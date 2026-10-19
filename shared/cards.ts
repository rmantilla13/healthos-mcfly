// The dashboard cards a person can hide (Settings → Cards; an admin can set it for anyone). Only layout: hiding a
// card changes what a page shows, never what's stored or what the Family board, McFly or the iPhone app see.

export type CardPage = 'home' | 'sleep' | 'body';

export const CARD_PAGES: { page: CardPage; label: string }[] = [
  { page: 'home', label: 'Home' },
  { page: 'sleep', label: 'Sleep · Overview' },
  { page: 'body', label: 'Body · Overview' },
];

export const CARDS: { id: string; page: CardPage; label: string }[] = [
  { id: 'home.readiness', page: 'home', label: 'Recovery or cardio fitness' },
  { id: 'home.spo2', page: 'home', label: 'Blood oxygen' },
  { id: 'home.hrv', page: 'home', label: 'HRV' },
  { id: 'home.sleep', page: 'home', label: 'Sleep' },
  { id: 'home.load', page: 'home', label: 'Strain or active energy' },
  { id: 'home.activity', page: 'home', label: 'Activity' },
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
];

const KNOWN = new Set(CARDS.map((c) => c.id));

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
