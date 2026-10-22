// A metric's detail sheet, opened from a card's arrow: the metric over a day, week, month or year (GET /api/metric),
// the window's average, three figures, and one plain sentence the server builds from them. A modal dialog: the page
// behind it can't be reached or scrolled while it's open, Escape or a click outside closes it, and focus goes back to
// the button that opened it. The card's own page is one link away ("Open Vitals"). Opened on a window with nothing in
// it, it moves to its longest range and says so, since the card may show an older reading.
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
import { compact, fmt, fmtDate, hoursMinutes, useApi } from '../lib.ts';
import { Icon } from './Icon.tsx';

export type SheetOptions = {
  /** The day the card shows (the sheet's window ends on it); null or absent is today. */
  date?: string | null;
  /** Where it was opened, for the breadcrumb: "Home", "Body". */
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

const SOURCE: Record<string, string> = { apple: 'Apple Health', whoop: 'WHOOP', demo: 'Demo data' };

/** What one day's value is, where it isn't simply the day's reading. */
const DAY_NOTE: Partial<Record<MetricKey, string>> = {
  glucose: "each day is the average of that day's readings",
  weight: "each day is that day's last weigh-in",
  body_fat: "each day is that day's last reading",
  lean_mass: "each day is that day's last reading",
  sleep_hours: 'each night counts toward the morning it ends',
};

function sourceLine(s: SheetData) {
  const names = s.sources.map((x) => SOURCE[x] ?? x);
  const from = names.length ? `From ${names.join(' and ')}` : '';
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

const EMPTY: Partial<Record<MetricKey, string>> = {
  glucose: 'Glucose appears when a CGM or meter writes to Apple Health.',
  weight: 'Weight appears when a scale or the Health app records it.',
  body_fat: 'Body fat appears when a smart scale writes it to Apple Health.',
  lean_mass: 'Lean body mass appears when a smart scale writes it to Apple Health.',
  recovery: 'Recovery comes from WHOOP.',
  strain: 'Day strain comes from WHOOP.',
  vo2max: 'Cardio fitness comes from Apple Watch, after outdoor walks and runs.',
};

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

  const ranges = sheet?.ranges ?? info.ranges.filter((r) => r !== 'day' || info.ranges.length === 1);
  // Said only while the range shown bears it out: a reading synced into the first window since the move drops it.
  const note = widened && !picked && shown?.range === range && stillEmpty(widened, shown) ? widenedNote(widened, range) : null;

  return (
    <div className="msheet-backdrop" onMouseDown={onBackdropDown} onClick={onBackdropClick}>
      {/* tabIndex -1: a click on the sheet's text or chart keeps focus in the dialog rather than dropping it to the page. */}
      <div ref={panel} className="msheet" role="dialog" aria-modal="true" aria-labelledby={titleId} aria-describedby={shown?.narrative ? textId : undefined} tabIndex={-1}>
        <header className="msheet-head">
          <div className="msheet-crumbs">
            <span>{section}</span>
            <span aria-hidden="true">/</span>
            <h2 id={titleId} ref={title} tabIndex={-1}>
              {info.label}
            </h2>
          </div>
          <button type="button" className="icon-btn msheet-close" onClick={onClose} aria-label="Close">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true" className="icon">
              <path d="M6 6l12 12M18 6 6 18" />
            </svg>
          </button>
        </header>

        {ranges.length > 1 && (
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
          {!shown ? (
            <p className="msheet-message">{error ? `Couldn't load this: ${error.message}` : 'Loading…'}</p>
          ) : (
            <SheetBody sheet={shown} textId={textId} note={note} />
          )}
        </div>

        {/* Not a link to the page it was opened on: that's where closing the sheet goes. */}
        {pageName(to) !== pageName(location.hash) && (
          <a className="msheet-open" href={to} onClick={onClose}>
            Open {pageName(to)}
            <Icon name="chevron-right" size={16} />
          </a>
        )}
      </div>
    </div>
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
