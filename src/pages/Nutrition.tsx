// The Nutrition page, its Home card and its Settings card: what a person logs in a food app, read through Apple
// Health, laid out like the Neka reference (tabs, a row of four cards, macro balance beside insights). The server
// has already removed every number the person chose not to see (server/nutrition.ts). This page adds no judgement
// on top: no score, no "remaining" or "on track", nothing over or under, no red or green. A target is one the
// person set, drawn as a plain line. A day with nothing logged is a gap, never a zero.
import { type ReactNode, useState } from 'react';
import type { Nutrient, NutritionData, NutritionDay, NutritionNumbers, NutritionTargets, Pattern, Settings, Status } from '../../shared/types.ts';
import { BarChart, ChartCard } from '../charts/Charts.tsx';
import { DayBars, GlassBars } from '../charts/DayBars.tsx';
import { Donut } from '../charts/Donut.tsx';
import { AllHiddenNote, CardRow } from '../components/CardRow.tsx';
import { Icon, type IconName } from '../components/Icon.tsx';
import { PageHead, RANGES, Tabs } from './Detail.tsx';
import { fmt, fmtDate, href, notifyDataChanged, relativeDay, sendJson, shiftDate, useApi, useCardShown, useCardsKnown } from '../lib.ts';

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

type Tab = 'overview' | 'macros' | 'hydration';
const TABS: { id: Tab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'macros', label: 'Macros' },
  { id: 'hydration', label: 'Hydration' },
];
/** Each tab has its own address (#/nutrition?tab=macros), as on Sleep and Body, so the back button works. */
const tabHref = (id: string) => (id === 'overview' ? '#/nutrition' : `#/nutrition?tab=${id}`);

/** A run of calendar days ending at `end`. */
function datesTo(end: string, count: number) {
  return Array.from({ length: count }, (_, i) => shiftDate(end, i - count + 1));
}

const meanOf = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const water = (ml: number, units: Settings['units']) => (units === 'imperial' ? `${fmt(ml / 29.5735)} fl oz` : ml >= 1000 ? `${fmt(ml / 1000, 1)} L` : `${fmt(ml)} mL`);
const glasses = (ml: number) => Math.round((ml / 250) * 2) / 2;

export function Nutrition({ status, params, refresh }: { status: Status; params: URLSearchParams; refresh: () => void }) {
  const [days, setDays] = useState(30);
  const { nutrition, nutritionNumbers: numbers } = status.settings;

  if (!nutrition || !numbers) return <NutritionIntro refresh={refresh} />;
  // With no amounts, there's nothing for the Macros and Hydration tabs to show.
  const tabs = numbers === 'none' ? TABS.slice(0, 1) : TABS;
  const current = tabs.find((t) => t.id === params.get('tab'))?.id ?? 'overview';
  const ranged = current !== 'overview';
  return (
    <div className="page page-wide nutrition-page">
      <PageHead
        title="Nutrition"
        sub="From the food app you log in, through Apple Health. Only you can see it."
        tabs={tabs.length > 1 ? <Tabs tabs={tabs} current={current} hrefOf={tabHref} label="Nutrition" center /> : undefined}
        days={ranged ? days : undefined}
        setDays={ranged ? setDays : undefined}
        ranges={RANGES.filter((r) => r.days <= 90)}
      />
      {current === 'overview' && <Overview status={status} />}
      {current === 'macros' && <Macros days={days} hosted={status.hosted} />}
      {current === 'hydration' && <Hydration days={days} units={status.settings.units} />}
    </div>
  );
}

// ---------- while it's off ----------

/**
 * Nutrition while it's off: what it shows, what stays private, and turning it on from here through the same choice
 * as Settings (what to see first, nothing preselected). Nothing is read or kept until then.
 */
