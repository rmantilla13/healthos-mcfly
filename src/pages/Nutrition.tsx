// The Nutrition page, its Home card and its Settings card: what a person logs in a food app, read through Apple
// Health. The server has already removed every number the person chose not to see (server/nutrition.ts). This
// page adds no judgement on top: no targets or "remaining", nothing over or under, no red or green, and a day
// with nothing logged is just a gap, never a zero.
import { useState } from 'react';
import type { Nutrient, NutritionData, NutritionDay, NutritionNumbers, Settings, Status } from '../../shared/types.ts';
import { BarChart, ChartCard } from '../charts/Charts.tsx';
import { Icon } from '../components/Icon.tsx';
import { fmt, fmtDate, href, notifyDataChanged, relativeDay, sendJson, shiftDate, useApi } from '../lib.ts';

const NUTRIENT: Record<Nutrient, { name: string; unit: string }> = {
  energy_kcal: { name: 'Energy', unit: 'kcal' },
  protein_g: { name: 'Protein', unit: 'g' },
  carbs_g: { name: 'Carbs', unit: 'g' },
  fat_g: { name: 'Fat', unit: 'g' },
  fiber_g: { name: 'Fiber', unit: 'g' },
  sugar_g: { name: 'Sugar', unit: 'g' },
  sat_fat_g: { name: 'Saturated fat', unit: 'g' },
  sodium_mg: { name: 'Sodium', unit: 'mg' },
  alcohol_drinks: { name: 'Alcoholic drinks', unit: 'drinks' },
};
const ORDER = Object.keys(NUTRIENT) as Nutrient[];
/** The three that make up most of a day's food, shown as one split of grams. */
const MACROS: { key: Nutrient; color: string }[] = [
  { key: 'protein_g', color: 'var(--series-1)' },
  { key: 'carbs_g', color: 'var(--series-3)' },
  { key: 'fat_g', color: 'var(--series-2)' },
];

const amount = (n: Nutrient, v: number) => `${fmt(v)} ${n === 'alcohol_drinks' ? (Math.round(v) === 1 ? 'drink' : 'drinks') : NUTRIENT[n].unit}`;

const CHOICES: { value: NutritionNumbers; title: string; text: string }[] = [
  { value: 'all', title: 'Everything', text: 'Calories, protein, carbs, fat, fiber, sugar, sodium and drinks.' },
  { value: 'no_energy', title: 'Everything except calories', text: 'The same, with no calories anywhere, Ask McFly included.' },
  { value: 'none', title: 'No amounts', text: 'Only which days you logged. No numbers at all.' },
];

// ---------- the page ----------

const RANGES = [7, 30, 90];

export function Nutrition({ status }: { status: Status }) {
  const [days, setDays] = useState(30);
  const { data, error, loading, reload } = useApi<NutritionData>(status.settings.nutrition ? `/nutrition?days=${days}` : null);

  if (!status.settings.nutrition || data?.enabled === false) {
    return (
      <div className="page">
        <header className="page-head">
          <div>
            <h1>Nutrition</h1>
            <p>Nutrition is off.</p>
          </div>
        </header>
        <section className="card">
          <p className="muted">
            Turn on nutrition in <a href={href('settings')}>Settings</a> to see what you log in a food app like MyFitnessPal or Cronometer next to your sleep and recovery.
          </p>
        </section>
      </div>
    );
  }
  if (error) return <div className="page-message">Couldn't load your nutrition: {error.message}</div>;
  if (!data) return <div className="page-message">Loading…</div>;

  const latest = data.days.at(-1);
  const charted = ORDER.filter((n) => data.days.some((d) => d.values[n] !== undefined));
  return (
    <div className={`page nutrition-page ${loading ? 'is-refreshing' : ''}`}>
      <header className="page-head">
        <div>
          <h1>Nutrition</h1>
          <p>From the food app you log in, through Apple Health. Only you can see it.</p>
        </div>
        <div className="filters" role="group" aria-label="Date range">
          {RANGES.map((r) => (
            <button key={r} className={days === r ? 'on' : ''} aria-pressed={days === r} onClick={() => setDays(r)}>
              {r} days
            </button>
          ))}
        </div>
      </header>

      {!latest ? (
        <NothingYet hosted={status.hosted} />
      ) : (
        <>
          <div className="grid-2">
            <DayCard day={latest} today={data.today} numbers={data.numbers ?? 'none'} />
            <LoggedCard data={data} />
          </div>
          {charted.length > 0 && (
            <div className="grid-2">
              {charted.map((n) => (
                <NutrientChart key={n} nutrient={n} days={data.days} />
              ))}
            </div>
          )}
          {data.apps.length > 1 && <AppChoice data={data} onSaved={reload} />}
          <p className="muted small nutrition-foot">
            Days with nothing logged are left out, not counted as zero. When two apps logged the same day, one is shown and the other isn't added in, because food apps often copy
            each other's entries through Apple Health.
          </p>
        </>
      )}
    </div>
  );
}

