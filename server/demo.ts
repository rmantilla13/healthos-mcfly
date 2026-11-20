// Synthetic data so the dashboard has something to show before real data is connected.
// Stored under source 'demo' and regenerated (up to today) when the local server starts on a local
// database. Never written to the hosted (Neon) database.
import {
  type DailyRow,
  type Db,
  type EventRow,
  type HourlyRow,
  OWNER_ID,
  type SleepStageRow,
  type WorkoutRow,
  deleteSource,
  replaceSleepStages,
  upsertDaily,
  upsertEvents,
  upsertHourly,
  upsertWorkouts,
} from './db.ts';
import { addDays, todayLocal, toLocalIso, type Stamp } from './dates.ts';
import { parseResultValue } from '../shared/labs.ts';
import { type LabRow, insertLabResults } from './labs.ts';

export const SOURCE = 'demo';
const DAYS = 400;
/** Days with hourly readings and stages through the night, as the iPhone app sends for recent days. */
const DETAIL_DAYS = 35;

function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export async function seedDemo(db: Db, userId = OWNER_ID) {
  const rand = rng(20261016);
  const noise = (sd: number) => (rand() + rand() + rand() - 1.5) * sd * 1.15;
  const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
  const offsetMin = -new Date().getTimezoneOffset();
  const at = (date: string, minutes: number): string => {
    const ms = Date.parse(date + 'T00:00:00Z') + minutes * 60_000 - offsetMin * 60_000;
    return toLocalIso({ ms, offsetMin } satisfies Stamp);
  };

  const today = todayLocal();
  const daily: DailyRow[] = [];
  const events: EventRow[] = [];
  const workouts: WorkoutRow[] = [];
  const nights: { date: string; segments: SleepStageRow[] }[] = [];
  // Its own stream, so the daily figures stay the same as before hourly detail existed.
  const detail = rng(20261019);
  const put = (date: string, metric: string, value: number) => daily.push({ date, metric, source: SOURCE, value });

  let weight = 81.5;
  let fitness = 0;
  for (let i = DAYS - 1; i >= 0; i--) {
    const date = addDays(today, -i);
    const dow = new Date(date + 'T12:00:00Z').getUTCDay();
    const weekend = dow === 0 || dow === 6;
    const progress = (DAYS - i) / DAYS; // slow improvement over the year
    // Last two weeks trend better so the insights have a story to tell.
    const recent = i < 14 ? (14 - i) / 14 : 0;
    fitness = fitness * 0.8 + noise(1) * 0.2;

    const sleepHours = clamp(7.1 + (weekend ? 0.5 : 0) + 0.3 * recent + noise(0.55), 5.2, 9.2);
    const deep = sleepHours * clamp(0.19 + noise(0.03), 0.12, 0.26);
    const rem = sleepHours * clamp(0.23 + noise(0.03), 0.15, 0.3);
    const light = sleepHours - deep - rem;
    const awake = clamp(0.45 + noise(0.18), 0.1, 1.1);
    const hrv = clamp(56 + 10 * progress + 8 * recent + (sleepHours - 7.2) * 4 + fitness * 6 + noise(6), 28, 110);
    const rhr = clamp(57 - 3 * progress - 1.5 * recent - (hrv - 62) * 0.08 + noise(1.6), 44, 70);
    const recovery = clamp(35 + (hrv - 45) * 1.15 + noise(9), 8, 99);
    const workoutToday = rand() < (weekend ? 0.55 : 0.6);
    const strain = clamp((workoutToday ? 12.5 : 7.5) + noise(2.4), 2.5, 19.8);
    const steps = Math.round(clamp((weekend ? 9500 : 8200) + (workoutToday ? 1800 : 0) + noise(2600), 2200, 21000));
    weight += -0.006 + noise(0.12) * 0.25;

    put(date, 'sleep_hours', sleepHours);
    put(date, 'sleep_deep', deep);
    put(date, 'sleep_rem', rem);
    put(date, 'sleep_light', light);
    put(date, 'sleep_awake', awake);
    put(date, 'sleep_in_bed', sleepHours + awake);
    put(date, 'sleep_performance', clamp((sleepHours / 8.1) * 100 + noise(4), 40, 100));
    put(date, 'hrv_rmssd', hrv);
    put(date, 'resting_hr', rhr);
    put(date, 'recovery', recovery);
    put(date, 'spo2', clamp(97.4 + noise(0.7), 94, 100));
    put(date, 'resp_rate', clamp(14.2 + noise(0.45), 12, 17));
    put(date, 'wrist_temp', clamp(35.95 + noise(0.18), 35.2, 36.8));
    put(date, 'strain', strain);
    put(date, 'steps', steps);
    put(date, 'active_energy', clamp(steps * 0.042 + (workoutToday ? 260 : 0) + noise(60), 150, 1400));
    // Without the random stream, so the rest of the demo stays as it was.
    put(date, 'resting_energy', 1720 + (weight - 81.5) * 14 + 22 * Math.sin(i * 1.7));
    if (workoutToday) put(date, 'hr_recovery', 24 + 5 * progress + 3 * Math.sin(i * 2.3));
    put(date, 'exercise_min', clamp((workoutToday ? 42 : 12) + noise(10), 0, 140));
    put(date, 'distance_km', steps * 0.00076);
    put(date, 'hr_avg', clamp(rhr + 16 + noise(3), 55, 95));
    if (i % 3 === 0 || i < 7) put(date, 'weight', weight);
    if (i % 7 === 0) put(date, 'body_fat', clamp(19.5 - 2.5 * progress + noise(0.4), 12, 25));
    if (i % 14 === 0) put(date, 'vo2max', 43.5 + 3.2 * progress + noise(0.4));

    const bed = 22 * 60 + 55 + Math.round(noise(35)) + (weekend ? 35 : 0);
    const wake = bed + Math.round((sleepHours + awake) * 60);
    // The night starts with a while in bed before falling asleep (from its own stream, like the hourly detail).
    const latency = Math.round(8 + detail() * 18);
    events.push({ id: `demo-sleep-${date}`, source: SOURCE, kind: 'sleep', title: 'Sleep', start: at(addDays(date, -1), bed + latency), end: at(addDays(date, -1), wake), date });
    if (i < DETAIL_DAYS) nights.push({ date, segments: nightStages(detail, (m) => at(addDays(date, -1), m), bed, wake, latency, { deep, rem, light, awake }) });

    if (i === 0 || rand() < 0.45) {
      const t = i === 0 ? 8 * 60 : 7 * 60 + Math.round(rand() * 90);
      events.push({ id: `demo-mindful-${date}`, source: SOURCE, kind: 'mindful', title: 'Meditation', start: at(date, t), end: at(date, t + 15), date });
    }

    if (workoutToday || i === 0) {
      const kinds = [
        { sport: 'Running', hr: 148, kcalPerMin: 11, dist: 170 },
        { sport: 'Strength Training', hr: 122, kcalPerMin: 7, dist: 0 },
        { sport: 'Cycling', hr: 138, kcalPerMin: 10, dist: 420 },
        { sport: 'Yoga', hr: 96, kcalPerMin: 4, dist: 0 },
      ];
      const k = i === 0 ? kinds[1] : kinds[Math.floor(rand() * kinds.length)];
      const startMin = i === 0 ? 12 * 60 + 30 : weekend ? 9 * 60 + Math.round(rand() * 120) : 17 * 60 + 30 + Math.round(rand() * 60);
      const dur = i === 0 ? 45 : Math.round(30 + rand() * 40);
      workouts.push({
        id: `demo-workout-${date}`,
        source: SOURCE,
        sport: k.sport,
        start: at(date, startMin),
        end: at(date, startMin + dur),
        date,
        duration_min: dur,
        energy_kcal: Math.round(dur * k.kcalPerMin * (0.9 + rand() * 0.2)),
        distance_m: k.dist ? Math.round(dur * k.dist) : null,
        avg_hr: Math.round(k.hr + noise(6)),
        max_hr: Math.round(k.hr + 25 + noise(6)),
        strain: Math.round(clamp(strain - 3 + noise(1.5), 3, 18) * 10) / 10,
        // From the day's strain, without the random stream, so the rest of the demo stays as it was.
        effort: k.sport === 'Yoga' ? 3 : Math.round(clamp(strain / 2, 3, 9)),
      });
    }
  }

  // Today's evening walk, so the timeline shows an upcoming item.
  workouts.push({
    id: `demo-walk-${today}`,
    source: SOURCE,
    sport: 'Walking',
    start: at(today, 18 * 60 + 30),
    end: at(today, 19 * 60 + 15),
    date: today,
    duration_min: 45,
    energy_kcal: 180,
    distance_m: 3900,
    avg_hr: 102,
    max_hr: 118,
    strain: 4.8,
    effort: null,
  });

  const hourly = demoHours(detail, today, daily, workouts);
  // Today's totals are what the hours add up to so far, and the figures that go with them scale alike.
  const todayRow = (metric: string) => daily.find((r) => r.date === today && r.metric === metric);
  const stepsRow = todayRow('steps');
  const share = stepsRow && stepsRow.value > 0 ? hourly.filter((h) => h.date === today && h.metric === 'steps').reduce((a, h) => a + h.value, 0) / stepsRow.value : 1;
  for (const metric of ['steps', 'active_energy']) {
    const row = todayRow(metric);
    if (row) row.value = hourly.filter((h) => h.date === today && h.metric === metric).reduce((a, h) => a + h.value, 0);
  }
  for (const metric of ['distance_km', 'exercise_min']) {
    const row = todayRow(metric);
    if (row) row.value *= share;
  }
  // Exercise so far is at least the workouts already over.
  const exercise = todayRow('exercise_min');
  const done = workouts.filter((w) => w.date === today && Date.parse(w.end) <= Date.now()).reduce((a, w) => a + w.duration_min, 0);
  if (exercise) exercise.value = Math.max(exercise.value, done);

  await db.tx(async (q) => {
    await deleteSource(q, userId, SOURCE);
    await upsertDaily(q, userId, daily);
    await upsertEvents(q, userId, events);
    await upsertWorkouts(q, userId, workouts);
    await upsertHourly(q, userId, hourly);
    await replaceSleepStages(q, userId, SOURCE, nights);
    await insertLabResults(q, userId, demoLabs(today));
  });
}

