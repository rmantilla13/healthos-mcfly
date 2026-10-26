// Cycle tracking: the Cycle page (shown only when tracking is on) and its card in Settings.
// The data comes from GET /api/cycle on its own, never from the summary, so nothing else on the
// dashboard (or Ask McFly's summary tool) carries it. Every estimate here is worded as one: no day is
// ever shown as safe, and nothing is fit to use as contraception.
import { useMemo, useState } from 'react';
import type {
  CervicalMucus,
  CycleData,
  CycleFields,
  CycleHistory,
  CycleInsights,
  CycleLogDay,
  CyclePhase,
  CycleTemperature,
  FertilityDay,
  Flow,
  OvulationTest,
  Settings,
  SexualActivity,
  Status,
  Symptom,
  TempDisturbance,
  TempSource,
} from '../../shared/types.ts';
import { Tooltip, niceTicks, useScrub, useWidth } from '../charts/core.tsx';
import { Icon } from '../components/Icon.tsx';
import { PageIntro } from '../components/PageIntro.tsx';
import { daysBetween, fmt, fmtDate, href, notifyDataChanged, sendJson, shiftDate, temp, useApi, useUnits } from '../lib.ts';

const FLOW_LABEL: Record<Flow, string> = {
  none: 'None',
  unspecified: 'Some',
  light: 'Light',
  medium: 'Medium',
  heavy: 'Heavy',
};
const TEST_LABEL: Record<OvulationTest, string> = {
  negative: 'Negative',
  lh_surge: 'LH surge',
  estrogen_surge: 'Estrogen surge',
  indeterminate: 'Unclear',
};
const MUCUS_LABEL: Record<CervicalMucus, string> = {
  dry: 'Dry',
  sticky: 'Sticky',
  creamy: 'Creamy',
  watery: 'Watery',
  egg_white: 'Egg white',
};
const SEX_LABEL: Record<SexualActivity, string> = {
  protected: 'Protected',
  unprotected: 'Unprotected',
  unspecified: 'Not noted',
};
const SYMPTOM_LABEL: Record<Symptom, string> = {
  cramps: 'Cramps',
  bloating: 'Bloating',
  breast_tenderness: 'Breast tenderness',
  headache: 'Headache',
  acne: 'Acne',
  fatigue: 'Fatigue',
  mood_changes: 'Mood changes',
  back_pain: 'Lower back pain',
  nausea: 'Nausea',
  appetite_changes: 'Appetite changes',
  sleep_changes: 'Sleep changes',
  hot_flashes: 'Hot flashes',
};
const DISTURB_LABEL: Record<TempDisturbance, string> = {
  sick: 'Sick or feverish',
  alcohol: 'Alcohol',
  sleep: 'Short or unusual sleep',
  travel: 'Travel',
  other: 'Other',
};
const SOURCE_LABEL: Record<TempSource, string> = {
  bbt: 'thermometer',
  wrist: 'Apple Watch wrist temperature',
  skin: 'WHOOP skin temperature',
};
const SOURCE_SHORT: Record<TempSource, string> = {
  bbt: 'Thermometer',
  wrist: 'Apple Watch',
  skin: 'WHOOP',
};
const PHASE_LABEL: Record<CyclePhase['name'], string> = {
  menstrual: 'Period',
  follicular: 'Follicular phase',
  ovulatory: 'Around ovulation',
  luteal: 'Luteal phase',
};
const PHASE_NOTE: Record<CyclePhase['name'], string> = {
  menstrual: 'Your period. Energy often picks up as it ends.',
  follicular: 'Before ovulation. Estrogen rises through this phase.',
  ovulatory: 'Around ovulation, as estimated. The days just before it are the most fertile.',
  luteal: 'After ovulation. Temperature and resting heart rate often run a little higher.',
};
const LEVEL_LABEL: Record<FertilityDay['level'], string> = {
  medium: 'Possible',
  high: 'High',
  peak: 'Peak',
};

const isBleeding = (d: CycleFields | undefined) => d?.flow !== undefined && d.flow !== 'none';
/** The estimate, or while fewer than two cycles are complete, the early one that leans on typical cycles. */
const estimateOf = (data: CycleData) => data.estimate ?? data.earlyEstimate ?? null;
const range = (a: string, b: string) => (a === b ? fmtDate(a) : `${fmtDate(a)} – ${fmtDate(b)}`);
const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
/** A temperature difference in the person's units (°F differences scale but don't shift). */
const tempDelta = (c: number, units: ReturnType<typeof useUnits>) => (units === 'imperial' ? { value: c * 1.8, unit: '°F' } : { value: c, unit: '°C' });
const signed = (v: number, digits: number) => `${v > 0 ? '+' : v < 0 ? '−' : ''}${fmt(Math.abs(v), digits)}`;

/** A short line for what one source logged on a day. */
function describe(f: CycleFields, units: ReturnType<typeof useUnits>): string {
  const parts: string[] = [];
  if (f.flow) parts.push(f.flow === 'none' ? 'No flow' : `${FLOW_LABEL[f.flow]} flow`);
  if (f.periodStart) parts.push('first day');
  if (f.spotting) parts.push('spotting');
  if (f.ovulationTest) parts.push(`test: ${TEST_LABEL[f.ovulationTest].toLowerCase()}`);
  if (f.mucus) parts.push(`${MUCUS_LABEL[f.mucus].toLowerCase()} mucus`);
  if (f.bbt !== undefined) {
    const t = temp(f.bbt, units);
    parts.push(`${fmt(t.value, 2)} ${t.unit}`);
  }
  if (f.tempDisturbed) parts.push(`temperature may be off (${DISTURB_LABEL[f.tempDisturbed].toLowerCase()})`);
  if (f.symptoms?.length) parts.push(f.symptoms.map((s) => SYMPTOM_LABEL[s].toLowerCase()).join(', '));
  if (f.sexualActivity) parts.push(`sex (${SEX_LABEL[f.sexualActivity].toLowerCase()})`);
  return parts.join(', ');
}

