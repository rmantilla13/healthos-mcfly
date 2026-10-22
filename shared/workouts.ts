// The latest-workout card's arithmetic (src/components/body/WorkoutCard.tsx), kept free of React so it can be
// tested on its own: which workout is the latest, that sport's recent sessions, pace or speed from distance and
// duration, and the few general recovery suggestions picked by plain rules. Every figure comes from the workout
// itself; nothing is estimated or scored. Times are read from the ISO strings, which carry the wearer's own offset.
import type { Units, Workout } from './types.ts';

/** The fields the card reads. The database can hand numbers back as strings, so every one goes through Number(). */
export type WorkoutLike = Pick<Workout, 'id' | 'sport' | 'start' | 'end' | 'date' | 'duration_min' | 'distance_m' | 'strain'>;

export type SportKind = 'run' | 'walk' | 'cycle' | 'swim' | 'strength' | 'mind' | 'other';

/** A broad kind from the sport's name, as Apple Health ("Traditional Strength Training") or WHOOP ("Weightlifting") writes it. */
export function sportKind(sport: string): SportKind {
  const s = sport.toLowerCase();
  if (/\brun|jog/.test(s)) return 'run';
  if (/walk|hik/.test(s)) return 'walk';
  if (/cycl|bik|spin/.test(s)) return 'cycle';
  if (/swim/.test(s)) return 'swim';
  if (/strength|weight|lift|functional|crossfit|cross training|core training/.test(s)) return 'strength';
  if (/yoga|pilates|mind|medita|stretch|flexib|tai chi|breath/.test(s)) return 'mind';
  return 'other';
}

/** A positive finite number, or null (a missing reading, a zero, or text that isn't a number). */
export function num(v: unknown): number | null {
  const n = Number(v);
  return v !== null && v !== undefined && v !== '' && Number.isFinite(n) && n > 0 ? n : null;
}

/** "HH:MM" as recorded, from the ISO string itself (never the browser's time zone). */
export const wallClock = (iso: string) => iso.slice(11, 16);

/**
 * The most recent workout that has finished by `now`, from a list already limited to the page's date. Today's list
 * can hold one that hasn't happened yet (the demo adds an evening walk so the timeline has something upcoming).
 */
export function latestWorkout<W extends WorkoutLike>(list: W[], now: number): W | null {
  let best: W | null = null;
  for (const w of list) {
    const end = Date.parse(w.end);
    if (Number.isFinite(end) && end > now) continue;
    if (!best || Date.parse(w.start) > Date.parse(best.start)) best = w;
  }
  return best;
}

/** The same sport's sessions up to and including `w`, oldest first: at most `n` of them. */
export function recentSessions<W extends WorkoutLike>(list: W[], w: W, n = 6): W[] {
  const sport = w.sport.trim().toLowerCase();
  const until = Date.parse(w.start);
  return list
    .filter((x) => x.sport.trim().toLowerCase() === sport && Date.parse(x.start) <= until)
    .sort((a, b) => Date.parse(a.start) - Date.parse(b.start))
    .slice(-n);
}

// ---------- distance, pace and speed ----------

const MILE_M = 1609.344;
const YARD_M = 0.9144;

/** How a distance reads for this sport: metres or yards for a swim, otherwise kilometres or miles. */
export function distanceIn(m: number, units: Units, kind: SportKind): { value: number; unit: string; digits: number } {
  if (kind === 'swim') return units === 'imperial' ? { value: m / YARD_M, unit: 'yd', digits: 0 } : { value: m, unit: 'm', digits: 0 };
  const value = units === 'imperial' ? m / MILE_M : m / 1000;
  return { value, unit: units === 'imperial' ? 'mi' : 'km', digits: value >= 100 ? 0 : value >= 10 ? 1 : 2 };
}

export type Pace =
  /** Time per distance: seconds per km or mile on foot, per 100 m or 100 yd in the water. */
  | { kind: 'pace'; seconds: number; per: 'km' | 'mi' | '100 m' | '100 yd' }
  /** Distance per hour, for a ride. */
  | { kind: 'speed'; value: number; unit: 'km/h' | 'mph' };

/**
 * Average pace (on foot, in the water) or speed (on a bike): the workout's duration divided by its distance. None
 * without both, for other sports, or when the result can't be a real session (a few metres logged over an hour).
 */
export function paceOf(w: Pick<Workout, 'sport' | 'distance_m' | 'duration_min'>, units: Units): Pace | null {
  const m = num(w.distance_m);
  const min = num(w.duration_min);
  if (m === null || min === null) return null;
  const kind = sportKind(w.sport);
  const imperial = units === 'imperial';
  if (kind === 'run' || kind === 'walk') {
    const seconds = (min * 60) / (m / (imperial ? MILE_M : 1000));
    // 1:30 to 60:00 per km (or the same per mile): anything outside is a recording slip, not a pace.
    const perKm = imperial ? seconds / (MILE_M / 1000) : seconds;
    return perKm >= 90 && perKm <= 3600 ? { kind: 'pace', seconds, per: imperial ? 'mi' : 'km' } : null;
  }
  if (kind === 'swim') {
    const seconds = (min * 60) / (m / (imperial ? 100 * YARD_M : 100));
    return seconds >= 40 && seconds <= 900 ? { kind: 'pace', seconds, per: imperial ? '100 yd' : '100 m' } : null;
  }
  if (kind === 'cycle') {
    const value = m / (imperial ? MILE_M : 1000) / (min / 60);
    return value > 0 && value <= (imperial ? 60 : 100) ? { kind: 'speed', value, unit: imperial ? 'mph' : 'km/h' } : null;
  }
  return null;
}