/**
 * Two blood draws about six months apart, so the Lab tests page has a latest result, a change and a range to show.
 * Fixed values, not the random stream: reseeding never moves them. One result has no printed range (the typical
 * one shows instead, labelled), one is printed as "<0.3", and vitamin D moves from below the range to within it.
 */
function demoLabs(today: string): LabRow[] {
  const draws: [days: number, values: Record<string, string>][] = [
    [-190, { total_cholesterol: '212', ldl: '134', hdl: '52', triglycerides: '131', hba1c: '5.4', glucose: '94', vitamin_d: '22', ferritin: '88', tsh: '2.1', hs_crp: '1.4', magnesium: '2.0' }],
    [-21, { total_cholesterol: '196', ldl: '118', hdl: '55', triglycerides: '112', hba1c: '5.3', glucose: '89', vitamin_d: '38', ferritin: '92', tsh: '1.9', hs_crp: '<0.3', magnesium: '2.1' }],
  ];
  const MARKERS: Record<string, { name: string; unit: string; ref: string; panel: string }> = {
    total_cholesterol: { name: 'Cholesterol, Total', unit: 'mg/dL', ref: '100-199', panel: 'Lipid panel' },
    ldl: { name: 'LDL Chol Calc (NIH)', unit: 'mg/dL', ref: '0-99', panel: 'Lipid panel' },
    hdl: { name: 'HDL Cholesterol', unit: 'mg/dL', ref: '>39', panel: 'Lipid panel' },
    triglycerides: { name: 'Triglycerides', unit: 'mg/dL', ref: '0-149', panel: 'Lipid panel' },
    hba1c: { name: 'Hemoglobin A1c', unit: '%', ref: '4.8-5.6', panel: 'Metabolic' },
    glucose: { name: 'Glucose', unit: 'mg/dL', ref: '70-99', panel: 'Metabolic' },
    vitamin_d: { name: 'Vitamin D, 25-Hydroxy', unit: 'ng/mL', ref: '30.0-100.0', panel: 'Vitamins and iron' },
    ferritin: { name: 'Ferritin', unit: 'ng/mL', ref: '30-400', panel: 'Vitamins and iron' },
    magnesium: { name: 'Magnesium', unit: 'mg/dL', ref: '', panel: 'Vitamins and iron' },
    tsh: { name: 'TSH', unit: 'uIU/mL', ref: '0.450-4.500', panel: 'Thyroid' },
    hs_crp: { name: 'hs-CRP', unit: 'mg/L', ref: '0.00-3.00', panel: 'Inflammation' },
  };
  const out: LabRow[] = [];
  for (const [days, values] of draws) {
    const collected = addDays(today, days);
    for (const [key, valueText] of Object.entries(values)) {
      const m = MARKERS[key];
      const [low, high] = m.ref.startsWith('>') ? [Number(m.ref.slice(1)), null] : m.ref ? m.ref.split('-').map(Number) : [null, null];
      out.push({
        id: `demo-lab-${collected}-${key}`,
        collected,
        biomarker: key,
        name: m.name,
        value: parseResultValue(valueText).value,
        value_text: valueText,
        unit: m.unit,
        ref_low: low,
        ref_high: high,
        ref_text: m.ref,
        lab: 'Demo Lab',
        panel: m.panel,
        source: SOURCE,
        created_at: Date.parse(`${collected}T09:00:00Z`),
      });
    }
  }
  return out;
}