export function Cycle({ status }: { status: Status }) {
  const { data, error, reload } = useApi<CycleData>('/cycle?days=400');
  const [selected, setSelected] = useState<string | null>(null);

  if (!status.settings.cycleTracking || data?.enabled === false) {
    return (
      <div className="page">
        <PageIntro sub="Cycle tracking is off." />
        <section className="card">
          <p className="muted">
            Turn on cycle tracking in <a href={href('profile')}>your Profile</a> to log periods and see estimates of your next one.
          </p>
        </section>
      </div>
    );
  }
  if (error) return <div className="page-message">Couldn't load your cycle: {error.message}</div>;
  if (!data) return <div className="page-message">Loading…</div>;

  return (
    <div className="page cycle-page">
      <PageIntro
        sub="From Apple Health, your Watch or WHOOP's nightly temperature, and what you log here. Only you can see it, unless you share your phase with family."
        actions={
          <button className="btn btn-primary" onClick={() => setSelected(data.today)}>
            <Icon name="plus" size={15} />
            Log today
          </button>
        }
      />
      <div className="cycle-hero">
        <TodayCard data={data} />
        <FertilityCard data={data} />
      </div>
      <TemperatureCard data={data} />
      <div className="cycle-main">
        <CalendarCard data={data} selected={selected} onSelect={setSelected} />
        {selected && (
          <LogCard key={selected} date={selected} day={data.days.find((d) => d.date === selected)} today={data.today} onClose={() => setSelected(null)} onSaved={reload} />
        )}
      </div>
      <div className="grid-2">
        <HistoryCard data={data} />
        <PatternsCard insights={data.insights} />
      </div>
      <DeleteCycleData onDeleted={reload} />
    </div>
  );
}

// ---------- today ----------

/** The current cycle as a ring: period, fertile days by level, the luteal phase, and today. */
function PhaseRing({ data, size = 168 }: { data: CycleData; size?: number }) {
  const { current } = data;
  const estimate = estimateOf(data);
  if (!current) return null;
  const expected = estimate ? daysBetween(current.start, estimate.nextPeriod.date) : (data.stats.cycleDays ?? 28);
  const length = Math.max(expected, current.day, 1);
  const r = size / 2 - 12;
  const c = size / 2;
  const at = (day: number) => -Math.PI / 2 + ((day - 1) / length) * 2 * Math.PI;
  const arc = (from: number, to: number) => {
    const a0 = at(from);
    const a1 = at(to + 1) - 0.035;
    const large = a1 - a0 > Math.PI ? 1 : 0;
    return `M${c + r * Math.cos(a0)},${c + r * Math.sin(a0)} A${r},${r} 0 ${large} 1 ${c + r * Math.cos(a1)},${c + r * Math.sin(a1)}`;
  };
  const day = (date: string) => daysBetween(current.start, date) + 1;
  const period = data.periods.find((p) => p.start === current.start);
  const periodDays = Math.min(period?.days ?? data.stats.periodDays ?? 5, length);
  const found = data.history?.at(-1)?.ovulation;
  const ovulation = found?.date ?? estimate?.ovulation;
  const segments: { from: number; to: number; cls: string }[] = [{ from: 1, to: periodDays, cls: 'ring-period' }];
  for (const f of data.fertility ?? []) {
    const d = day(f.date);
    if (d > periodDays && d <= length) segments.push({ from: d, to: d, cls: `ring-fertile-${f.level}` });
  }
  if (ovulation) {
    const fertileEnd = Math.max(periodDays, ...(data.fertility ?? []).map((f) => day(f.date)));
    const from = Math.max(day(ovulation) + 1, fertileEnd + 1);
    if (from <= length) segments.push({ from, to: length, cls: 'ring-luteal' });
  }
  const t = at(Math.min(current.day, length) + 0.5);
  return (
    <svg className="phase-ring" width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true">
      <circle cx={c} cy={c} r={r} className="ring-track" />
      {segments.map((s, i) => (
        <path key={i} d={arc(s.from, s.to)} className={s.cls} />
      ))}
      <circle cx={c + r * Math.cos(t)} cy={c + r * Math.sin(t)} r={7} className="ring-today" />
      <text x={c} y={c - 4} textAnchor="middle" className="ring-day">
        Day {current.day}
      </text>
      <text x={c} y={c + 18} textAnchor="middle" className="ring-of">
        of about {expected}
      </text>
    </svg>
  );
}

function ovulationLine(data: CycleData): string | null {
  const now = data.history?.at(-1);
  const est = estimateOf(data);
  if (now?.status === 'confirmed' && now.ovulation) {
    return `Ovulation confirmed around ${fmtDate(now.ovulation.date)} by a sustained rise in your ${SOURCE_LABEL[now.ovulation.tempSource ?? 'bbt']}.`;
  }
  if (now?.status === 'lh_test' && now.ovulation) return `Ovulation likely around ${fmtDate(now.ovulation.date)}, the day after your positive LH test.`;
  if (!est) return null;
  if (now?.temperature && data.today <= shiftDate(est.ovulation, 3)) return `Watching your ${SOURCE_LABEL[now.temperature.source]} for the rise that follows ovulation.`;
  return `Ovulation estimated around ${fmtDate(est.ovulation)}.`;
}

