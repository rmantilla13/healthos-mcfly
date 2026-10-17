// Synthetic data so the dashboard has something to show before real data is connected.
// Stored under source 'demo' and regenerated (up to today) when the local server starts on a local
// database. Never written to the hosted (Neon) database.
import { type DailyRow, type Db, type EventRow, OWNER_ID, type WorkoutRow, deleteSource, upsertDaily, upsertEvents, upsertWorkouts } from './db.ts';
import { addDays, todayLocal, toLocalIso, type Stamp } from './dates.ts';

export const SOURCE = 'demo';
const DAYS = 400;

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
    put(date, 'exercise_min', clamp((workoutToday ? 42 : 12) + noise(10), 0, 140));
    put(date, 'distance_km', steps * 0.00076);
    put(date, 'hr_avg', clamp(rhr + 16 + noise(3), 55, 95));
    if (i % 3 === 0 || i < 7) put(date, 'weight', weight);
    if (i % 7 === 0) put(date, 'body_fat', clamp(19.5 - 2.5 * progress + noise(0.4), 12, 25));
    if (i % 14 === 0) put(date, 'vo2max', 43.5 + 3.2 * progress + noise(0.4));

    const bed = 22 * 60 + 55 + Math.round(noise(35)) + (weekend ? 35 : 0);
    const wake = bed + Math.round((sleepHours + awake) * 60);
    events.push({ id: `demo-sleep-${date}`, source: SOURCE, kind: 'sleep', title: 'Sleep', start: at(addDays(date, -1), bed), end: at(addDays(date, -1), wake), date });

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
  });

  await db.tx(async (q) => {
    await deleteSource(q, userId, SOURCE);
    await upsertDaily(q, userId, daily);
    await upsertEvents(q, userId, events);
    await upsertWorkouts(q, userId, workouts);
  });
}
