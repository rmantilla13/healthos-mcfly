// Cycle tracking: the Cycle page (shown only when tracking is on) and its card in Settings.
// The data comes from GET /api/cycle on its own, never from the summary, so nothing else on the
// dashboard (or Ask McFly's summary tool) carries it.
import { useState } from 'react';
import type { CervicalMucus, CycleData, CycleFields, CycleLogDay, Flow, OvulationTest, Settings, SexualActivity, Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { daysBetween, fmt, fmtDate, href, notifyDataChanged, sendJson, shiftDate, temp, useApi, useUnits } from '../lib.ts';

const FLOW_LABEL: Record<Flow, string> = { none: 'None', unspecified: 'Some', light: 'Light', medium: 'Medium', heavy: 'Heavy' };
const TEST_LABEL: Record<OvulationTest, string> = { negative: 'Negative', lh_surge: 'LH surge', estrogen_surge: 'Estrogen surge', indeterminate: 'Unclear' };
const MUCUS_LABEL: Record<CervicalMucus, string> = { dry: 'Dry', sticky: 'Sticky', creamy: 'Creamy', watery: 'Watery', egg_white: 'Egg white' };
const SEX_LABEL: Record<SexualActivity, string> = { protected: 'Protected', unprotected: 'Unprotected', unspecified: 'Not noted' };
const BASIS: Record<string, string> = { lh_test: 'your LH test this cycle', bbt: 'your temperature rise this cycle' };

const isBleeding = (d: CycleFields | undefined) => d?.flow !== undefined && d.flow !== 'none';
const range = (a: string, b: string) => (a === b ? fmtDate(a) : `${fmtDate(a)} – ${fmtDate(b)}`);
const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;

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
  if (f.sexualActivity) parts.push(`sex (${SEX_LABEL[f.sexualActivity].toLowerCase()})`);
  return parts.join(', ');
}

export function Cycle({ status }: { status: Status }) {
  const { data, error, reload } = useApi<CycleData>('/cycle?days=400');
  const [selected, setSelected] = useState<string | null>(null);

  if (!status.settings.cycleTracking || data?.enabled === false) {
    return (
      <div className="page">
        <header className="page-head">
          <div>
            <h1>Cycle</h1>
            <p>Cycle tracking is off.</p>
          </div>
        </header>
        <section className="card">
          <p className="muted">
            Turn on cycle tracking in <a href={href('settings')}>Settings</a> to log periods and see estimates of your next one.
          </p>
        </section>
      </div>
    );
  }
  if (error) return <div className="page-message">Couldn't load your cycle: {error.message}</div>;
  if (!data) return <div className="page-message">Loading…</div>;

  return (
    <div className="page cycle-page">
      <header className="page-head">
        <div>
          <h1>Cycle</h1>
          <p>From Apple Health and what you log here. Only you can see it.</p>
        </div>
        <button className="btn" onClick={() => setSelected(data.today)}>
          Log today
        </button>
      </header>
      <div className="grid-2">
        <NowCard data={data} />
        <HistoryCard data={data} />
      </div>
      <div className="cycle-main">
        <CalendarCard data={data} selected={selected} onSelect={setSelected} />
        {selected && (
          <LogCard
            key={selected}
            date={selected}
            day={data.days.find((d) => d.date === selected)}
            today={data.today}
            onClose={() => setSelected(null)}
            onSaved={reload}
          />
        )}
      </div>
      <DeleteCycleData onDeleted={reload} />
    </div>
  );
}

function NowCard({ data }: { data: CycleData }) {
  const { current, estimate, today } = data;
  const next = estimate?.nextPeriod;
  const until = next ? daysBetween(today, next.date) : null;
  return (
    <section className="card cycle-now">
      <div className="card-title-row">
        <h2>This cycle</h2>
        {estimate && <span className="pill">Estimate</span>}
      </div>
      {current ? (
        <p className="cycle-day">
          <span className="cycle-day-n">Day {current.day}</span>
          <span className="muted">Period started {fmtDate(current.start)}</span>
        </p>
      ) : (
        <p className="muted">No period logged yet. Log the first day of your next one, or import your Apple Health history.</p>
      )}
      {estimate && next && until !== null ? (
        <dl className="cycle-facts">
          <div>
            <dt>Next period</dt>
            <dd>
              {until > 0 ? `Around ${fmtDate(next.date)}, in ${plural(until, 'day')}` : until === 0 ? 'Expected around today' : `Expected ${fmtDate(next.date)}, ${plural(-until, 'day')} ago`}
              <small>Usually {range(next.earliest, next.latest)}</small>
            </dd>
          </div>
          <div>
            <dt>Fertile window</dt>
            <dd>
              {range(estimate.fertile.start, estimate.fertile.end)}
              <small>Ovulation around {fmtDate(estimate.ovulation)}</small>
            </dd>
          </div>
        </dl>
      ) : (
        current && (
          <p className="muted small">
            {data.noEstimate === 'stale'
              ? `Your latest logged period started ${fmtDate(current.start)}. Log your most recent one to see estimates again.`
              : 'Estimates appear after two complete cycles: three period starts.'}
          </p>
        )
      )}
      {estimate && (
        <p className="muted small cycle-caveat">
          Estimated from {estimate.basis === 'calendar' ? `your last ${plural(estimate.cycles, 'cycle')}` : BASIS[estimate.basis]}. Cycles vary, so these are
          estimates, not medical advice and not reliable as contraception.
        </p>
      )}
    </section>
  );
}