function NutritionIntro({ refresh }: { refresh: () => void }) {
  const [choosing, setChoosing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function turnOn(numbers: NutritionNumbers) {
    setBusy(true);
    setError(null);
    try {
      await sendJson('PUT', '/settings', { nutrition: true, nutritionNumbers: numbers });
      refresh();
      notifyDataChanged();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="page page-wide nutrition-page">
      {/* No tabs here, so no PageHead: its tools row keeps a fixed height for pages that switch tabs. */}
      <header className="page-head">
        <div>
          <h1>Nutrition</h1>
          <p>What you eat, next to how you sleep and recover. Off until you turn it on.</p>
        </div>
      </header>
      <div className="split split-even">
        <section className="card nutrition-intro">
          <h2>What it shows</h2>
          <ul>
            <li>
              <span className="intro-icon">
                <Icon name="nutrition" size={16} />
              </span>
              <div>
                <strong>Your food app's daily totals</strong>
                <span className="muted small">Calories, protein, carbs, fat, fiber, sugar and sodium from MyFitnessPal, Cronometer, Lose It!, MacroFactor or Yazio, through Apple Health.</span>
              </div>
            </li>
            <li>
              <span className="intro-icon">
                <Icon name="chart" size={16} />
              </span>
              <div>
                <strong>Macro balance, water and caffeine</strong>
                <span className="muted small">Your day by weight, the water you log as glasses, and your daily caffeine.</span>
              </div>
            </li>
            <li>
              <span className="intro-icon">
                <Icon name="moon" size={16} />
              </span>
              <div>
                <strong>How it goes with your sleep and HRV</strong>
                <span className="muted small">Patterns from your own days, worded as things that tend to go together, never as causes.</span>
              </div>
            </li>
          </ul>
        </section>
        <section className="card nutrition-intro">
          <h2>What stays private</h2>
          <ul>
            <li>
              <span className="intro-icon">
                <Icon name="shield" size={16} />
              </span>
              <div>
                <strong>Only you see it</strong>
                <span className="muted small">Never on the Family board, never in the admin screens.</span>
              </div>
            </li>
            <li>
              <span className="intro-icon">
                <Icon name="check" size={16} />
              </span>
              <div>
                <strong>You choose how much you see</strong>
                <span className="muted small">Everything, everything except calories, or no amounts at all. Ask McFly sees only that much.</span>
              </div>
            </li>
            <li>
              <span className="intro-icon">
                <Icon name="spark" size={16} />
              </span>
              <div>
                <strong>No scores, streaks or set targets</strong>
                <span className="muted small">Set your own targets later if you like; they show only as a plain line. Turn it off or delete it any time in Settings.</span>
              </div>
            </li>
          </ul>
        </section>
      </div>
      <section className="card nutrition-turn-on">
        {!choosing ? (
          <div className="turn-on-row">
            <p className="muted">Nothing is read or kept until you turn it on.</p>
            <button className="btn btn-primary" onClick={() => setChoosing(true)}>
              Turn on Nutrition
            </button>
          </div>
        ) : (
          <>
            <div>
              <h2>First, choose what you want to see</h2>
              <p className="muted small">You can change it any time in Settings.</p>
            </div>
            <NumbersChoice current={null} busy={busy} onChoose={turnOn} />
            <div className="btn-row">
              <button className="btn btn-quiet" disabled={busy} onClick={() => setChoosing(false)}>
                Cancel
              </button>
            </div>
          </>
        )}
        {error && <p className="note-bad small">{error}</p>}
      </section>
    </div>
  );
}

/** The three ways to see Nutrition, shared by Settings and the page above. Nothing is preselected for someone turning it on. */
function NumbersChoice({ current, busy, onChoose }: { current: NutritionNumbers | null; busy: boolean; onChoose: (numbers: NutritionNumbers) => void }) {
  return (
    <div className="choice-list" role="group" aria-label="What you see">
      {CHOICES.map((c) => (
        <button key={c.value} className={`choice ${current === c.value ? 'on' : ''}`} aria-pressed={current === c.value} disabled={busy} onClick={() => onChoose(c.value)}>
          <strong>{c.title}</strong>
          <span className="muted small">{c.text}</span>
        </button>
      ))}
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
  const shownCard = useCardShown();
  const cardsKnown = useCardsKnown();
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
      <div className={`nutrition-overview ${loading ? 'is-refreshing' : ''}`}>
        <CardRow
          className="split split-even"
          pair
          cards={[
            ['nutrition.logged', <LoggedCard data={data} />],
            [
              'nutrition.none-note',
              <section className="card">
                <h2>{latest ? relativeDay(latest.date, data.today) : 'Nothing logged lately'}</h2>
                <p className="muted">
                  {latest ? `You logged food in ${latest.app}.` : ''} You chose to see no amounts, so this page shows only the days you logged. Change it in{' '}
                  <a href={href('settings')}>Settings</a>.
                </p>
              </section>,
            ],
          ]}
        />
      </div>
    );
  }
  // Rows lay out from the cards left after the ones the person hid (Settings → Cards), like Home, Sleep and Body.
  const cards: [string, ReactNode][] = [
    ...(numbers === 'all' ? ([['nutrition.energy', <EnergyCard week={series('energy_kcal', week)} target={data.targets.energy_kcal} today={data.today} />]] as [string, ReactNode][]) : []),
    ['nutrition.protein', <ProteinCard week={series('protein_g', week)} before={series('protein_g', before)} target={data.targets.protein_g} today={data.today} />],
    ['nutrition.water', <WaterCard week={week.map((date) => ({ date, value: waterByDate.get(date) ?? null }))} target={data.targets.water_ml} today={data.today} units={status.settings.units} />],
    ['nutrition.logged', <LoggedCard data={data} />],
  ];
  // Every card this setting would show is hidden (Energy doesn't count while calories are hidden).
  const allHidden = cardsKnown && [...cards.map(([id]) => id), 'nutrition.macros', 'nutrition.insights'].every((id) => !shownCard(id));
  return (
    <div className={`nutrition-overview ${loading ? 'is-refreshing' : ''}`}>
      <CardRow className="cards cards-4" fill={{ wide: 4, mid: 3, small: 2 }} cards={cards} />
      <CardRow
        className="split split-even"
        pair
        cards={[
          ['nutrition.macros', latest ? <MacroBalanceCard day={latest} today={data.today} numbers={numbers} caffeine={caffeineByDate.get(latest.date)} /> : <NothingYet hosted={status.hosted} />],
          ['nutrition.insights', <FoodInsights insights={data.insights} />],
        ]}
      />
      {allHidden && <AllHiddenNote />}
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
  if (!data.days.length) return <NothingYet hosted={hosted} />;
  const charted = ORDER.filter((n) => data.days.some((d) => d.values[n] !== undefined));
  return (
    <div className={`nutrition-tab ${loading ? 'is-refreshing' : ''}`}>
      <div className="split split-body">
        <AverageCard data={data} />
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
        <>
          <div className="split split-even">
            <HydrationSummary title="Water" points={w} format={(ml) => `${fmt(glasses(ml), glasses(ml) % 1 ? 1 : 0)} glasses · ${water(ml, units)}`} target={data.targets.water_ml ? water(data.targets.water_ml, units) : undefined} days={days} />
            <HydrationSummary title="Caffeine" points={caffeine} format={(mg) => `${fmt(mg)} mg`} days={days} />
          </div>
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
        </>
      )}
    </div>
  );
}