/** The export import runs only on a Mac with healthOS running, so the hosted site points to the iPhone app alone. */
function NothingYet({ hosted }: { hosted: boolean }) {
  return (
    <section className="card nutrition-empty">
      <h2>Nothing logged yet</h2>
      <p className="muted">
        healthOS reads what your food app writes to Apple Health: MyFitnessPal, Cronometer, Lose It!, MacroFactor and Yazio all can. Turn on its Apple Health connection in
        that app.
        {hosted ? ' Your food log comes in once the healthOS iPhone app is updated to read it.' : ' Then bring it in here:'}
      </p>
      {!hosted && (
        <ul className="muted">
          <li>
            Import your Health export again from <a href={href('integrations')}>Integrations</a>.
          </li>
          <li>Or let the healthOS iPhone app send it, once it's updated to read food.</li>
        </ul>
      )}
    </section>
  );
}

function DayCard({ day, today, numbers }: { day: NutritionDay; today: string; numbers: NutritionNumbers }) {
  const shown = ORDER.filter((n) => day.values[n] !== undefined);
  const macros = MACROS.filter((m) => day.values[m.key] !== undefined);
  const total = macros.reduce((a, m) => a + day.values[m.key]!, 0);
  return (
    <section className="card nutrition-day">
      <div className="nutrition-day-head">
        <h2>{relativeDay(day.date, today)}</h2>
        <span className="chip">{day.app}</span>
      </div>
      {numbers === 'none' || !shown.length ? (
        <p className="muted">
          You logged food in {day.app}
          {day.otherApps.length ? ` and ${day.otherApps.join(', ')}` : ''}.
        </p>
      ) : (
        <>
          <dl className="nutrition-values">
            {shown.map((n) => (
              <div key={n}>
                <dt>{NUTRIENT[n].name}</dt>
                <dd>{amount(n, day.values[n]!)}</dd>
              </div>
            ))}
          </dl>
          {macros.length === 3 && total > 0 && (
            <div className="macro-split" role="img" aria-label={`By weight: ${macros.map((m) => `${NUTRIENT[m.key].name.toLowerCase()} ${Math.round((day.values[m.key]! / total) * 100)}%`).join(', ')}`}>
              <div className="macro-bar">
                {macros.map((m) => (
                  <i key={m.key} style={{ flexGrow: day.values[m.key]!, background: m.color }} />
                ))}
              </div>
              <div className="macro-legend">
                {macros.map((m) => (
                  <span key={m.key}>
                    <i style={{ background: m.color }} />
                    {NUTRIENT[m.key].name} {Math.round((day.values[m.key]! / total) * 100)}%
                  </span>
                ))}
                <span className="muted">by weight</span>
              </div>
            </div>
          )}
          {day.otherApps.length > 0 && <p className="muted small">Also logged in {day.otherApps.join(', ')}, not added in.</p>}
        </>
      )}
    </section>
  );
}

