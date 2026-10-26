// The dashboard cards a person can hide (Home → Edit widgets, or Profile → Cards; an admin can set it for anyone).
// Only layout: hiding a card changes what a page shows, never what's stored or what the Family board, McFly or the
// iPhone app see. A defaultHidden card is optional: off until the person turns it on (shown_cards), and the other
// cards are on until hidden (hidden_cards). Never remove an id: a stored list naming it would then be refused.

export type CardPage = 'home' | 'sleep' | 'body' | 'nutrition';

export const CARD_PAGES: { page: CardPage; label: string }[] = [
  { page: 'home', label: 'Home' },
  { page: 'sleep', label: 'Sleep · Overview' },
  { page: 'body', label: 'Body · Overview' },
  { page: 'nutrition', label: 'Nutrition · Overview' },
];

/** nutrition: offered only to people with Nutrition on (and never in the admin screens, which don't know who has it on). */
export const CARDS: { id: string; page: CardPage; label: string; nutrition?: true; defaultHidden?: true }[] = [
  { id: 'home.rhr', page: 'home', label: 'Resting heart rate' },
  { id: 'home.spo2', page: 'home', label: 'Blood oxygen' },
  { id: 'home.hrv', page: 'home', label: 'HRV' },
  { id: 'home.sleep', page: 'home', label: 'Sleep' },
  // The id predates the card's new name; kept so lists that hid it still apply.
  { id: 'home.readiness', page: 'home', label: 'Recovery' },
  { id: 'home.resp', page: 'home', label: 'Respiratory rate' },
  { id: 'home.nutrition', page: 'home', label: "Today's nutrition" },
  { id: 'home.journal', page: 'home', label: 'Your health journal' },
  { id: 'home.week', page: 'home', label: 'Week so far', defaultHidden: true },
  { id: 'home.timeline', page: 'home', label: "Today's timeline", defaultHidden: true },
  { id: 'home.insights', page: 'home', label: 'Recent insights', defaultHidden: true },
  { id: 'home.load', page: 'home', label: 'Strain or active energy', defaultHidden: true },
  { id: 'home.activity', page: 'home', label: 'Activity', defaultHidden: true },
  { id: 'home.food', page: 'home', label: 'Food totals', nutrition: true, defaultHidden: true },
  { id: 'sleep.total', page: 'sleep', label: 'Sleep' },
  // Was "Sleep score" (WHOOP performance or Apple efficiency); efficiency now has its own card.
  { id: 'sleep.score', page: 'sleep', label: 'Sleep performance' },
  { id: 'sleep.efficiency', page: 'sleep', label: 'Sleep efficiency' },
  { id: 'sleep.rhr', page: 'sleep', label: 'Resting heart rate' },
  { id: 'sleep.stages', page: 'sleep', label: 'Sleep stages' },
  { id: 'sleep.insights', page: 'sleep', label: 'Sleep insights' },
  { id: 'sleep.timeline', page: 'sleep', label: 'Sleep timeline' },
  { id: 'body.figure', page: 'body', label: 'Your figure' },
  // One switch for the Weight, Body fat and Lean body mass cards (the id predates them).
  { id: 'body.composition', page: 'body', label: 'Weight, body fat and lean mass' },
  { id: 'body.story', page: 'body', label: 'A picture of your progress' },
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
  { id: 'body.biomarkers', page: 'body', label: 'Key biomarkers' },
  { id: 'nutrition.energy', page: 'nutrition', label: 'Energy', nutrition: true },
  { id: 'nutrition.protein', page: 'nutrition', label: 'Protein', nutrition: true },
  { id: 'nutrition.water', page: 'nutrition', label: 'Water', nutrition: true },
  { id: 'nutrition.logged', page: 'nutrition', label: 'Days logged', nutrition: true },
  { id: 'nutrition.macros', page: 'nutrition', label: 'Macro balance', nutrition: true },
  { id: 'nutrition.insights', page: 'nutrition', label: 'Food insights', nutrition: true },
];

const KNOWN = new Set(CARDS.map((c) => c.id));
/** The optional cards: off until turned on. */
export const OPTIONAL_CARDS = new Set(CARDS.filter((c) => c.defaultHidden).map((c) => c.id));
/** Whether a card shows, given both lists: an optional card when turned on, any other unless hidden. */
export const cardShown = (id: string, hidden: string[], shown: string[]) => (OPTIONAL_CARDS.has(id) ? shown.includes(id) : !hidden.includes(id));
/** How many default cards are hidden. An optional card turned off is in `hidden` too (for the iPhone), but it isn't hidden from a default. */
export const hiddenDefaults = (hidden: string[]) => hidden.filter((id) => !OPTIONAL_CARDS.has(id)).length;

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

/** A shown-cards list as sent: known optional card ids, once each, in the registry's order; null when it isn't one. */
export function cleanShownCards(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.some((v) => typeof v !== 'string' || !OPTIONAL_CARDS.has(v))) return null;
  const set = new Set(value as string[]);
  return CARDS.filter((c) => set.has(c.id)).map((c) => c.id);
}

/** The stored shown_cards setting, read leniently like readHiddenCards. */
export function readShownCards(raw: string | undefined | null): string[] {
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (cleanShownCards(parsed.filter((v) => typeof v === 'string' && OPTIONAL_CARDS.has(v))) ?? []) : [];
  } catch {
    return [];
  }
}

/**
 * One card shown or hidden, as { hidden, shown } lists after the change (either may be unchanged): any card moves in
 * or out of `hidden`, and an optional one in or out of `shown` too. The web reads only `shown` for an optional card;
 * the iPhone app knows only `hidden` (most optional cards were ordinary ones when it was built), so its change shows
 * in the first answer instead of needing a second write. Null for an unknown card or a non-boolean.
 */
export function withCardToggled(lists: { hidden: string[]; shown: string[] }, change: unknown): { hidden: string[]; shown: string[] } | null {
  if (typeof change !== 'object' || change === null) return null;
  const { id, shown } = change as { id?: unknown; shown?: unknown };
  if (typeof id !== 'string' || !KNOWN.has(id) || typeof shown !== 'boolean') return null;
  if (OPTIONAL_CARDS.has(id)) {
    const next = cleanShownCards(shown ? [...lists.shown, id] : lists.shown.filter((x) => x !== id));
    const hidden = withCardShown(lists.hidden, change);
    return next && hidden && { hidden, shown: next };
  }
  const next = withCardShown(lists.hidden, change);
  return next && { hidden: next, shown: lists.shown };
}

/**
 * How many columns `n` cards take in a row of at most `max`: as few rows as fit, and as even as they go, so 4 cards
 * in a 3-up row are 2 × 2 rather than 3 + 1. A short last row stretches to fill (styles.css, .fill-row).
 */
export function fillColumns(n: number, max: number) {
  if (n <= 1 || max <= 1) return 1;
  return Math.ceil(n / Math.ceil(n / max));
}