/** A drink's average over the days it was logged in the range, and how many days that was. */
function HydrationSummary({ title, points, format, target, days }: { title: string; points: { date: string; value: number }[]; format: (v: number) => string; target?: string; days: number }) {
  const avg = meanOf(points.map((p) => p.value));
  return (
    <section className="card hydration-summary">
      <div className="metric-head">
        <span>{title}</span>
        <span className="muted small">Last {days} days</span>
      </div>
      {avg === null ? (
        <p className="muted small">Nothing logged in these {days} days.</p>
      ) : (
        <>
          <div className="metric-value">
            {format(avg)}
            <small>a day on average, over the {points.length} {points.length === 1 ? 'day' : 'days'} logged</small>
          </div>
          {target && <span className="target-note small">Your target {target}</span>}
        </>
      )}
    </section>
  );
}

// ---------- shared pieces ----------

/**
 * The range's average day: each nutrient's mean over the days it was logged (a day without it doesn't count as zero),
 * and protein, carbs and fat by weight. In place of repeating the latest day, which the Overview already shows.
 */
function AverageCard({ data }: { data: NutritionData }) {
  const avg: Partial<Record<Nutrient, number>> = {};
  for (const n of ORDER) {
    const m = meanOf(data.days.flatMap((d) => (d.values[n] === undefined ? [] : [d.values[n]!])));
    if (m !== null) avg[n] = m;
  }
  const shown = ORDER.filter((n) => avg[n] !== undefined);
  const parts = MACROS.flatMap((m) => (avg[m.key] === undefined ? [] : [{ key: m.key, label: NUTRIENT[m.key].name, value: avg[m.key]!, color: m.color }]));
  const total = parts.reduce((a, p) => a + p.value, 0);
  const span = Math.round((Date.parse(`${data.end}T00:00:00Z`) - Date.parse(`${data.start}T00:00:00Z`)) / 86_400_000) + 1;
  return (
    <section className="card average-day">
      <div className="nutrition-day-head">
        <h2>Average day</h2>
        <span className="muted small">
          {data.days.length} logged {data.days.length === 1 ? 'day' : 'days'} in the last {span}
        </span>
      </div>
      <div className="average-day-body">
        {parts.length === 3 && total > 0 && (
          <Donut
            parts={parts}
            size={124}
            thickness={14}
            label={`Average by weight: ${parts.map((p) => `${p.label.toLowerCase()} ${Math.round((p.value / total) * 100)}%`).join(', ')}`}
            center={
              avg.energy_kcal !== undefined ? (
                <>
                  <strong>{fmt(avg.energy_kcal)}</strong>
                  <span>kcal</span>
                </>
              ) : (
                <span>by weight</span>
              )
            }
          />
        )}
        <dl className="nutrition-values">
          {shown.map((n) => (
            <div key={n}>
              <dt>{NUTRIENT[n].name}</dt>
              <dd>{amount(n, avg[n]!)}</dd>
            </div>
          ))}
        </dl>
      </div>
      <p className="muted small">Each average counts only the days that nutrient was logged.</p>
    </section>
  );
}