function TodayCard({ data }: { data: CycleData }) {
  const { current, today, phase } = data;
  const estimate = estimateOf(data);
  const next = estimate?.nextPeriod;
  const until = next ? daysBetween(today, next.date) : null;
  const ov = ovulationLine(data);
  return (
    <section className="card cycle-today">
      <PhaseRing data={data} />
      <div className="cycle-today-text">
        <div className="card-title-row">
          <h2>{phase ? PHASE_LABEL[phase.name] : 'This cycle'}</h2>
          {estimate?.confidence && (
            <span className={`pill confidence-${estimate.confidence}`}>
              {estimate.confidence === 'high' ? 'Confident' : estimate.confidence === 'medium' ? 'Fairly sure' : 'Early estimate'}
            </span>
          )}
        </div>
        {phase && <p className="muted small">{PHASE_NOTE[phase.name]}</p>}
        {!current && <p className="muted">No period logged yet. Log the first day of your next one, or import your Apple Health history.</p>}
        {estimate && next && until !== null ? (
          <dl className="cycle-facts">
            <div>
              <dt>Next period</dt>
              <dd>
                {until > 0
                  ? `${fmtDate(next.date)}, in ${plural(until, 'day')}`
                  : until === 0
                    ? 'Expected around today'
                    : `Expected ${fmtDate(next.date)}, ${plural(-until, 'day')} ago`}
                <small>Likely {range(next.earliest, next.latest)}</small>
              </dd>
            </div>
            <div>
              <dt>Fertile window</dt>
              <dd>
                {range(estimate.fertile.start, estimate.fertile.end)}
                <small>{ov}</small>
              </dd>
            </div>
          </dl>
        ) : (
          current && (
            <p className="muted small">
              {data.noEstimate === 'stale'
                ? `Your latest logged period started ${fmtDate(current.start)}. Log your most recent one to see estimates again.`
                : 'Estimates appear once a period is logged.'}
            </p>
          )
        )}
        {estimate && (
          <p className="muted small cycle-caveat">
            {estimate.cycles < 2
              ? 'Based on typical cycles until you have logged a few of your own.'
              : estimate.basis === 'calendar'
                ? `Based on your last ${plural(Math.min(estimate.cycles, 12), 'cycle')}.`
                : estimate.basis === 'bbt'
                  ? 'Based on this cycle’s temperature rise and your past cycles.'
                  : 'Based on this cycle’s LH test and your past cycles.'}{' '}
            Estimates, not medical advice, and not reliable as contraception.
          </p>
        )}
      </div>
    </section>
  );
}

// ---------- fertile window ----------

function FertilityCard({ data }: { data: CycleData }) {
  const fertility = data.fertility ?? [];
  const est = estimateOf(data);
  if (!est || !fertility.length) {
    return (
      <section className="card cycle-fertility">
        <div className="card-title-row">
          <h2>Fertile window</h2>
        </div>
        <p className="muted small">Your estimated fertile days show here once a period is logged.</p>
      </section>
    );
  }
  // Two days either side of the window, so it reads as a window.
  const from = shiftDate(fertility[0].date, -2);
  const to = shiftDate(fertility.at(-1)!.date, 2);
  const byDate = new Map(fertility.map((f) => [f.date, f]));
  const days = Array.from({ length: daysBetween(from, to) + 1 }, (_, i) => shiftDate(from, i));
  const found = data.history?.at(-1)?.ovulation?.date;
  const ovulation = found ?? est.ovulation;
  return (
    <section className="card cycle-fertility">
      <div className="card-title-row">
        <h2>Fertile window</h2>
        <span className="pill">{fertility[0].basis === 'logged' ? 'Your signs' : 'Estimate'}</span>
      </div>
      <ol className="fertile-bars" aria-label="Estimated chance of conception by day">
        {days.map((d) => {
          const f = byDate.get(d);
          return (
            <li
              key={d}
              className={[d === data.today && 'is-today', d < data.today && 'is-past'].filter(Boolean).join(' ')}
              aria-label={`${fmtDate(d, { weekday: 'long', month: 'long', day: 'numeric' })}: ${f ? `${LEVEL_LABEL[f.level].toLowerCase()} chance` : 'outside the estimated window'}${d === ovulation ? ', ovulation' : ''}${d === data.today ? ', today' : ''}`}
            >
              <span className="fertile-bar">
                <span
                  className={f ? `lvl-${f.level}` : 'lvl-low'}
                  style={{
                    height: `${Math.max(6, (f?.chance ?? 0.04) * 100)}%`,
                  }}
                />
              </span>
              <span className="fertile-day">{Number(d.slice(8))}</span>
              <span className="fertile-mark">{d === ovulation ? (found ? '●' : '○') : d === data.today ? '·' : ''}</span>
            </li>
          );
        })}
      </ol>
      <div className="legend">
        {(['medium', 'high', 'peak'] as const).map((l) => (
          <span key={l} className="legend-item">
            <span className={`legend-key rect lvl-${l}`} /> {LEVEL_LABEL[l]}
          </span>
        ))}
        <span className="legend-item">{found ? '● Ovulation' : '○ Ovulation (estimate)'}</span>
      </div>
      <p className="muted small">
        Each day’s chance of conception, relative to the most fertile day: the five days before ovulation and the day itself. Positive LH tests, egg-white or watery mucus and a
        temperature rise all sharpen it. Never treat a day outside it as safe.
      </p>
    </section>
  );
}

// ---------- temperature ----------

const TM = { top: 18, right: 14, bottom: 44, left: 44 };