/** Every day of the window, filled where something was logged. A plain record, not a streak. */
function LoggedCard({ data }: { data: NutritionData }) {
  const logged = new Set(data.days.map((d) => d.date));
  const dates: string[] = [];
  for (let d = data.start; d <= data.end; d = shiftDate(d, 1)) dates.push(d);
  return (
    <section className="card nutrition-logged">
      <h2>Days logged</h2>
      <p className="metric-strong">
        {logged.size} of {dates.length} days
      </p>
      <div className={`logged-strip ${dates.length > 31 ? 'is-dense' : ''}`} role="img" aria-label={`Logged on ${logged.size} of the last ${dates.length} days`}>
        {dates.map((d) => (
          <i key={d} className={logged.has(d) ? 'on' : ''} title={fmtDate(d, { weekday: 'short', month: 'short', day: 'numeric' })} />
        ))}
      </div>
      <div className="metric-foot">
        <span>{fmtDate(data.start)}</span>
        <span>{fmtDate(data.end)}</span>
      </div>
    </section>
  );
}

function NutrientChart({ nutrient, days }: { nutrient: Nutrient; days: NutritionDay[] }) {
  const points = days.flatMap((d) => (d.values[nutrient] === undefined ? [] : [{ date: d.date, value: d.values[nutrient]! }]));
  const { name, unit } = NUTRIENT[nutrient];
  return (
    <ChartCard
      title={name}
      note={`${points.length} ${points.length === 1 ? 'day' : 'days'} logged · median line`}
      table={{ columns: ['Date', `${name} (${unit})`], rows: [...points].reverse().map((p) => [fmtDate(p.date, { month: 'short', day: 'numeric', year: 'numeric' }), fmt(p.value)]) }}
    >
      <BarChart points={points} format={(v) => amount(nutrient, v)} tickFormat={(v) => fmt(v)} height={180} label={`${name} by day`} />
    </ChartCard>
  );
}

function AppChoice({ data, onSaved }: { data: NutritionData; onSaved: () => void }) {
  const save = async (app: string | null) => {
    await sendJson('PUT', '/settings', { nutritionApp: app });
    onSaved();
    notifyDataChanged();
  };
  return (
    <section className="card settings">
      <div>
        <h2>On days two apps logged</h2>
        <p className="muted small">Use one app's totals. Automatic picks whichever logged the most that day.</p>
      </div>
      <div className="filters nutrition-apps" role="group" aria-label="App to use">
        {[null, ...data.apps].map((app) => (
          <button key={app ?? 'auto'} className={data.app === app ? 'on' : ''} aria-pressed={data.app === app} onClick={() => save(app)}>
            {app ?? 'Automatic'}
          </button>
        ))}
      </div>
    </section>
  );
}

// ---------- the Home card ----------

/** A strip under the Home cards, only for people who turned nutrition on. Its own request: Summary stays food-free. */
export function NutritionCard() {
  const { data } = useApi<NutritionData>('/nutrition?days=7');
  if (!data?.enabled) return null;
  const latest = data.days.at(-1);
  const logged = new Set(data.days.map((d) => d.date));
  const dates: string[] = [];
  for (let d = data.start; d <= data.end; d = shiftDate(d, 1)) dates.push(d);
  const shown = latest ? ORDER.filter((n) => latest.values[n] !== undefined && n !== 'sat_fat_g' && n !== 'sodium_mg').slice(0, 5) : [];
  return (
    <article className="card nutrition-card">
      <div className="metric-head">
        <span>Food</span>
        <a href={href('nutrition')} className="metric-link" aria-label="Open Nutrition">
          <Icon name="arrow-up-right" size={16} />
        </a>
      </div>
      <div className="nutrition-card-body">
        {!latest ? (
          <p className="muted small">Nothing logged in the last 7 days.</p>
        ) : shown.length ? (
          <dl className="nutrition-values is-row">
            {shown.map((n) => (
              <div key={n}>
                <dt>{NUTRIENT[n].name}</dt>
                <dd>{amount(n, latest.values[n]!)}</dd>
              </div>
            ))}
          </dl>
        ) : (
          <p className="metric-strong">Logged in {latest.app}</p>
        )}
        <div className="nutrition-card-side">
          <div className="logged-strip is-week" role="img" aria-label={`Logged on ${logged.size} of the last 7 days`}>
            {dates.map((d) => (
              <i key={d} className={logged.has(d) ? 'on' : ''} title={fmtDate(d, { weekday: 'short' })} />
            ))}
          </div>
          <span className="muted small">{latest ? `${relativeDay(latest.date, data.today)} · ${latest.app}` : 'Last 7 days'}</span>
        </div>
      </div>
    </article>
  );
}