function NothingYet({ hosted }: { hosted: boolean }) {
  return (
    <section className="card nutrition-empty">
      <h2>Nothing logged yet</h2>
      <p className="muted">
        healthOS reads what your food app writes to Apple Health: MyFitnessPal, Cronometer, Lose It!, MacroFactor and Yazio all can. Turn on its Apple Health connection in
        that app.
        {hosted ? ' Then open the healthOS iPhone app (1.1, build 16 or later): it asks to read food and sends your log at its next sync.' : ' Then bring it in here:'}
      </p>
      {!hosted && (
        <ul className="muted">
          <li>
            Import your Health export again from <a href={href('integrations')}>Integrations</a>.
          </li>
          <li>Or open the healthOS iPhone app (1.1, build 16 or later), which sends it at its next sync.</li>
        </ul>
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
            <NumbersChoice
              current={nutrition ? nutritionNumbers : null}
              busy={busy}
              onChoose={(v) => save(nutrition ? { nutritionNumbers: v } : { nutrition: true, nutritionNumbers: v })}
            />
          </div>
        )}
        {nutrition && nutritionNumbers !== 'none' && <TargetInputs status={status} save={save} busy={busy} />}
        <p className="muted small">
          {!nutrition
            ? "While this is off, healthOS doesn't read or keep your food logs."
            : status.hosted
              ? 'Your food log comes in from the healthOS iPhone app (1.1, build 16 or later) at its next sync.'
              : 'History comes in with your next Health export import, or from the healthOS iPhone app at its next sync.'}
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