/** "5:07" or "1:02:30": whole seconds first, so 5:59.7 reads 6:00, never 5:60. */
export function clockDuration(totalSeconds: number) {
  const t = Math.round(totalSeconds);
  const h = Math.floor(t / 3600);
  const m = Math.floor((t % 3600) / 60);
  const s = t % 60;
  const ss = String(s).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

/** The pace or speed as text: "5:07 /km", "24.3 km/h". `digits` formats the speed (the app passes its own fmt). */
export function formatPace(p: Pace, digits: (v: number, d: number) => string = (v, d) => v.toFixed(d)) {
  return p.kind === 'speed' ? `${digits(p.value, 1)} ${p.unit}` : `${clockDuration(p.seconds)} /${p.per}`;
}

/** What the recent-session bars compare: distance when this session and most of the others have one, otherwise time. */
export function barMetric(sessions: WorkoutLike[], latest: WorkoutLike): 'distance' | 'duration' {
  const withDistance = sessions.filter((w) => num(w.distance_m) !== null).length;
  return num(latest.distance_m) !== null && withDistance * 2 >= sessions.length ? 'distance' : 'duration';
}

// ---------- general recovery suggestions ----------

export type SuggestionId = 'water' | 'protein' | 'winddown' | 'lighter' | 'sleep';
export type Suggestion = { id: SuggestionId; text: string; why: string };

/** WHOOP's strain bands, as on the Strain card: 14 and up is high, 18 and up is all out. */
const HIGH_STRAIN = 14;
const ALL_OUT_STRAIN = 18;

/** Ended at 20:00 or later, or past midnight: the same "late workout" the insights use. */
export function endsLate(w: Pick<Workout, 'end' | 'date'>) {
  return w.end.slice(0, 10) > w.date || Number(w.end.slice(11, 13)) >= 20;
}

/**
 * A few general recovery suggestions picked by plain rules from the session's length, strain and kind. They're
 * general ideas anyone might use after a session like this, never a prescription and never medical advice; each
 * says which rule picked it. Always at least one.
 */
export function recoverySuggestions(w: WorkoutLike): Suggestion[] {
  const min = num(w.duration_min) ?? 0;
  const strain = num(w.strain);
  const kind = sportKind(w.sport);
  const lasted = `Lasted ${Math.round(min)} min`;
  const out: Suggestion[] = [];
  if (min >= 45 || (strain !== null && strain >= HIGH_STRAIN))
    out.push({
      id: 'water',
      text: 'Drink some water over the next hour or so',
      why: strain !== null && strain >= HIGH_STRAIN ? `High strain (${strain.toFixed(1)})` : lasted,
    });
  if (kind === 'strength' || min >= 60)
    out.push({ id: 'protein', text: 'Have a meal or snack with some protein in the next few hours', why: kind === 'strength' ? 'After strength training' : lasted });
  if (endsLate(w)) out.push({ id: 'winddown', text: 'Leave some time to wind down before bed', why: `Ended at ${wallClock(w.end)}` });
  if (min >= 90 || (strain !== null && strain >= ALL_OUT_STRAIN))
    out.push({
      id: 'lighter',
      text: 'Think about an easier day next',
      why: strain !== null && strain >= ALL_OUT_STRAIN ? `All-out strain (${strain.toFixed(1)})` : lasted,
    });
  if (!out.length) out.push({ id: 'sleep', text: 'Keep to your usual sleep tonight', why: 'Sleep is when the body does most of its recovering' });
  return out;
}

// ---------- remembered ticks ----------
// One localStorage entry holds the ticks for the last few workout-days. Only ids go in: which person, workout and
// day, and which suggestions were ticked; never a figure. The card reads and writes it inside try/catch.

export const TICKS_KEY = 'healthos-recovery-ticks';
const KEEP = 20;

export const tickKey = (userId: string, workoutId: string, day: string) => `${userId}|${workoutId}|${day}`;

type Store = Record<string, { ids: string[]; at: number }>;

function parseStore(raw: string | null): Store {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw) as unknown;
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Store) : {};
  } catch {
    return {};
  }
}

/** The ticked suggestion ids for one workout-day; none when nothing (or nothing readable) is stored. */
export function readTicks(raw: string | null, key: string): string[] {
  const ids = parseStore(raw)[key]?.ids;
  return Array.isArray(ids) ? ids.filter((x): x is string => typeof x === 'string') : [];
}

/** The stored text with this workout-day's ticks replaced, keeping only the most recent entries. */
export function writeTicks(raw: string | null, key: string, ids: string[], now: number): string {
  const store = parseStore(raw);
  if (ids.length) store[key] = { ids: [...new Set(ids)], at: now };
  else delete store[key];
  const kept = Object.entries(store)
    .filter(([, v]) => v && Array.isArray(v.ids))
    .sort((a, b) => (Number(b[1].at) || 0) - (Number(a[1].at) || 0))
    .slice(0, KEEP);
  return JSON.stringify(Object.fromEntries(kept));
}