function TemperatureCard({ data }: { data: CycleData }) {
  const units = useUnits();
  const history = data.history ?? [];
  const [index, setIndex] = useState(Math.max(0, history.length - 1));
  const cycle = history[Math.min(index, history.length - 1)];
  const temps = data.temperatures ?? [];
  if (!cycle) {
    return (
      <section className="card">
        <div className="card-title-row">
          <h2>Temperature</h2>
        </div>
        <p className="muted small">Your temperature curve shows here once a period is logged.</p>
      </section>
    );
  }
  const source = cycle.temperature?.source ?? null;
  const est = estimateOf(data);
  const end = cycle.end ?? (est ? shiftDate(est.nextPeriod.date, -1) : data.today);
  const points = source ? temps.filter((t) => t.source === source && t.date >= cycle.start && t.date <= (cycle.end ?? data.today)) : [];
  const otherSources = [...new Set(temps.filter((t) => t.date >= cycle.start && t.date <= (cycle.end ?? data.today)).map((t) => t.source))].filter((s) => s !== source);
  const label = cycle.end ? `${fmtDate(cycle.start)} – ${fmtDate(cycle.end)}` : `Since ${fmtDate(cycle.start)}`;
  const status = {
    confirmed: `Rise found: ovulation around ${cycle.ovulation ? fmtDate(cycle.ovulation.date) : ''}${cycle.temperature?.rise ? `, about ${signed(tempDelta(cycle.temperature.rise, units).value, 2)} ${tempDelta(0, units).unit} after it` : ''}.`,
    lh_test: `No temperature rise confirmed; ovulation from your LH test around ${cycle.ovulation ? fmtDate(cycle.ovulation.date) : ''}.`,
    waiting: 'No rise yet this cycle.',
    not_found: 'No sustained rise in this cycle’s temperatures.',
    no_data: 'Too few temperatures in this cycle to look for a rise.',
  }[cycle.status];
  return (
    <section className="card cycle-temp">
      <div className="card-title-row">
        <div>
          <h2>Temperature</h2>
          <p className="muted small">
            {source ? `${SOURCE_SHORT[source]}, against your own usual level. ` : ''}
            {status}
          </p>
        </div>
        <div className="btn-row cycle-nav">
          <button className="btn" aria-label="Earlier cycle" disabled={index <= 0} onClick={() => setIndex(index - 1)}>
            <Icon name="chevron-left" size={16} />
          </button>
          <span className="small">{label}</span>
          <button className="btn" aria-label="Later cycle" disabled={index >= history.length - 1} onClick={() => setIndex(index + 1)}>
            <Icon name="chevron-right" size={16} />
          </button>
        </div>
      </div>
      {points.length ? (
        <TempChart cycle={cycle} end={end} points={points} days={data.days} fertility={cycle.end ? [] : (data.fertility ?? [])} today={data.today} />
      ) : (
        <p className="muted small cycle-temp-empty">
          No temperatures in this cycle. Wearing an Apple Watch (Series 8 or later) or WHOOP to sleep records one every night; you can also log a thermometer reading when you wake.
        </p>
      )}
      {otherSources.length > 0 && (
        <p className="muted small">
          Also recorded: {otherSources.map((s) => SOURCE_SHORT[s]).join(', ')}. Each cycle uses the one device that covered it best; devices read at different levels, so they’re
          never mixed.
        </p>
      )}
    </section>
  );
}

function TempChart({
  cycle,
  end,
  points,
  days,
  fertility,
  today,
}: {
  cycle: CycleHistory;
  end: string;
  points: CycleTemperature[];
  days: CycleLogDay[];
  fertility: FertilityDay[];
  today: string;
}) {
  const units = useUnits();
  const [ref, width] = useWidth<HTMLDivElement>();
  const height = 240;
  const length = Math.max(daysBetween(cycle.start, end) + 1, daysBetween(cycle.start, points.at(-1)!.date) + 1, 14);
  const cd = (date: string) => daysBetween(cycle.start, date) + 1;
  const xOf = (day: number) => TM.left + ((day - 0.5) / length) * (width - TM.left - TM.right);
  const conv = (c: number) => tempDelta(c, units).value;
  const values = points.map((p) => conv(p.deviation));
  if (cycle.temperature?.coverline !== null && cycle.temperature?.coverline !== undefined) values.push(conv(cycle.temperature.coverline));
  const ticks = niceTicks(Math.min(...values, -0.1), Math.max(...values, 0.1), 4);
  const tickDigits = ticks.length > 1 && ticks[1] - ticks[0] < 0.1 - 1e-9 ? 2 : 1;
  const lo = ticks[0];
  const hi = ticks.at(-1)!;
  const plotBottom = height - TM.bottom;
  const yOf = (v: number) => TM.top + (1 - (v - lo) / (hi - lo || 1)) * (plotBottom - TM.top);
  const { index, handlers } = useScrub(points.length, (i) => xOf(cd(points[i].date)));
  const usable = points.filter((p) => !p.excluded);
  const unit = tempDelta(0, units).unit;
  const ovDay = cycle.ovulation ? cd(cycle.ovulation.date) : null;
  const inCycle = days.filter((d) => d.date >= cycle.start && cd(d.date) <= length);
  const bleeding = inCycle.filter((d) => isBleeding(d));
  const lh = inCycle.filter((d) => d.ovulationTest === 'lh_surge');
  const fertile = fertility.filter((f) => cd(f.date) <= length);
  const step = Math.max(1, Math.ceil(length / Math.max(4, Math.floor(width / 48))));
  const line = usable.map((p, i) => `${i ? 'L' : 'M'}${xOf(cd(p.date))},${yOf(conv(p.deviation))}`).join(' ');
  const band = (from: number, to: number) => ({
    x: xOf(from) - (xOf(2) - xOf(1)) / 2,
    w: (to - from + 1) * (xOf(2) - xOf(1)),
  });
  const hovered = index !== null ? points[index] : null;
  return (
    <>
      <div className="chart" ref={ref} style={{ height }}>
        {width > 0 && (
          <svg
            width={width}
            height={height}
            {...handlers}
            role="img"
            aria-label={`Temperature by cycle day, ${cycle.status === 'confirmed' ? `rise found, ovulation on day ${ovDay}` : 'no rise found'}`}
          >
            {fertile.map((f) => {
              const b = band(cd(f.date), cd(f.date));
              return <rect key={f.date} x={b.x} y={TM.top} width={b.w} height={plotBottom - TM.top} className={`temp-fertile lvl-${f.level}`} />;
            })}
            {ovDay &&
              ovDay < length &&
              (() => {
                const b = band(ovDay + 1, length);
                return <rect x={b.x} y={TM.top} width={b.w} height={plotBottom - TM.top} className="temp-luteal" />;
              })()}
            {ticks.map((t) => (
              <g key={t}>
                <line x1={TM.left} x2={width - TM.right} y1={yOf(t)} y2={yOf(t)} className="grid" />
                <text x={TM.left - 8} y={yOf(t)} dy="0.32em" textAnchor="end" className="axis-label">
                  {signed(t, tickDigits)}
                </text>
              </g>
            ))}
            {cycle.temperature?.coverline !== null && cycle.temperature?.coverline !== undefined && (
              <g>
                <line x1={TM.left} x2={width - TM.right} y1={yOf(conv(cycle.temperature.coverline))} y2={yOf(conv(cycle.temperature.coverline))} className="coverline" />
                <text x={width - TM.right} y={yOf(conv(cycle.temperature.coverline)) - 5} textAnchor="end" className="axis-label">
                  Cover line
                </text>
              </g>
            )}
            {ovDay && <line x1={xOf(ovDay)} x2={xOf(ovDay)} y1={TM.top} y2={plotBottom} className="ovulation-line" />}
            {lh.map((d) => (
              <path key={d.date} d={`M${xOf(cd(d.date)) - 5},${TM.top} h10 l-5,7 z`} className="lh-mark">
                <title>Positive LH test</title>
              </path>
            ))}
            <path d={line} className="temp-line" />
            {points.map((p) => (
              <circle key={p.date} cx={xOf(cd(p.date))} cy={yOf(conv(p.deviation))} r={p.excluded ? 3.5 : 3} className={p.excluded ? 'temp-dot is-excluded' : 'temp-dot'} />
            ))}
            {bleeding.map((d) => {
              const b = band(cd(d.date), cd(d.date));
              return <rect key={d.date} x={b.x + 1} y={plotBottom + 6} width={Math.max(2, b.w - 2)} height={6} rx={3} className="temp-period" />;
            })}
            {Array.from({ length }, (_, i) => i + 1)
              .filter((d) => d === 1 || d % step === 0)
              .map((d) => (
                <text key={d} x={xOf(d)} y={height - 8} textAnchor="middle" className={`axis-label${shiftDate(cycle.start, d - 1) === today ? ' is-today' : ''}`}>
                  {d}
                </text>
              ))}
            {index !== null && <line x1={xOf(cd(points[index].date))} x2={xOf(cd(points[index].date))} y1={TM.top} y2={plotBottom} className="crosshair" />}
            <rect width={width} height={height} fill="transparent" />
          </svg>
        )}
        {hovered && (
          <Tooltip x={xOf(cd(hovered.date))} y={yOf(conv(hovered.deviation))} width={width}>
            <div className="tooltip-title">
              {fmtDate(hovered.date, {
                weekday: 'short',
                month: 'short',
                day: 'numeric',
              })}{' '}
              · day {cd(hovered.date)}
            </div>
            <div>
              {fmt(temp(hovered.value, units).value, 2)} {temp(0, units).unit} ({signed(conv(hovered.deviation), 2)} {unit})
            </div>
            {hovered.excluded && <div className="muted">{hovered.excluded === 'disturbed' ? 'Left out: marked as possibly off' : 'Left out: far from the nights around it'}</div>}
          </Tooltip>
        )}
      </div>
      <div className="legend temp-legend">
        <span className="legend-item">
          <span className="legend-key rect temp-period" /> Period
        </span>
        <span className="legend-item">
          <span className="legend-key dash coverline-key" /> Cover line
        </span>
        <span className="legend-item">
          <span className="legend-key rect temp-luteal-key" /> After ovulation
        </span>
        <span className="legend-item">○ Left out</span>
        <span className="legend-item">▼ Positive LH test</span>
      </div>
    </>
  );
}

