// A metric's detail sheet, opened from a card's arrow: the metric over a day, week, month or year (GET /api/metric),
// the window's average, three figures, and one plain sentence the server builds from them, then "What this means" (a
// plain explainer and a source to read on). A modal dialog in the shared Sheet look (a pale panel over a light,
// blurred veil): the page behind it can't be reached or scrolled while it's open, Escape or a click outside closes it,
// and focus goes back to the button that opened it. The card's own page is one link away ("Open Vitals"). Opened on a
// window with nothing in it, it moves to its longest range and says so, since the card may show an older reading; a
// metric never measured at all says "No measurement yet" instead, with no ranges to try.
import { type MouseEvent, type ReactNode, useCallback, useEffect, useId, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  type MetricFigure,
  type MetricKey,
  type MetricRange,
  type MetricSheet as SheetData,
  METRIC_INFO,
  RANGE_LABEL,
  emptyWindowText,
  mmolFromMgDl,
  nothingToShow,
  showSheet,
  stillEmpty,
  widenedNote,
  widerRange,
} from '../../shared/metrics.ts';
import type { DayMetric } from '../../shared/types.ts';
import { BarChart, ChartCard, TrendChart } from '../charts/Charts.tsx';
import { DayChart } from '../charts/Day.tsx';
import { cumulative, drawThrough, hourSpan } from '../charts/day.ts';
import { compact, fmt, fmtDate, hoursMinutes, href, useApi } from '../lib.ts';
import { Icon } from './Icon.tsx';
import '../styles/home.css';

export type SheetOptions = {
  /** The day the card shows (the sheet's window ends on it); null or absent is today. */
  date?: string | null;
  /** The line above the metric's name, in capitals: "Your signals", "Your body". */
  section: string;
  /** The card's own page, for "Open …" (the address its arrow used to go to). */
  to: string;
  /** The range to open on; the metric's own default otherwise. */
  range?: MetricRange;
};

type Open = { key: MetricKey; options: SheetOptions; opener: HTMLElement | null };

/**
 * Opens a sheet from any button: `open(key, options, opener)`. The page renders `sheet` (a portal, so it sits over
 * everything); focus returns to `opener` (or whatever had focus) when it closes.
 */
export function useMetricSheet() {
  const [state, setState] = useState<Open | null>(null);
  const open = useCallback((key: MetricKey, options: SheetOptions, opener?: HTMLElement | null) => {
    setState({ key, options, opener: opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null) });
  }, []);
  const close = useCallback(() => setState(null), []);
  const sheet = state ? createPortal(<MetricSheet key={state.key} metric={state.key} {...state.options} opener={state.opener} onClose={close} />, document.body) : null;
  return { open, close, sheet };
}

/** A card's arrow that opens the metric's sheet: a real button, named for what it opens. */
export function MetricSheetLink({ metric, title, className = 'metric-link', ...options }: SheetOptions & { metric: MetricKey; title: string; className?: string }) {
  const { open, sheet } = useMetricSheet();
  return (
    <>
      <button type="button" className={`${className} metric-sheet-btn`} aria-label={`Open ${title} details`} aria-haspopup="dialog" onClick={(e) => open(metric, options, e.currentTarget)}>
        <Icon name="arrow-up-right" size={16} />
      </button>
      {sheet}
    </>
  );
}

// ---------- formatting ----------

/** A value with its unit, as the cards write it. */
function formatter(sheet: { key: MetricKey; unit: string; digits: number }) {
  const info = METRIC_INFO[sheet.key];
  if (info.duration) return hoursMinutes;
  return (v: number) => {
    const n = fmt(v, sheet.digits);
    return sheet.unit === '%' ? `${n}%` : sheet.unit ? `${n} ${sheet.unit}` : n;
  };
}

const tickFormatter = (sheet: { key: MetricKey; digits: number }) => {
  if (METRIC_INFO[sheet.key].duration) return (v: number) => `${fmt(v)}h`;
  if (sheet.key === 'steps' || sheet.key === 'active_energy') return compact;
  return (v: number) => fmt(v, sheet.digits && Math.abs(v) < 100 ? 1 : 0);
};

const SOURCE: Record<string, string> = { apple: 'Apple Health', whoop: 'WHOOP', fitbit: 'Fitbit', manual: 'Added by you', demo: 'Demo data' };