// ---------- Settings ----------

export function NutritionSettings({ status, refresh }: { status: Status; refresh: () => void }) {
  const { nutrition, nutritionNumbers } = status.settings;
  const [choosing, setChoosing] = useState(false);
  const [busy, setBusy] = useState(false);
  async function save(patch: Partial<Settings>) {
    setBusy(true);
    try {
      await sendJson('PUT', '/settings', patch);
      refresh();
      notifyDataChanged();
    } finally {
      setBusy(false);
      setChoosing(false);
    }
  }
  return (
    <>
      <section className="card settings">
        <div className="settings-row cycle-switch-row">
          <div>
            <h2>Nutrition</h2>
            <p className="muted small">
              Reads what you log in a food app (MyFitnessPal, Cronometer, Lose It!, MacroFactor, Yazio) from Apple Health, as daily totals. Only you can see it: never your
              family, never the admin screens. Ask McFly can read it while this is on, only as much as you choose to see. healthOS sets no targets.
            </p>
          </div>
          <button
            className={`switch ${nutrition ? 'is-on' : ''}`}
            role="switch"
            aria-checked={nutrition}
            aria-label="Show my nutrition"
            disabled={busy}
            onClick={() => (nutrition ? save({ nutrition: false }) : setChoosing(!choosing))}
          >
            <span />
          </button>
        </div>
        {(choosing || nutrition) && (
          <div className="settings-row">
            <span>{nutrition ? 'What you see' : 'First, choose what you want to see. You can change it any time.'}</span>
            <div className="choice-list" role="group" aria-label="What you see">
              {CHOICES.map((c) => (
                <button
                  key={c.value}
                  className={`choice ${nutrition && nutritionNumbers === c.value ? 'on' : ''}`}
                  aria-pressed={nutrition && nutritionNumbers === c.value}
                  disabled={busy}
                  onClick={() => save(nutrition ? { nutritionNumbers: c.value } : { nutrition: true, nutritionNumbers: c.value })}
                >
                  <strong>{c.title}</strong>
                  <span className="muted small">{c.text}</span>
                </button>
              ))}
            </div>
          </div>
        )}
        <p className="muted small">
          {!nutrition
            ? "While this is off, healthOS doesn't read or keep your food logs."
            : status.hosted
              ? 'Your food log comes in from the healthOS iPhone app once it’s updated to read food.'
              : 'History comes in with your next Health export import, or from the iPhone app once it reads food.'}
        </p>
      </section>
      <DeleteNutritionData />
    </>
  );
}

function DeleteNutritionData() {
  const [done, setDone] = useState<number | null>(null);
  async function remove() {
    if (!confirm('Delete all your nutrition data? This removes every food total healthOS stores for you. It can’t be undone.')) return;
    const r = await sendJson<{ deleted: number }>('POST', '/nutrition/delete');
    setDone(r.deleted);
    notifyDataChanged();
  }
  return (
    <section className="card settings">
      <div>
        <h2>Delete nutrition data</h2>
        <p className="muted small">
          Removes every food total healthOS stores for you, whether nutrition is on or off. With nutrition on, your next import or iPhone sync brings back what's still in Apple
          Health.
        </p>
      </div>
      <div className="btn-row">
        <button className="btn btn-danger" onClick={remove}>
          Delete all nutrition data
        </button>
        {done !== null && <span className="muted small">{done ? 'Deleted.' : 'There was nothing to delete.'}</span>}
      </div>
    </section>
  );
}
