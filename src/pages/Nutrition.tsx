// The Nutrition page, its Home card and its Settings card: what a person logs in a food app, read through Apple
// Health, laid out like the Neka reference (tabs, a row of four cards, macro balance beside insights). The server
// has already removed every number the person chose not to see (server/nutrition.ts). This page adds no judgement
// on top: no score, no "remaining" or "on track", nothing over or under, no red or green. A target is one the
// person set, drawn as a plain line. A day with nothing logged is a gap, never a zero.
import { useState } from 'react';
import type { Nutrient, NutritionData, NutritionDay, NutritionNumbers, NutritionTargets, Pattern, Settings, Status } from '../../shared/types.ts';
import { BarChart, ChartCard } from '../charts/Charts.tsx';
import { DayBars, GlassBars } from '../charts/DayBars.tsx';
import { Donut } from '../charts/Donut.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
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
type Tab = 'overview' | 'macros' | 'hydration';
const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'macros', label: 'Macros' },
  { id: 'hydration', label: 'Hydration' },
];

/** A run of calendar days ending at `end`. */
function datesTo(end: string, count: number) {
  return Array.from({ length: count }, (_, i) => shiftDate(end, i - count + 1));
}

const meanOf = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const water = (ml: number, units: Settings['units']) => (units === 'imperial' ? `${fmt(ml / 29.5735)} fl oz` : ml >= 1000 ? `${fmt(ml / 1000, 1)} L` : `${fmt(ml)} mL`);
const glasses = (ml: number) => Math.round((ml / 250) * 2) / 2;