function HistoryCard({ data }: { data: CycleData }) {
  const { stats, cycles, periods } = data;
  const recent = cycles.slice(-6);
  const longest = Math.max(35, ...recent.map((c) => c.days));
  return (
    <section className="card">
      <div className="card-title-row">
        <h2>Your cycles</h2>
        <span className="muted small">{plural(periods.length, 'period')} logged</span>
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
          <span className="muted small">Typical period</span>
          <strong>{stats.periodDays === null ? '–' : plural(stats.periodDays, 'day')}</strong>
        </div>
      </div>
      {recent.length > 0 && (
        <ul className="cycle-bars" aria-label="Recent cycle lengths">
          {recent.map((c) => (
            <li key={c.start}>
              <span className="muted small">{fmtDate(c.start)}</span>
              <span className="cycle-bar">
                <span style={{ width: `${Math.min(100, (c.days / longest) * 100)}%` }} />
              </span>
              <span className="small">{c.days} d</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function CalendarCard({ data, selected, onSelect }: { data: CycleData; selected: string | null; onSelect: (date: string) => void }) {
  const units = useUnits();
  const [month, setMonth] = useState(data.today.slice(0, 7));
  const byDate = new Map(data.days.map((d) => [d.date, d]));
  const est = data.estimate;
  const predictedEnd = est ? shiftDate(est.nextPeriod.date, (data.stats.periodDays ?? 5) - 1) : null;
  const ovulations = new Set(data.ovulations.map((o) => o.date));

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
          const future = date > data.today;
          const cls = ['cal-day'];
          if (isBleeding(d)) cls.push('is-period');
          else if (est && predictedEnd && date >= data.today && date >= est.nextPeriod.date && date <= predictedEnd) cls.push('is-predicted');
          if (est && date >= est.fertile.start && date <= est.fertile.end) cls.push('is-fertile');
          if (est?.ovulation === date || ovulations.has(date)) cls.push('is-ovulation');
          if (date === data.today) cls.push('is-today');
          if (date === selected) cls.push('is-selected');
          const marks = d && (d.spotting || d.ovulationTest || d.mucus || d.bbt !== undefined || d.sexualActivity);
          const states = [
            cls.includes('is-predicted') && 'expected period',
            cls.includes('is-fertile') && 'fertile window, estimated',
            cls.includes('is-ovulation') && (est?.ovulation === date ? 'estimated ovulation' : 'ovulation'),
            d && describe(d, units),
          ].filter(Boolean);
          return (
            <button
              key={date}
              className={cls.join(' ')}
              disabled={future}
              aria-pressed={date === selected}
              aria-label={[fmtDate(date, { weekday: 'long', month: 'long', day: 'numeric' }), ...states].join(', ')}
              onClick={() => onSelect(date)}
            >
              {Number(date.slice(8))}
              {marks && <span className={d.spotting ? 'cal-dot is-spot' : 'cal-dot'} />}
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
              <span className="cal-key is-fertile" /> Fertile window (estimate)
            </span>
          </>
        )}
        <span className="legend-item">
          <span className="cal-key is-ovulation" /> Ovulation
        </span>
        <span className="legend-item">
          <span className="cal-dot" /> Other entries
        </span>
      </div>
    </section>
  );
}

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
  const [f, setF] = useState<CycleFields>(day?.manual ?? {});
  const [bbt, setBbt] = useState(f.bbt === undefined ? '' : fmt(temp(f.bbt, units).value, 2));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const set = (patch: Partial<CycleFields>) => setF((cur) => ({ ...cur, ...patch }));
  const fromApple = day?.apple && describe(day.apple, units);

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
      <Choices<Flow> label="Flow" value={f.flow} options={{ none: 'None', light: 'Light', medium: 'Medium', heavy: 'Heavy' } as Record<Flow, string>} onChange={(flow) => set({ flow })} />
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
      <label>
        <span>Basal body temperature ({units === 'imperial' ? '°F' : '°C'})</span>
        <input inputMode="decimal" placeholder={units === 'imperial' ? '97.7' : '36.5'} value={bbt} onChange={(e) => setBbt(e.target.value)} />
      </label>
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
          Removes every cycle entry healthOS stores for you. Entries from Apple Health come back with your next import or iPhone sync unless you delete them in
          the Health app or turn off healthOS's access to cycle data in iPhone Settings.
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

export function CycleSettings({ status, refresh }: { status: Status; refresh: () => void }) {
  const { sex, cycleTracking } = status.settings;
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
          <p className="muted small">Only you can see this. Admins never see it.</p>
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
              Adds a Cycle page for periods, ovulation tests and temperature, with estimates of your next period and fertile window. Ask McFly can read it while
              this is on.
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