// ---------- calendar ----------

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function CalendarCard({ data, selected, onSelect }: { data: CycleData; selected: string | null; onSelect: (date: string) => void }) {
  const units = useUnits();
  const [month, setMonth] = useState(data.today.slice(0, 7));
  const byDate = useMemo(() => new Map(data.days.map((d) => [d.date, d])), [data.days]);
  const fertility = useMemo(() => new Map((data.fertility ?? []).map((f) => [f.date, f])), [data.fertility]);
  const est = estimateOf(data);
  const predictedEnd = est ? shiftDate(est.nextPeriod.date, (data.stats.periodDays ?? 5) - 1) : null;
  const found = new Set(data.ovulations.map((o) => o.date));

  const first = `${month}-01`;
  const lead = (new Date(`${first}T00:00:00Z`).getUTCDay() + 6) % 7;
  const length = daysBetween(first, `${shiftDate(first, 32).slice(0, 7)}-01`);
  const cells = [...Array(lead).fill(null), ...Array.from({ length }, (_, i) => shiftDate(first, i))];
  const go = (n: number) => setMonth(shiftDate(`${month}-15`, n * 30).slice(0, 7));

  return (
    <section className="card cycle-calendar">
      <div className="card-title-row">
        <h2>{fmtDate(first, { month: 'long', year: 'numeric' })}</h2>
        <div className="btn-row">
          <button className="btn" aria-label="Previous month" onClick={() => go(-1)}>
            <Icon name="chevron-left" size={16} />
          </button>
          <button className="btn" aria-label="Next month" onClick={() => go(1)} disabled={month >= shiftDate(data.today, 62).slice(0, 7)}>
            <Icon name="chevron-right" size={16} />
          </button>
        </div>
      </div>
      <div className="cal-grid" role="grid">
        {WEEKDAYS.map((w) => (
          <span key={w} className="cal-head muted small">
            {w}
          </span>
        ))}
        {cells.map((date, i) => {
          if (!date) return <span key={`pad-${i}`} />;
          const d = byDate.get(date);
          const f = fertility.get(date);
          const future = date > data.today;
          const cls = ['cal-day'];
          const predicted = !isBleeding(d) && est && predictedEnd && date >= data.today && date >= est.nextPeriod.date && date <= predictedEnd;
          if (isBleeding(d)) cls.push('is-period');
          else if (predicted) cls.push('is-predicted');
          else if (f) cls.push(`is-fertile-${f.level}`);
          if (found.has(date)) cls.push('is-ovulation');
          else if (est?.ovulation === date && !data.history?.at(-1)?.ovulation) cls.push('is-ovulation-est');
          if (date === data.today) cls.push('is-today');
          if (date === selected) cls.push('is-selected');
          const marks = d && (d.spotting || d.ovulationTest || d.mucus || d.bbt !== undefined || d.sexualActivity || d.symptoms?.length || d.tempDisturbed);
          const states = [
            predicted && 'expected period',
            f && `${LEVEL_LABEL[f.level].toLowerCase()} fertility, estimated`,
            found.has(date) ? 'ovulation' : cls.includes('is-ovulation-est') && 'estimated ovulation',
            d && describe(d, units),
          ].filter(Boolean);
          return (
            <button
              key={date}
              className={cls.join(' ')}
              disabled={future}
              aria-pressed={date === selected}
              aria-label={[
                fmtDate(date, {
                  weekday: 'long',
                  month: 'long',
                  day: 'numeric',
                }),
                ...states,
              ].join(', ')}
              onClick={() => onSelect(date)}
            >
              {Number(date.slice(8))}
              {marks && <span className={d.spotting ? 'cal-dot is-spot' : d.symptoms?.length ? 'cal-dot is-symptom' : 'cal-dot'} />}
            </button>
          );
        })}
      </div>
      <div className="legend cycle-legend">
        <span className="legend-item">
          <span className="cal-key is-period" /> Period
        </span>
        {est && (
          <>
            <span className="legend-item">
              <span className="cal-key is-predicted" /> Expected period
            </span>
            <span className="legend-item">
              <span className="cal-key is-fertile-high" /> Fertile (estimate)
            </span>
          </>
        )}
        <span className="legend-item">
          <span className="cal-key is-ovulation" /> Ovulation
        </span>
        <span className="legend-item">
          <span className="cal-dot" /> Entries
        </span>
      </div>
    </section>
  );
}