export function Nutrition({ status }: { status: Status }) {
  const [tab, setTab] = useState<Tab>('overview');
  const [days, setDays] = useState(30);
  const { nutrition, nutritionNumbers: numbers } = status.settings;

  if (!nutrition || !numbers) {
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
  // With no amounts, there's nothing for the Macros and Hydration tabs to show.
  const tabs = numbers === 'none' ? TABS.slice(0, 1) : TABS;
  const current = tabs.some((t) => t.id === tab) ? tab : 'overview';
  return (
    <div className="page nutrition-page">
      <header className="page-head">
        <div>
          <h1>Nutrition</h1>
          <p>From the food app you log in, through Apple Health. Only you can see it.</p>
        </div>
        {current !== 'overview' && (
          <div className="filters" role="group" aria-label="Date range">
            {RANGES.map((r) => (
              <button key={r} className={days === r ? 'on' : ''} aria-pressed={days === r} onClick={() => setDays(r)}>
                {r} days
              </button>
            ))}
          </div>
        )}
      </header>
      {tabs.length > 1 && (
        <div className="nutrition-tabs" role="tablist" aria-label="Nutrition">
          {tabs.map((t) => (
            <button key={t.id} role="tab" aria-selected={current === t.id} className={current === t.id ? 'on' : ''} onClick={() => setTab(t.id)}>
              {t.label}
            </button>
          ))}
        </div>
      )}
      {current === 'overview' && <Overview status={status} />}
      {current === 'macros' && <Macros days={days} hosted={status.hosted} />}
      {current === 'hydration' && <Hydration days={days} units={status.settings.units} />}
    </div>
  );
}

function useNutrition(path: string) {
  const { data, error, loading, reload } = useApi<NutritionData>(path);
  const fallback = error ? <div className="page-message">Couldn't load your nutrition: {error.message}</div> : !data ? <div className="page-message">Loading…</div> : null;
  return { data, loading, reload, fallback };
}

// ---------- Overview ----------

/** The last two weeks: the latest day and its week on the cards, the week before only for the protein chip. */
function Overview({ status }: { status: Status }) {
  const { data, loading, fallback } = useNutrition('/nutrition?days=14&insights=1');
  if (!data) return fallback;
  const numbers = data.numbers ?? 'none';
  const byDate = new Map(data.days.map((d) => [d.date, d]));
  const week = datesTo(data.end, 7);
  const before = datesTo(shiftDate(data.end, -7), 7);
  const latest = data.days.at(-1);
  const waterByDate = new Map(data.hydration.water.map((p) => [p.date, p.value]));
  const caffeineByDate = new Map(data.hydration.caffeine.map((p) => [p.date, p.value]));
  const series = (n: Nutrient, dates: string[]) => dates.map((date) => ({ date, value: byDate.get(date)?.values[n] ?? null }));

  if (!latest && !data.hydration.water.length) return <NothingYet hosted={status.hosted} />;
  if (numbers === 'none') {
    return (
      <div className={`grid-2 ${loading ? 'is-refreshing' : ''}`}>
        <LoggedCard data={data} />
        <section className="card">
          <h2>{latest ? relativeDay(latest.date, data.today) : 'Nothing logged lately'}</h2>
          <p className="muted">
            {latest ? `You logged food in ${latest.app}.` : ''} You chose to see no amounts, so this page shows only the days you logged. Change it in{' '}
            <a href={href('settings')}>Settings</a>.
          </p>
        </section>
      </div>
    );
  }
  return (
    <div className={`nutrition-overview ${loading ? 'is-refreshing' : ''}`}>
      <div className={`nutrition-cards ${numbers === 'all' ? '' : 'is-3'}`}>
        {numbers === 'all' && <EnergyCard week={series('energy_kcal', week)} target={data.targets.energy_kcal} today={data.today} />}
        <ProteinCard week={series('protein_g', week)} before={series('protein_g', before)} target={data.targets.protein_g} today={data.today} />
        <WaterCard week={week.map((date) => ({ date, value: waterByDate.get(date) ?? null }))} target={data.targets.water_ml} today={data.today} units={status.settings.units} />
        <LoggedCard data={data} />
      </div>
      <div className="grid-2">
        {latest ? <MacroBalanceCard day={latest} today={data.today} numbers={numbers} caffeine={caffeineByDate.get(latest.date)} /> : <NothingYet hosted={status.hosted} />}
        <FoodInsights insights={data.insights} />
      </div>
    </div>
  );
}

/** The latest day with a value, and its date. */
function lastValue(week: { date: string; value: number | null }[]) {
  for (let i = week.length - 1; i >= 0; i--) if (week[i].value !== null) return week[i] as { date: string; value: number };
  return null;
}

function CardHead({ title, tab }: { title: string; tab?: string }) {
  return (
    <div className="metric-head">
      <span>{title}</span>
      {tab && <span className="muted small">{tab}</span>}
    </div>
  );
}

function EnergyCard({ week, target, today }: { week: { date: string; value: number | null }[]; target?: number; today: string }) {
  const last = lastValue(week);
  return (
    <article className="card metric metric-peach">
      <CardHead title="Energy" tab={last ? relativeDay(last.date, today) : undefined} />
      {last ? (
        <div className="metric-value">
          {fmt(last.value)}
          <small>kcal</small>
        </div>
      ) : (
        <p className="muted small">No calories logged this week.</p>
      )}
      <DayBars days={week} format={(v) => `${fmt(v)} kcal`} target={target} label="Energy, last 7 days" />
      <div className="metric-foot">
        <span>Last 7 days</span>
        {target !== undefined && <span className="target-note">Your target {fmt(target)} kcal</span>}
      </div>
    </article>
  );
}

function ProteinCard({ week, before, target, today }: { week: { date: string; value: number | null }[]; before: { date: string; value: number | null }[]; target?: number; today: string }) {
  const last = lastValue(week);
  const logged = (xs: { value: number | null }[]) => xs.flatMap((x) => (x.value === null ? [] : [x.value]));
  // Logged days only, at least three on each side: a week of gaps isn't a week of eating less.
  const [now, then] = [logged(week), logged(before)];
  const delta = now.length >= 3 && then.length >= 3 ? meanOf(now)! - meanOf(then)! : null;
  return (
    <article className="card metric">
      <CardHead title="Protein" tab={last ? relativeDay(last.date, today) : undefined} />
      {last ? (
        <div className="metric-value">
          {fmt(last.value)}
          <small>grams</small>
        </div>
      ) : (
        <p className="muted small">No protein logged this week.</p>
      )}
      {delta !== null && (
        <span className="chip chip-neutral">{Math.abs(delta) < 1 ? 'About the same as the week before' : `${delta > 0 ? '+' : '−'}${fmt(Math.abs(delta))} g a day vs the week before`}</span>
      )}
      <DayBars days={week} format={(v) => `${fmt(v)} g`} target={target} label="Protein, last 7 days" />
      <div className="metric-foot">
        <span>Last 7 days</span>
        {target !== undefined && <span className="target-note">Your target {fmt(target)} g</span>}
      </div>
    </article>
  );
}

function WaterCard({ week, target, today, units }: { week: { date: string; value: number | null }[]; target?: number; today: string; units: Settings['units'] }) {
  const last = lastValue(week);
  return (
    <article className="card metric">
      <CardHead title="Water" tab={last ? relativeDay(last.date, today) : undefined} />
      {last ? (
        <div className="metric-value">
          {fmt(glasses(last.value), glasses(last.value) % 1 ? 1 : 0)}
          <small>
            {glasses(last.value) === 1 ? 'glass' : 'glasses'} · {water(last.value, units)}
          </small>
        </div>
      ) : (
        <p className="muted small">No water logged this week.</p>
      )}
      <GlassBars days={week} format={(ml) => `${fmt(glasses(ml), glasses(ml) % 1 ? 1 : 0)} glasses · ${water(ml, units)}`} target={target} label="Water in glasses, last 7 days" />
      <div className="metric-foot">
        <span>1 glass = {units === 'imperial' ? '8.5 fl oz' : '250 mL'}</span>
        {target !== undefined && <span className="target-note">Your target {water(target, units)}</span>}
      </div>
    </article>
  );
}

/** Protein, carbs and fat by weight for the latest day, the rest of the day's food beneath. */
function MacroBalanceCard({ day, today, numbers, caffeine }: { day: NutritionDay; today: string; numbers: NutritionNumbers; caffeine?: number }) {
  const parts = MACROS.flatMap((m) => (day.values[m.key] === undefined ? [] : [{ key: m.key, label: NUTRIENT[m.key].name, value: day.values[m.key]!, color: m.color }]));
  const total = parts.reduce((a, p) => a + p.value, 0);
  const energy = numbers === 'all' ? day.values.energy_kcal : undefined;
  const footer: { label: string; value: string }[] = [
    ...(['fiber_g', 'sugar_g', 'sodium_mg'] as const).flatMap((n) => (day.values[n] === undefined ? [] : [{ label: n === 'sugar_g' ? 'Sugar (total)' : NUTRIENT[n].name, value: amount(n, day.values[n]!) }])),
    ...(caffeine !== undefined ? [{ label: 'Caffeine', value: `${fmt(caffeine)} mg` }] : []),
  ];
  return (
    <section className="card macro-balance">
      <div className="nutrition-day-head">
        <h2>Macro balance</h2>
        <span className="muted small">
          {relativeDay(day.date, today)} · {day.app}
        </span>
      </div>
      {total > 0 ? (
        <div className="macro-balance-body">
          <Donut
            parts={parts}
            label={`By weight: ${parts.map((p) => `${p.label.toLowerCase()} ${Math.round((p.value / total) * 100)}%`).join(', ')}`}
            center={
              energy !== undefined ? (
                <>
                  <strong>{fmt(energy)}</strong>
                  <span>kcal</span>
                </>
              ) : (
                <span>by weight</span>
              )
            }
          />
          <ul className="macro-list">
            {parts.map((p) => (
              <li key={p.key}>
                <i style={{ background: p.color }} />
                <span>{p.label}</span>
                <strong>{fmt(p.value)} g</strong>
                <span className="muted">{Math.round((p.value / total) * 100)}%</span>
              </li>
            ))}
          </ul>
        </div>
      ) : (
        <p className="muted">No protein, carbs or fat logged that day.</p>
      )}
      {footer.length > 0 && (
        <dl className="macro-foot">
          {footer.map((f) => (
            <div key={f.label}>
              <dt>{f.label}</dt>
              <dd>{f.value}</dd>
            </div>
          ))}
        </dl>
      )}
    </section>
  );
}

const PATTERN_ICON: Record<string, IconName> = { moon: 'moon', heart: 'heart', steps: 'steps', sun: 'sun', spark: 'spark', 'trend-up': 'chart', 'trend-down': 'chart' };

function FoodInsights({ insights }: { insights: Pattern[] }) {
  return (
    <section className="card food-insights">
      <h2>Insights</h2>
      {insights.length ? (
        <ul>
          {insights.map((p) => (
            <li key={p.id}>
              <span className="food-insight-icon">
                <Icon name={PATTERN_ICON[p.icon] ?? 'spark'} size={16} />
              </span>
              <div>
                <p>{p.text}</p>
                <p className="muted small">{p.detail} Days that go together, not proof that one causes the other.</p>
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <p className="muted">
          Patterns show up here once there are a few weeks of logs to compare: caffeine and that night's sleep, and drinks and the next morning's HRV.
        </p>
      )}
    </section>
  );
}

// ---------- Macros ----------

function Macros({ days, hosted }: { days: number; hosted: boolean }) {
  const { data, loading, reload, fallback } = useNutrition(`/nutrition?days=${days}`);
  if (!data) return fallback;
  const latest = data.days.at(-1);
  if (!latest) return <NothingYet hosted={hosted} />;
  const charted = ORDER.filter((n) => data.days.some((d) => d.values[n] !== undefined));
  return (
    <div className={`nutrition-tab ${loading ? 'is-refreshing' : ''}`}>
      <div className="grid-2">
        <DayCard day={latest} today={data.today} numbers={data.numbers ?? 'none'} />
        <LoggedCard data={data} />
      </div>
      {charted.length > 0 && (
        <div className="grid-2">
          {charted.map((n) => (
            <NutrientChart key={n} nutrient={n} days={data.days} target={n === 'energy_kcal' || n === 'protein_g' ? data.targets[n] : undefined} />
          ))}
        </div>
      )}
      {data.apps.length > 1 && <AppChoice data={data} onSaved={reload} />}
      <p className="muted small nutrition-foot">
        Days with nothing logged are left out, not counted as zero. When two apps logged the same day, one is shown and the other isn't added in, because food apps often copy each
        other's entries through Apple Health.
      </p>
    </div>
  );
}

// ---------- Hydration ----------

function Hydration({ days, units }: { days: number; units: Settings['units'] }) {
  const { data, loading, fallback } = useNutrition(`/nutrition?days=${days}`);
  if (!data) return fallback;
  const { water: w, caffeine } = data.hydration;
  return (
    <div className={`nutrition-tab ${loading ? 'is-refreshing' : ''}`}>
      {!w.length && !caffeine.length ? (
        <section className="card">
          <h2>No water or caffeine logged</h2>
          <p className="muted">Apps that log drinks, like WaterMinder or your food app, write water and caffeine to Apple Health, and they show up here.</p>
        </section>
      ) : (
        <div className="grid-2">
          <ChartCard
            title="Water"
            note={`${w.length} ${w.length === 1 ? 'day' : 'days'} logged · 1 glass = ${units === 'imperial' ? '8.5 fl oz' : '250 mL'}`}
            table={{ columns: ['Date', units === 'imperial' ? 'Water (fl oz)' : 'Water (mL)', 'Glasses'], rows: [...w].reverse().map((p) => [fmtDate(p.date, { month: 'short', day: 'numeric', year: 'numeric' }), water(p.value, units), fmt(glasses(p.value), 1)]) }}
          >
            <BarChart
              points={w}
              format={(v) => water(v, units)}
              tickFormat={(v) => (units === 'imperial' ? fmt(v / 29.5735) : fmt(v))}
              height={200}
              goal={data.targets.water_ml ? { value: data.targets.water_ml, label: 'Your target' } : undefined}
              label="Water by day"
            />
          </ChartCard>
          <ChartCard
            title="Caffeine"
            note={`${caffeine.length} ${caffeine.length === 1 ? 'day' : 'days'} logged · daily total`}
            table={{ columns: ['Date', 'Caffeine (mg)'], rows: [...caffeine].reverse().map((p) => [fmtDate(p.date, { month: 'short', day: 'numeric', year: 'numeric' }), fmt(p.value)]) }}
          >
            <BarChart points={caffeine} format={(v) => `${fmt(v)} mg`} tickFormat={(v) => fmt(v)} height={200} label="Caffeine by day" />
          </ChartCard>
        </div>
      )}
    </div>
  );
}

// ---------- shared pieces ----------

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

function NutrientChart({ nutrient, days, target }: { nutrient: Nutrient; days: NutritionDay[]; target?: number }) {
  const points = days.flatMap((d) => (d.values[nutrient] === undefined ? [] : [{ date: d.date, value: d.values[nutrient]! }]));
  const { name, unit } = NUTRIENT[nutrient];
  return (
    <ChartCard
      title={name}
      note={`${points.length} ${points.length === 1 ? 'day' : 'days'} logged · median line`}
      table={{ columns: ['Date', `${name} (${unit})`], rows: [...points].reverse().map((p) => [fmtDate(p.date, { month: 'short', day: 'numeric', year: 'numeric' }), fmt(p.value)]) }}
    >
      <BarChart
        points={points}
        format={(v) => amount(nutrient, v)}
        tickFormat={(v) => fmt(v)}
        height={180}
        goal={target !== undefined ? { value: target, label: 'Your target' } : undefined}
        label={`${name} by day`}
      />
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
              family, never the admin screens. Ask McFly can read it while this is on, only as much as you choose to see. healthOS never suggests a target.
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
        {nutrition && nutritionNumbers !== 'none' && <TargetInputs status={status} save={save} busy={busy} />}
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

const TARGETS: { key: keyof NutritionTargets; label: string; unit: string; energy?: boolean }[] = [
  { key: 'energy_kcal', label: 'Calories', unit: 'kcal', energy: true },
  { key: 'protein_g', label: 'Protein', unit: 'g' },
  { key: 'water_ml', label: 'Water', unit: 'mL' },
];

/** Your own targets, each optional and blank by default. Shown as a plain line on the charts, never as a score. */
function TargetInputs({ status, save, busy }: { status: Status; save: (patch: Partial<Settings>) => Promise<void>; busy: boolean }) {
  const { nutritionTargets: targets, nutritionNumbers } = status.settings;
  const shown = TARGETS.filter((t) => !t.energy || nutritionNumbers === 'all');
  const [draft, setDraft] = useState(() => Object.fromEntries(shown.map((t) => [t.key, targets[t.key] === null ? '' : String(targets[t.key])])) as Record<string, string>);
  const commit = (key: keyof NutritionTargets) => {
    const raw = draft[key]?.trim() ?? '';
    const next = raw === '' ? null : Number(raw);
    if (next === targets[key] || (next !== null && !Number.isFinite(next))) return;
    void save({ nutritionTargets: { ...targets, [key]: next } });
  };
  return (
    <div className="settings-row">
      <span>Your targets (optional)</span>
      <p className="muted small">Leave blank for none. A target you set shows as a plain line on your charts, nothing more.</p>
      <div className="target-inputs">
        {shown.map((t) => (
          <label key={t.key}>
            <span className="muted small">{t.label}</span>
            <span className="target-field">
              <input
                inputMode="numeric"
                value={draft[t.key] ?? ''}
                disabled={busy}
                placeholder="None"
                aria-label={`${t.label} target in ${t.unit}`}
                onChange={(e) => setDraft({ ...draft, [t.key]: e.target.value.replace(/[^\d]/g, '') })}
                onBlur={() => commit(t.key)}
              />
              <span className="muted small">{t.unit}</span>
            </span>
          </label>
        ))}
      </div>
    </div>
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