/**
 * A night as the Watch records it: time in bed before falling asleep, then about 90-minute cycles of light,
 * deep and REM sleep (more deep early, more REM late) with brief wakings, adding up to the night's totals.
 */
function nightStages(
  rand: () => number,
  at: (m: number) => string,
  bed: number,
  wake: number,
  latency: number,
  hours: { deep: number; rem: number; light: number; awake: number },
): SleepStageRow[] {
  const asleep = (hours.deep + hours.rem + hours.light) * 60;
  const n = Math.max(3, Math.round(asleep / 90));
  const share = (w: (k: number) => number) => {
    const ws = Array.from({ length: n }, (_, k) => w(k));
    const sum = ws.reduce((a, b) => a + b, 0);
    return ws.map((x) => x / sum);
  };
  const deep = share((k) => (n - k) ** 1.6);
  const rem = share((k) => (k + 1) ** 1.2);
  const wakeBudget = Math.max(0, hours.awake * 60 - latency);
  const wakings = share((k) => (k === n - 1 ? 0.2 : rand() < 0.55 ? 0.5 + rand() : 0));
  const plan: [string, number][] = [['in_bed', latency]];
  for (let k = 0; k < n; k++) {
    const light = (hours.light * 60) / n;
    const split = 0.4 + rand() * 0.25;
    plan.push(['light', light * split], ['deep', hours.deep * 60 * deep[k]], ['light', light * (1 - split)], ['rem', hours.rem * 60 * rem[k]]);
    if (wakings[k] > 0) plan.push(['awake', wakeBudget * wakings[k]]);
  }
  // Whole minutes, with the last stretch ending at the night's end; tiny stretches fold into their neighbour.
  const out: SleepStageRow[] = [];
  let t = bed;
  let carry = 0;
  for (const [stage, min] of plan) {
    const len = Math.round(min + carry);
    if (len < 2) {
      carry += min;
      continue;
    }
    carry = 0;
    const end = Math.min(wake, t + len);
    if (end <= t) break;
    const prev = out.at(-1);
    if (prev && prev.stage === stage) prev.end = at(end);
    else out.push({ start: at(t), end: at(end), stage });
    t = end;
  }
  if (t < wake) {
    const prev = out.at(-1)!;
    prev.end = at(wake);
  }
  return out;
}