// ---------- logging a day ----------

function Choices<T extends string>({ label, value, options, onChange }: { label: string; value: T | undefined; options: Record<T, string>; onChange: (v: T | undefined) => void }) {
  return (
    <div className="settings-row">
      <span>{label}</span>
      <div className="filters cycle-choices" role="group" aria-label={label}>
        {(Object.keys(options) as T[]).map((k) => (
          <button key={k} className={value === k ? 'on' : ''} aria-pressed={value === k} onClick={() => onChange(value === k ? undefined : k)}>
            {options[k]}
          </button>
        ))}
      </div>
    </div>
  );
}

function LogCard({ date, day, today, onClose, onSaved }: { date: string; day: CycleLogDay | undefined; today: string; onClose: () => void; onSaved: () => void }) {
  const units = useUnits();
  // The whole manual entry for the day: saving replaces it, so every field travels on every save.
  const [f, setF] = useState<CycleFields>(day?.manual ?? {});
  const [bbt, setBbt] = useState(f.bbt === undefined ? '' : fmt(temp(f.bbt, units).value, 2));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const set = (patch: Partial<CycleFields>) => setF((cur) => ({ ...cur, ...patch }));
  const fromApple = day?.apple && describe(day.apple, units);
  const toggleSymptom = (s: Symptom) => {
    const cur = new Set(f.symptoms ?? []);
    if (cur.has(s)) cur.delete(s);
    else cur.add(s);
    set({ symptoms: cur.size ? [...cur].sort() : undefined });
  };

  async function save(fields: CycleFields) {
    setBusy(true);
    setErr(null);
    try {
      let celsius: number | undefined;
      if (bbt.trim() && fields !== CLEARED) {
        const v = Number(bbt.replace(',', '.'));
        if (!Number.isFinite(v)) throw new Error('Enter the temperature as a number.');
        celsius = units === 'imperial' ? ((v - 32) * 5) / 9 : v;
      }
      await sendJson('POST', '/cycle/day', { date, ...fields, bbt: celsius });
      onSaved();
      onClose();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card settings cycle-log">
      <div className="card-title-row">
        <h2>{date === today ? 'Today' : fmtDate(date, { weekday: 'long', month: 'long', day: 'numeric' })}</h2>
        <button className="btn btn-quiet" onClick={onClose}>
          Close
        </button>
      </div>
      {fromApple && <p className="muted small">From Apple Health: {fromApple}. What you log here takes its place, field by field.</p>}
      <Choices<Flow>
        label="Flow"
        value={f.flow}
        options={
          {
            none: 'None',
            light: 'Light',
            medium: 'Medium',
            heavy: 'Heavy',
          } as Record<Flow, string>
        }
        onChange={(flow) => set({ flow })}
      />
      <div className="cycle-checks">
        <label className="check">
          <input type="checkbox" checked={Boolean(f.periodStart)} onChange={(e) => set({ periodStart: e.target.checked || undefined })} />
          <span>First day of my period</span>
        </label>
        <label className="check">
          <input type="checkbox" checked={Boolean(f.spotting)} onChange={(e) => set({ spotting: e.target.checked || undefined })} />
          <span>Spotting</span>
        </label>
      </div>
      <Choices<OvulationTest> label="Ovulation test" value={f.ovulationTest} options={TEST_LABEL} onChange={(ovulationTest) => set({ ovulationTest })} />
      <Choices<CervicalMucus> label="Cervical mucus" value={f.mucus} options={MUCUS_LABEL} onChange={(mucus) => set({ mucus })} />
      <div className="settings-row">
        <span>Symptoms</span>
        <div className="filters cycle-choices" role="group" aria-label="Symptoms">
          {(Object.keys(SYMPTOM_LABEL) as Symptom[]).map((s) => {
            const on = Boolean(f.symptoms?.includes(s));
            return (
              <button key={s} className={on ? 'on' : ''} aria-pressed={on} onClick={() => toggleSymptom(s)}>
                {SYMPTOM_LABEL[s]}
              </button>
            );
          })}
        </div>
      </div>
      <label>
        <span>Basal body temperature ({units === 'imperial' ? '°F' : '°C'}), taken on waking</span>
        <input inputMode="decimal" placeholder={units === 'imperial' ? '97.7' : '36.5'} value={bbt} onChange={(e) => setBbt(e.target.value)} />
      </label>
      <Choices<TempDisturbance> label="Temperature may be off" value={f.tempDisturbed} options={DISTURB_LABEL} onChange={(tempDisturbed) => set({ tempDisturbed })} />
      <p className="muted small">Marking it leaves this morning’s readings, from your thermometer, Watch and WHOOP, out of the analysis.</p>
      <Choices<SexualActivity> label="Sex" value={f.sexualActivity} options={SEX_LABEL} onChange={(sexualActivity) => set({ sexualActivity })} />
      {err && (
        <p className="note-bad">
          <Icon name="alert" size={15} /> {err}
        </p>
      )}
      <div className="btn-row">
        <button className="btn btn-primary" disabled={busy} onClick={() => save(f)}>
          Save
        </button>
        {day?.manual && (
          <button className="btn" disabled={busy} onClick={() => save(CLEARED)}>
            Clear what I logged
          </button>
        )}
      </div>
    </section>
  );
}

const CLEARED: CycleFields = {};

// ---------- history and patterns ----------

function HistoryCard({ data }: { data: CycleData }) {
  const units = useUnits();
  const { stats } = data;
  const recent = (data.history ?? []).slice(-6);
  const longest = Math.max(35, ...recent.map((c) => c.days));
  return (
    <section className="card">
      <div className="card-title-row">
        <h2>Your cycles</h2>
        <span className="muted small">{plural(data.periods.length, 'period')} logged</span>
      </div>
      <div className="cycle-stats">
        <div>
          <span className="muted small">Typical cycle</span>
          <strong>{stats.cycleDays === null ? '–' : `${stats.cycleDays} days`}</strong>
          {stats.shortest !== null && stats.longest !== null && stats.shortest !== stats.longest && (
            <span className="muted small">
              {stats.shortest}–{stats.longest} days
            </span>
          )}
        </div>
        <div>
          <span className="muted small">Period</span>
          <strong>{stats.periodDays === null ? '–' : plural(stats.periodDays, 'day')}</strong>
        </div>
        {stats.lutealDays != null && (
          <div>
            <span className="muted small">After ovulation</span>
            <strong>{plural(stats.lutealDays, 'day')}</strong>
          </div>
        )}
        {stats.regular != null && (
          <div>
            <span className="muted small">Regularity</span>
            <strong>{stats.regular ? 'Regular' : 'Variable'}</strong>
            <span className="muted small">Varies by {plural(stats.variation ?? 0, 'day')}</span>
          </div>
        )}
      </div>
      {recent.length > 0 && (
        <ul className="cycle-bars" aria-label="Recent cycles">
          {recent.map((c) => {
            const pct = (n: number) => `${Math.min(100, (n / longest) * 100)}%`;
            const period = Math.min(c.periodDays ?? 0, c.days);
            const fol = c.follicularDays !== null ? Math.max(0, c.follicularDays - period) : null;
            const lut = c.follicularDays !== null ? Math.max(0, c.days - c.follicularDays) : null;
            const desc = [
              `${fmtDate(c.start)}: ${c.end ? `${c.days} days` : `${c.days} days so far`}`,
              c.periodDays !== null && `period ${c.periodDays} days`,
              c.ovulation && `ovulation on day ${c.follicularDays}${c.status === 'confirmed' ? ' (temperature)' : ' (LH test)'}`,
              c.temperature?.rise != null && `rise ${signed(tempDelta(c.temperature.rise, units).value, 2)}${tempDelta(0, units).unit}`,
            ]
              .filter(Boolean)
              .join(', ');
            return (
              <li key={c.start} aria-label={desc}>
                <span className="muted small">{fmtDate(c.start)}</span>
                <span className={`cycle-bar ${c.end ? '' : 'is-current'}`}>
                  <span className="seg-period" style={{ width: pct(period) }} />
                  {fol !== null && lut !== null ? (
                    <>
                      <span className="seg-follicular" style={{ width: pct(fol) }} />
                      <span className="seg-luteal" style={{ width: pct(lut) }} />
                    </>
                  ) : (
                    <span className="seg-unknown" style={{ width: pct(c.days - period) }} />
                  )}
                </span>
                <span className="small">{c.end ? `${c.days} d` : `${c.days} d…`}</span>
              </li>
            );
          })}
        </ul>
      )}
      <div className="legend">
        <span className="legend-item">
          <span className="legend-key rect seg-period" /> Period
        </span>
        <span className="legend-item">
          <span className="legend-key rect seg-follicular" /> Before ovulation
        </span>
        <span className="legend-item">
          <span className="legend-key rect seg-luteal" /> After ovulation
        </span>
      </div>
    </section>
  );
}

const BODY_LABEL: Record<CycleInsights['body'][number]['metric'], string> = {
  resting_hr: 'Resting heart rate',
  hrv: 'HRV',
  temperature: 'Temperature',
};
const PHASE_WORD: Record<CyclePhase['name'], string> = {
  menstrual: 'during your period',
  follicular: 'before ovulation',
  ovulatory: 'around ovulation',
  luteal: 'after ovulation',
};
const DEVIATION_TEXT: Record<CycleInsights['deviations'][number]['kind'], (d: CycleInsights['deviations'][number]) => string> = {
  frequent: (d) => `${d.count} of your last ${d.of} cycles were shorter than 24 days.`,
  infrequent: (d) => `${d.count} of your last ${d.of} cycles were longer than 38 days.`,
  irregular: (d) => `Your last ${d.of} cycles varied by ${d.spread} days, more than the 7 to 9 days usually seen.`,
  prolonged: (d) => `${d.count} of your last ${d.of} periods lasted more than 8 days.`,
  spotting: (d) => `You logged spotting between periods in ${d.count} of your last ${d.of} cycles.`,
};

function PatternsCard({ insights }: { insights: CycleInsights | undefined }) {
  const units = useUnits();
  const body = insights?.body ?? [];
  const symptoms = insights?.symptoms ?? [];
  const deviations = insights?.deviations ?? [];
  const value = (b: CycleInsights['body'][number], v: number) =>
    b.metric === 'temperature' ? `${signed(tempDelta(v, units).value, 2)} ${tempDelta(0, units).unit}` : `${fmt(v, b.metric === 'resting_hr' ? 1 : 0)} ${b.unit}`;
  return (
    <section className="card cycle-patterns">
      <div className="card-title-row">
        <h2>Patterns</h2>
        <span className="muted small">From your own cycles</span>
      </div>
      {!body.length && !symptoms.length && !deviations.length && (
        <p className="muted small">
          Patterns show after a few cycles: how your resting heart rate, HRV and temperature change after ovulation (once a temperature rise or LH test finds it), and when your
          logged symptoms tend to come.
        </p>
      )}
      {body.length > 0 && (
        <dl className="pattern-body">
          {body.map((b) => (
            <div key={b.metric}>
              <dt>{BODY_LABEL[b.metric]}</dt>
              <dd>
                <span>
                  {value(b, b.follicular)} <span className="muted">→</span> <strong>{value(b, b.luteal)}</strong>
                </span>
                <small>before → after ovulation, {plural(b.cycles, 'cycle')}</small>
              </dd>
            </div>
          ))}
        </dl>
      )}
      {symptoms.length > 0 && (
        <ul className="pattern-symptoms">
          {symptoms.slice(0, 6).map((s) => (
            <li key={s.symptom}>
              <strong>{SYMPTOM_LABEL[s.symptom]}</strong>
              <span className="muted small">
                {s.phase ? `mostly ${PHASE_WORD[s.phase]}` : 'at different points'} · {plural(s.cycles, 'cycle')}
              </span>
            </li>
          ))}
        </ul>
      )}
      {deviations.length > 0 && (
        <div className="pattern-notes">
          {deviations.map((d) => (
            <p key={d.kind} className="small">
              {DEVIATION_TEXT[d.kind](d)}
            </p>
          ))}
          <p className="muted small">Outside the usual ranges (FIGO). Often nothing, but worth mentioning to a clinician if it keeps happening.</p>
        </div>
      )}
    </section>
  );
}

function DeleteCycleData({ onDeleted }: { onDeleted?: () => void }) {
  const [done, setDone] = useState<number | null>(null);
  async function remove() {
    if (!confirm('Delete all your cycle data? This removes everything cycle-related healthOS stores for you, from Apple Health and logged here. It can’t be undone.')) return;
    const r = await sendJson<{ deleted: number }>('POST', '/cycle/delete');
    setDone(r.deleted);
    onDeleted?.();
    notifyDataChanged();
  }
  return (
    <section className="card settings">
      <div>
        <h2>Delete cycle data</h2>
        <p className="muted small">
          Removes every cycle entry healthOS stores for you. Entries from Apple Health come back with your next import or iPhone sync unless you delete them in the Health app or
          turn off healthOS's access to cycle data in iPhone Settings. Your Watch and WHOOP temperatures stay with your other health data.
        </p>
      </div>
      <div className="btn-row">
        <button className="btn btn-danger" onClick={remove}>
          Delete all cycle data
        </button>
        {done !== null && <span className="muted small">{done ? `Deleted ${done} ${done === 1 ? 'entry' : 'entries'}.` : 'There was nothing to delete.'}</span>}
      </div>
    </section>
  );
}

// ---------- Settings ----------

export function CycleSettings({ status, refresh, family = false }: { status: Status; refresh: () => void; family?: boolean }) {
  const { sex, cycleTracking, shareCyclePhase } = status.settings;
  const [busy, setBusy] = useState(false);
  async function save(patch: Partial<Settings>) {
    setBusy(true);
    try {
      await sendJson('PUT', '/settings', patch);
      refresh();
      notifyDataChanged();
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <section className="card settings">
        <div>
          <h2>Health profile</h2>
          <p className="muted small">Only you can see this, except a phase you share with family. Admin screens never show it.</p>
        </div>
        <div className="settings-row">
          <span>Sex for health calculations</span>
          <div className="filters" role="group" aria-label="Sex for health calculations">
            {(['female', 'male', 'unspecified'] as const).map((s) => (
              <button key={s} className={sex === s ? 'on' : ''} aria-pressed={sex === s} disabled={busy} onClick={() => save({ sex: s })}>
                {s === 'female' ? 'Female' : s === 'male' ? 'Male' : 'Prefer not to say'}
              </button>
            ))}
          </div>
        </div>
        <div className="settings-row cycle-switch-row">
          <div>
            <span>Track my cycle</span>
            <p className="muted small">
              Adds a Cycle page for periods, ovulation tests, symptoms and temperature, with estimates of your next period and fertile window. It reads your Apple Watch or WHOOP
              nightly temperature to find ovulation. Ask McFly can read it while this is on.
              {sex === 'female' && !cycleTracking && ' Turn it on whenever you like.'}
            </p>
          </div>
          <button
            className={`switch ${cycleTracking ? 'is-on' : ''}`}
            role="switch"
            aria-checked={cycleTracking}
            aria-label="Track my cycle"
            disabled={busy}
            onClick={() => save({ cycleTracking: !cycleTracking })}
          >
            <span />
          </button>
        </div>
        {cycleTracking && family && (
          <div className="settings-row cycle-switch-row">
            <div>
              <span>Show my cycle phase to family</span>
              <p className="muted small">
                One word on your Family board tile (period, follicular or luteal), never dates or logs. Hidden as your next period approaches. Members will know you track your
                cycle, and looking day after day shows roughly when your period starts.
              </p>
            </div>
            <button
              className={`switch ${shareCyclePhase ? 'is-on' : ''}`}
              role="switch"
              aria-checked={shareCyclePhase}
              aria-label="Show my cycle phase to family"
              disabled={busy}
              onClick={() => save({ shareCyclePhase: !shareCyclePhase })}
            >
              <span />
            </button>
          </div>
        )}
        {!cycleTracking && (
          <p className="muted small">
            While this is off, cycle data from Apple Health is still saved, hidden from every page and from Ask McFly, so your history is there if you turn it on.
          </p>
        )}
      </section>
      <DeleteCycleData />
    </>
  );
}