/** What one day's value is, where it isn't simply the day's reading. */
const DAY_NOTE: Partial<Record<MetricKey, string>> = {
  glucose: "each day is the average of that day's readings",
  weight: "each day is that day's last weigh-in",
  body_fat: "each day is that day's last reading",
  lean_mass: "each day is that day's last reading",
  sleep_hours: 'each night counts toward the morning it ends',
  sleep_performance: 'each night counts toward the morning it ends',
  sleep_efficiency: 'each night counts toward the morning it ends',
};

function sourceLine(s: SheetData) {
  // Devices are "From …"; entries the person typed in are said apart: "From Apple Health, and added by you".
  const names = s.sources.filter((x) => x !== 'manual').map((x) => SOURCE[x] ?? x);
  const devices = names.length ? `From ${names.join(' and ')}` : '';
  const from = s.sources.includes('manual') ? (devices ? `${devices}, and added by you` : SOURCE.manual) : devices;
  const method = s.key === 'hrv' ? (s.metric === 'hrv_sdnn' ? 'SDNN, from Apple Watch' : 'RMSSD, measured during sleep') : '';
  const span =
    s.from === s.to
      ? fmtDate(s.from, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })
      : `${fmtDate(s.from, { month: 'short', day: 'numeric', year: s.from.slice(0, 4) === s.to.slice(0, 4) ? undefined : 'numeric' })} – ${fmtDate(s.to, { month: 'short', day: 'numeric', year: 'numeric' })}`;
  return [from, method, DAY_NOTE[s.key], span].filter(Boolean).join(' · ');
}