/** Hour by hour for recent days: steps and active energy spread over waking hours, heart rate low overnight. */
function demoHours(rand: () => number, today: string, daily: DailyRow[], workouts: WorkoutRow[]): HourlyRow[] {
  const out: HourlyRow[] = [];
  const nowHour = new Date().getHours();
  const value = (date: string, metric: string) => daily.find((r) => r.date === date && r.metric === metric)?.value;
  // Time of day people tend to move: a morning commute, lunch and the evening.
  const shape = [0, 0, 0, 0, 0, 0, 0.2, 0.9, 1.4, 0.8, 0.6, 0.7, 1.2, 1, 0.6, 0.6, 0.8, 1.3, 1.2, 0.9, 0.6, 0.4, 0.2, 0.05];
  for (let i = DETAIL_DAYS - 1; i >= 0; i--) {
    const date = addDays(today, -i);
    const last = i === 0 ? nowHour : 23;
    const steps = value(date, 'steps') ?? 0;
    const energy = value(date, 'active_energy') ?? 0;
    const rhr = value(date, 'resting_hr') ?? 58;
    const w = workouts.find((x) => x.date === date && x.id.startsWith('demo-workout'));
    const wHour = w ? Number(w.start.slice(11, 13)) : -1;
    const weights = shape.map((x, h) => x * (0.6 + rand() * 0.8) + (h === wHour ? 3 : 0));
    const total = weights.reduce((a, b) => a + b, 0);
    for (let h = 0; h <= last; h++) {
      const part = weights[h] / total;
      if (part > 0) {
        out.push({ date, hour: h, metric: 'steps', source: SOURCE, value: Math.round(steps * part) });
        out.push({ date, hour: h, metric: 'active_energy', source: SOURCE, value: Math.round(energy * part) });
      }
      const asleep = h < 6 || h === 23;
      const avg = h === wHour && w?.avg_hr ? (w.avg_hr + rhr + 20) / 2 : asleep ? rhr + 2 + rand() * 4 : rhr + 12 + weights[h] * 6 + rand() * 6;
      out.push({ date, hour: h, metric: 'hr_avg', source: SOURCE, value: Math.round(avg) });
      out.push({ date, hour: h, metric: 'hr_min', source: SOURCE, value: Math.round(Math.max(rhr - 3, avg - 8 - rand() * 6)) });
      out.push({ date, hour: h, metric: 'hr_max', source: SOURCE, value: Math.round(avg + 10 + rand() * (h === wHour ? 40 : 18)) });
    }
  }
  return out;
}
