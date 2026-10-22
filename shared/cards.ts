// The dashboard cards a person can hide (Settings → Cards; an admin can set it for anyone). Only layout: hiding a
// card changes what a page shows, never what's stored or what the Family board, McFly or the iPhone app see.

export type CardPage = 'home' | 'sleep' | 'body' | 'nutrition';

export const CARD_PAGES: { page: CardPage; label: string }[] = [
  { page: 'home', label: 'Home' },
  { page: 'sleep', label: 'Sleep · Overview' },
  { page: 'body', label: 'Body · Overview' },
  { page: 'nutrition', label: 'Nutrition · Overview' },
];

/** nutrition: offered only to people with Nutrition on (and never in the admin screens, which don't know who has it on). */
export const CARDS: { id: string; page: CardPage; label: string; nutrition?: true }[] = [
  { id: 'home.readiness', page: 'home', label: 'Recovery or cardio fitness' },
  { id: 'home.spo2', page: 'home', label: 'Blood oxygen' },
  { id: 'home.hrv', page: 'home', label: 'HRV' },
  { id: 'home.sleep', page: 'home', label: 'Sleep' },
  { id: 'home.load', page: 'home', label: 'Strain or active energy' },
  { id: 'home.activity', page: 'home', label: 'Activity' },
  { id: 'home.food', page: 'home', label: 'Food', nutrition: true },
  { id: 'home.timeline', page: 'home', label: "Today's timeline" },
  { id: 'home.insights', page: 'home', label: 'Recent insights' },
  { id: 'sleep.score', page: 'sleep', label: 'Sleep score' },
  { id: 'sleep.total', page: 'sleep', label: 'Total sleep' },
  { id: 'sleep.rhr', page: 'sleep', label: 'Resting heart rate' },
  { id: 'sleep.stages', page: 'sleep', label: 'Sleep stages' },
  { id: 'sleep.insights', page: 'sleep', label: 'Sleep insights' },
  { id: 'sleep.timeline', page: 'sleep', label: 'Sleep timeline' },
  { id: 'body.rhr', page: 'body', label: 'Resting heart rate' },
  { id: 'body.hrv', page: 'body', label: 'HRV' },
  { id: 'body.strain', page: 'body', label: 'Strain' },
  { id: 'body.recovery', page: 'body', label: 'Recovery' },
  { id: 'body.heart', page: 'body', label: 'Heart rate today' },
  { id: 'body.metrics', page: 'body', label: 'Body metrics' },
  { id: 'body.energy', page: 'body', label: 'Energy burned' },
  { id: 'body.steps', page: 'body', label: 'Activity level' },
  { id: 'body.workout', page: 'body', label: 'Latest workout' },
  { id: 'body.glucose', page: 'body', label: 'Glucose' },
  { id: 'body.composition', page: 'body', label: 'Body composition' },
  { id: 'body.biomarkers', page: 'body', label: 'Key biomarkers' },
  { id: 'nutrition.energy', page: 'nutrition', label: 'Energy', nutrition: true },
  { id: 'nutrition.protein', page: 'nutrition', label: 'Protein', nutrition: true },
  { id: 'nutrition.water', page: 'nutrition', label: 'Water', nutrition: true },
  { id: 'nutrition.logged', page: 'nutrition', label: 'Days logged', nutrition: true },
  { id: 'nutrition.macros', page: 'nutrition', label: 'Macro balance', nutrition: true },
  { id: 'nutrition.insights', page: 'nutrition', label: 'Food insights', nutrition: true },
];

const KNOWN = new Set(CARDS.map((c) => c.id));

/** Nutrition's cards, kept out of everything an admin sees or sends: the admin screens can't tell who uses Nutrition. */
export const NUTRITION_CARDS = new Set(CARDS.filter((c) => c.nutrition).map((c) => c.id));
export const withoutNutritionCards = (ids: string[]) => ids.filter((id) => !NUTRITION_CARDS.has(id));

/**
 * A hidden-cards list as sent: an array of known card ids. Returns them once each, in the registry's order, or
 * null when it isn't one (not an array, a non-string, or an unknown id).
 */
export function cleanHiddenCards(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.some((v) => typeof v !== 'string' || !KNOWN.has(v))) return null;
  const set = new Set(value as string[]);
  return CARDS.filter((c) => set.has(c.id)).map((c) => c.id);
}

/** The stored setting (a JSON array), read leniently: anything unreadable or no longer a card is dropped. */
export function readHiddenCards(raw: string | undefined | null): string[] {
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (cleanHiddenCards(parsed.filter((v) => typeof v === 'string' && KNOWN.has(v))) ?? []) : [];
  } catch {
    return [];
  }
}

/** What to store for a list: nothing when no card is hidden. */
export const storedHiddenCards = (ids: string[]) => (ids.length ? JSON.stringify(ids) : null);

/**
 * One card shown or hidden, applied to the list as it is now: so a change made elsewhere meanwhile (another tab,
 * or an admin) isn't undone by a page that loaded an older list. Null for an unknown card or a non-boolean.
 */
export function withCardShown(current: string[], change: unknown): string[] | null {
  if (typeof change !== 'object' || change === null) return null;
  const { id, shown } = change as { id?: unknown; shown?: unknown };
  if (typeof id !== 'string' || !KNOWN.has(id) || typeof shown !== 'boolean') return null;
  return cleanHiddenCards(shown ? current.filter((x) => x !== id) : [...current, id]);
}

/**
 * How many columns `n` cards take in a row of at most `max`: as few rows as fit, and as even as they go, so 4 cards
 * in a 3-up row are 2 × 2 rather than 3 + 1. A short last row stretches to fill (styles.css, .fill-row).
 */
export function fillColumns(n: number, max: number) {
  if (n <= 1 || max <= 1) return 1;
  return Math.ceil(n / Math.ceil(n / max));
}