/** "Open Vitals", "Open Recovery on Body": the card's own page, named. */
export function pageName(to: string) {
  const [path, query] = to.replace(/^#\/?/, '').split('?');
  const page = path ? path[0].toUpperCase() + path.slice(1) : 'Home';
  const tab = new URLSearchParams(query ?? '').get('tab');
  return tab ? `${tab[0].toUpperCase()}${tab.slice(1)} on ${page}` : page;
}

const OWN_ENTRY = 'Add an entry on Body, or connect a smart scale through Apple Health.';
const EMPTY: Partial<Record<MetricKey, string>> = {
  glucose: 'Glucose appears when a CGM or meter writes to Apple Health.',
  weight: OWN_ENTRY,
  body_fat: OWN_ENTRY,
  lean_mass: OWN_ENTRY,
  recovery: 'Recovery comes from WHOOP.',
  strain: 'Day strain comes from WHOOP.',
  vo2max: 'Cardio fitness comes from Apple Watch, after outdoor walks and runs.',
  sleep_performance: 'Sleep performance comes from WHOOP.',
  sleep_efficiency: 'Sleep efficiency comes from WHOOP or Fitbit, or from Apple Watch nights that record time in bed.',
};
/** Metrics a person can type in themselves (Body): a never-measured one says how, under the general line. */
const OWN_ENTRIES = new Set<MetricKey>(['weight', 'body_fat', 'lean_mass']);

// ---------- the sheet ----------

const FOCUSABLE = 'a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"])';

function MetricSheet({ metric, date, section, to, range: initial, opener, onClose }: SheetOptions & { metric: MetricKey; opener: HTMLElement | null; onClose: () => void }) {
  const info = METRIC_INFO[metric];
  const [range, setRange] = useState<MetricRange>(initial && info.ranges.includes(initial) ? initial : info.initial);
  // Set once the person presses a range: from then on the sheet shows the one they chose, empty or not.
  const [picked, setPicked] = useState(false);
  // The range it opened on, when it moved to a longer one by itself because that one had nothing in it.
  const [widened, setWidened] = useState<MetricRange | null>(null);
  const { data, error, loading, current } = useApi<SheetData>(`/metric/${metric}?range=${range}${date ? `&date=${date}` : ''}`);
  const sheet = data?.key === metric ? data : undefined;
  // Another range's data stays up while the one asked for loads, except an empty window's; and one about to move to a
  // longer range isn't shown at all. Either would flash "Nothing in the last 30 days" on the way to a range that has something.
  const shown = sheet && showSheet(sheet, range, picked) ? sheet : undefined;
  const panel = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const titleId = useId();
  const textId = useId();

  // While open: the page behind is inert (no focus, hidden from screen readers) and doesn't scroll. Focus starts
  // on the title and goes back to the opener at the end.
  useEffect(() => {
    const root = document.getElementById('root');
    const wasInert = root?.hasAttribute('inert') ?? true;
    if (root && !wasInert) root.setAttribute('inert', '');
    const html = document.documentElement;
    const before = { html: html.style.overflow, body: document.body.style.overflow };
    html.style.overflow = 'hidden';
    document.body.style.overflow = 'hidden';
    title.current?.focus({ preventScroll: true });
    return () => {
      if (root && !wasInert) root.removeAttribute('inert');
      html.style.overflow = before.html;
      document.body.style.overflow = before.body;
      if (opener?.isConnected) opener.focus({ preventScroll: true });
    };
  }, [opener]);

  // A range this person doesn't have (Day, before the phone has sent any hours) falls back to the first one they do.
  // One with nothing in it, until the person picks a range themselves, moves to the longest: the card it was opened
  // from may show a reading older than the window (a weigh-in two months ago), which the sheet shouldn't deny. Only
  // on data that's current: an older copy kept from before a sync may be empty where the window now isn't.
  useEffect(() => {
    if (!sheet || sheet.range !== range || !current) return;
    if (!sheet.ranges.includes(range)) return void setRange(sheet.ranges[0]);
    const wider = picked ? null : widerRange(sheet);
    if (wider) {
      setWidened(range);
      setRange(wider);
    }
  }, [sheet, range, picked, current]);

  // Keys are heard on the document while the sheet is open, not only on the panel: a click on its text or chart can
  // leave focus on the page's body, and Escape and Tab must still work then. Keys for something else on top (the
  // search palette) are left to it.
  useEffect(() => {
    const onKey = (e: globalThis.KeyboardEvent) => {
      const p = panel.current;
      const target = e.target instanceof Node ? e.target : null;
      const onPage = !target || target === document || target === document.body || target === document.documentElement;
      if (!p || e.defaultPrevented || !(onPage || p.contains(target))) return;
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
        return;
      }
      if (e.key !== 'Tab') return;
      // Focus stays inside: Tab from the last control goes to the first, Shift+Tab from the first to the last, and
      // from the panel itself (after a click on its text) or from outside it, to the last or the first.
      const items = [...p.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => el.offsetParent !== null || el === document.activeElement);
      if (!items.length) return;
      const first = items[0];
      const last = items.at(-1)!;
      const at = document.activeElement;
      const off = at === p || !p.contains(at);
      if (e.shiftKey && (at === first || at === title.current || off)) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && (at === last || off)) {
        e.preventDefault();
        first.focus();
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);
  // A press that starts and ends on the backdrop closes; one that starts inside (selecting text, a drag) doesn't.
  const downOnBackdrop = useRef(false);
  const onBackdropDown = (e: MouseEvent<HTMLDivElement>) => {
    downOnBackdrop.current = e.target === e.currentTarget;
  };
  const onBackdropClick = (e: MouseEvent<HTMLDivElement>) => {
    if (downOnBackdrop.current && e.target === e.currentTarget) onClose();
    downOnBackdrop.current = false;
  };

  const ranges = sheet?.ranges ?? [];
  // Said only while the range shown bears it out: a reading synced into the first window since the move drops it.
  const note = widened && !picked && shown?.range === range && stillEmpty(widened, shown) ? widenedNote(widened, range) : null;
  // Never measured at all (an older server doesn't say, and counts as measured). Until the first answer it isn't known,
  // so the ranges wait for it rather than showing and then going.
  const never = sheet?.everMeasured === false;
  const measured = !!sheet && !never;

  return (
    <div className="sheet-veil" onMouseDown={onBackdropDown} onClick={onBackdropClick}>
      {/* tabIndex -1: a click on the sheet's text or chart keeps focus in the dialog rather than dropping it to the page. */}
      <div
        ref={panel}
        className="sheet msheet-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={never ? textId : shown?.narrative ? textId : undefined}
        tabIndex={-1}
      >
        <header className="sheet-head">
          <div>
            <p className="eyebrow">{section}</p>
            <h2 id={titleId} ref={title} tabIndex={-1}>
              {info.label}
            </h2>
          </div>
          <button type="button" className="sheet-close" onClick={onClose} aria-label="Close">
            <Icon name="x" size={16} strokeWidth={1.8} />
          </button>
        </header>

        {measured && ranges.length > 1 && (
          <div className="filters msheet-ranges" role="group" aria-label="Range">
            {ranges.map((r) => (
              <button
                key={r}
                type="button"
                className={range === r ? 'on' : ''}
                aria-pressed={range === r}
                onClick={() => {
                  setPicked(true);
                  setRange(r);
                }}
              >
                {RANGE_LABEL[r]}
              </button>
            ))}
          </div>
        )}

        <div className={`msheet-body${loading ? ' is-refreshing' : ''}`}>
          {never ? (
            <div className="msheet-empty" id={textId}>
              <p className="msheet-empty-title">No measurement yet.</p>
              <p>Connect a source or import measured data to see your trend.</p>
              {OWN_ENTRIES.has(metric) && <p className="msheet-empty-hint">{OWN_ENTRY}</p>}
              <a className="pill" href={href('integrations')} onClick={onClose}>
                Manage connections
                <Icon name="arrow-up-right" size={14} />
              </a>
            </div>
          ) : !shown ? (
            <p className="msheet-message">{error ? `Couldn't load this: ${error.message}` : 'Loading…'}</p>
          ) : (
            <SheetBody sheet={shown} textId={textId} note={note} />
          )}
        </div>

        <About metric={metric} />

        {/* Only once there's something there, and not a link to the page it was opened on: that's where closing goes. */}
        {measured && pageName(to) !== pageName(location.hash) && (
          <a className="msheet-open" href={to} onClick={onClose}>
            Open {pageName(to)}
            <Icon name="chevron-right" size={16} />
          </a>
        )}
      </div>
    </div>
  );
}

/** "What this means": the metric in one plain sentence, what to keep in mind about it, and a reputable page to read on. */
function About({ metric }: { metric: MetricKey }) {
  const { label, about } = METRIC_INFO[metric];
  const headId = useId();
  return (
    <section className="msheet-about" aria-labelledby={headId}>
      <p className="eyebrow">Understand your {label}</p>
      <h3 id={headId}>What this means</h3>
      <p className="msheet-about-what">{about.what}</p>
      <p className="msheet-about-caveat">{about.caveat}</p>
      <a className="msheet-about-source" href={about.source.href} target="_blank" rel="noopener noreferrer">
        {about.source.label}
        <Icon name="arrow-up-right" size={12} />
        <span className="sr-only"> (opens in a new tab)</span>
      </a>
    </section>
  );
}

function SheetBody({ sheet, textId, note }: { sheet: SheetData; textId: string; note: string | null }) {
  const format = formatter(sheet);
  const h = sheet.headline;
  // A window holding only today's unfinished total isn't empty: its bar and its Latest · so far today are shown.
  const nothing = nothingToShow(sheet);
  return (
    <>
      {/* Why a range the person didn't press is the pressed one. */}
      {note && (
        <p className="msheet-widened" role="status">
          {note}
        </p>
      )}
      <p className="msheet-source">{sourceLine(sheet)}</p>
      {nothing ? (
        <p className="msheet-message">
          {sheet.range === 'day' && !sheet.day?.metrics[sheet.key as DayMetric]
            ? 'Hour-by-hour readings come from Apple Watch and iPhone, through the healthOS iPhone app.'
            : (emptyWindowText(sheet) ?? EMPTY[sheet.key] ?? 'Nothing recorded in this range.')}
        </p>
      ) : (
        <>
          <div className="msheet-figure">
            <div className="msheet-figure-main">
              <span className="msheet-figure-label">{h.label}</span>
              <span className="msheet-big">{bigValue(sheet, h)}</span>
              {sheet.key === 'glucose' && h.value !== null && <span className="msheet-alt">{fmt(mmolFromMgDl(h.value), 1)} mmol/L</span>}
              {h.note && <span className="msheet-note">{h.note}</span>}
            </div>
            {sheet.status && (
              <span className={`pill msheet-status msheet-status-${sheet.status.position}`}>
                {sheet.status.text}
                <span className="sr-only"> (the latest reading)</span>
              </span>
            )}
          </div>
          <SheetChart sheet={sheet} />
          <ul className="msheet-tiles">
            {sheet.tiles.map((t) => (
              <li key={t.label}>
                <span className="msheet-tile-label">{t.label}</span>
                <b>{t.value === null ? '—' : t.unit === sheet.unit ? format(t.value) : `${fmt(t.value)} ${t.unit}`}</b>
                <small>{[t.date && fmtDate(t.date, { month: 'short', day: 'numeric', year: sheet.range === 'year' ? 'numeric' : undefined }), t.note].filter(Boolean).join(' · ') || ' '}</small>
              </li>
            ))}
          </ul>
        </>
      )}
      {sheet.narrative && (
        <p className="msheet-insight" id={textId} aria-live="polite">
          <span className="insight-icon tone-neutral" aria-hidden="true">
            <Icon name="spark" size={16} />
          </span>
          <span>{sheet.narrative}</span>
        </p>
      )}
    </>
  );
}

/** The big number, its unit set smaller as on the cards. */
function bigValue(sheet: SheetData, f: MetricFigure): ReactNode {
  if (f.value === null) return '—';
  if (METRIC_INFO[sheet.key].duration) return hoursMinutes(f.value);
  const n = fmt(f.value, sheet.digits);
  return (
    <>
      {n}
      {f.unit && <small>{f.unit === '%' ? '%' : ` ${f.unit}`}</small>}
    </>
  );
}

const weekLabel = (d: string) => `Week of ${fmtDate(d, { month: 'short', day: 'numeric' })}`;

function SheetChart({ sheet }: { sheet: SheetData }) {
  const format = formatter(sheet);
  const tick = tickFormatter(sheet);
  const info = METRIC_INFO[sheet.key];
  const color = sheet.key === 'strain' || sheet.key === 'active_energy' || sheet.key === 'resting_hr' || sheet.key === 'heart_rate' ? 'var(--series-2)' : 'var(--series-1)';

  if (sheet.range === 'day') {
    const d = sheet.day;
    const ser = d?.metrics[sheet.key as DayMetric];
    if (!d || !ser) return null;
    const through = drawThrough(d.date, d.today, d.asOf);
    const running = sheet.key !== 'heart_rate';
    const run = cumulative(ser.hours, through);
    const cell = (v: number | null | undefined) => (v === null || v === undefined ? '—' : format(v));
    const hours = through === null ? [] : Array.from({ length: through + 1 }, (_, i) => i);
    const table = running
      ? { columns: ['Hour', 'This hour', 'So far', 'Typical by then'], rows: hours.map((i) => [hourSpan(i), format(ser.hours[i] ?? 0), cell(run[i]), cell(ser.typical[i])]) }
      : { columns: ['Hour', 'Average', 'Low', 'High', 'Typical'], rows: hours.map((i) => [hourSpan(i), cell(ser.hours[i]), cell(ser.min?.[i]), cell(ser.max?.[i]), cell(ser.typical[i])]) };
    return (
      <ChartCard className="msheet-chart" title={running ? 'By the hour, running total' : 'By the hour'} note="Dashed: your typical day, the median of the last 30 days" table={table}>
        <DayChart
          kind={running ? 'running' : 'hourly'}
          series={ser}
          through={through}
          format={format}
          tickFormat={tick}
          color={color}
          goal={sheet.goal ? { value: sheet.goal, label: `Goal ${compact(sheet.goal)}` } : undefined}
          label={`${info.label} by the hour, ${fmtDate(d.date, { weekday: 'long', month: 'long', day: 'numeric' })}`}
        />
      </ChartCard>
    );
  }

  if (!sheet.points.length) return null;
  const weekly = sheet.resolution === 'week';
  const title = weekly ? 'Weekly averages of the daily values' : info.duration ? 'Each night' : 'Each day';
  const table = {
    columns: [weekly ? 'Week of' : 'Date', info.label],
    rows: sheet.points.map((p) => [fmtDate(p.date, { year: 'numeric', month: 'short', day: 'numeric' }), format(p.value)]),
  };
  const label = `${info.label}, ${RANGE_LABEL[sheet.range].toLowerCase()}${weekly ? ', weekly averages' : ''}`;
  return (
    <ChartCard className="msheet-chart" title={title} note={sheet.partialToday && !weekly ? "Today's bar is so far today" : undefined} table={table}>
      {info.chart === 'bars' ? (
        <BarChart
          points={sheet.points}
          format={format}
          tickFormat={tick}
          label={label}
          periodLabel={weekly ? weekLabel : undefined}
          goal={sheet.goal && !weekly ? { value: sheet.goal, label: `Goal ${compact(sheet.goal)}` } : undefined}
        />
      ) : (
        <TrendChart points={sheet.points} format={format} tickFormat={tick} color={color} label={label} gapDays={weekly ? 10 : 3} periodLabel={weekly ? weekLabel : undefined} />
      )}
    </ChartCard>
  );
}
