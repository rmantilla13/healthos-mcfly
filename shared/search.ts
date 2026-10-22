// The ⌘K palette's catalogue and ranking (src/components/Search.tsx), kept free of React so it can be tested on its
// own. The catalogue is only places in the app: pages, their tabs, where each metric is shown, and a few actions.
// It holds no data. What's typed is matched here and never leaves the page.

export type SearchGroup = 'pages' | 'tabs' | 'metrics' | 'actions';

export const GROUPS: { id: SearchGroup; label: string }[] = [
  { id: 'pages', label: 'Pages' },
  { id: 'tabs', label: 'Tabs' },
  { id: 'metrics', label: 'Metrics' },
  { id: 'actions', label: 'Actions' },
];

/** Who can see what, from GET /api/status (and /api/auth/me for whether sign-in is on). */
export type SearchAccess = {
  cycleTracking: boolean;
  /** Nutrition is on, so its Log tab exists. */
  nutrition: boolean;
  /** Nutrition is on with amounts (not "No amounts"), so its Macros and Hydration tabs exist. */
  nutritionAmounts: boolean;
  /** Signed in with family sharing on, so the Family page is in the menu. */
  family: boolean;
  /** Signed in as an admin. */
  admin: boolean;
};

type Needs = 'cycle' | 'nutrition' | 'amounts' | 'family' | 'admin';

export type SearchItem = {
  id: string;
  group: SearchGroup;
  label: string;
  /** Where it is, shown beside the label ("Body · Cardiovascular"). Matched too, but weighs less. */
  hint?: string;
  /** Other words people use for it. */
  keywords?: string[];
  /** The address it opens: a hash route, never anything typed. */
  to: string;
  needs?: Needs;
  /** For the "Ask McFly about …" action: the question to hand over. Never put in the address. */
  ask?: string;
};

const body = (tab: string) => `#/body?tab=${tab}`;
const sleep = (tab: string) => `#/sleep?tab=${tab}`;
const nutrition = (tab: string) => `#/nutrition?tab=${tab}`;

const CATALOGUE: SearchItem[] = [
  // ---------- pages, in the sidebar's order ----------
  { id: 'page.home', group: 'pages', label: 'Home', to: '#/', keywords: ['today', 'dashboard', 'overview', 'timeline'] },
  { id: 'page.family', group: 'pages', label: 'Family', to: '#/family', keywords: ['family board', 'members', 'shared'], needs: 'family' },
  { id: 'page.vitals', group: 'pages', label: 'Vitals', to: '#/vitals', keywords: ['heart', 'vital signs'] },
  { id: 'page.body', group: 'pages', label: 'Body', to: '#/body', keywords: ['heart', 'recovery', 'strain', 'movement'] },
  { id: 'page.cycle', group: 'pages', label: 'Cycle', to: '#/cycle', keywords: ['period', 'menstrual', 'cycle tracking'], needs: 'cycle' },
  { id: 'page.sleep', group: 'pages', label: 'Sleep', to: '#/sleep', keywords: ['night', 'bed', 'rest'] },
  { id: 'page.nutrition', group: 'pages', label: 'Nutrition', to: '#/nutrition', keywords: ['food', 'diet', 'meals', 'eating'] },
  { id: 'page.labs', group: 'pages', label: 'Lab tests', to: '#/labs', keywords: ['labs', 'blood test', 'blood work', 'bloodwork', 'panel', 'results'] },
  { id: 'page.mcfly', group: 'pages', label: 'Ask McFly', to: '#/mcfly', keywords: ['mcfly', 'chat', 'assistant', 'ai', 'question'] },
  { id: 'page.integrations', group: 'pages', label: 'Integrations', to: '#/integrations', keywords: ['connect', 'whoop', 'apple health', 'iphone app', 'import', 'sync', 'sources'] },
  { id: 'page.settings', group: 'pages', label: 'Settings', to: '#/settings', keywords: ['preferences', 'account', 'units', 'cards', 'profile'] },
  { id: 'page.admin', group: 'pages', label: 'Admin', to: '#/admin', keywords: ['people', 'users', 'invite', 'accounts'], needs: 'admin' },

  // ---------- tabs ----------
  { id: 'tab.body.recovery', group: 'tabs', label: 'Recovery', hint: 'Body', to: body('recovery'), keywords: ['hrv', 'resting heart rate'] },
  { id: 'tab.body.strain', group: 'tabs', label: 'Strain', hint: 'Body', to: body('strain'), keywords: ['active energy', 'exercise minutes'] },
  { id: 'tab.body.activity', group: 'tabs', label: 'Activity', hint: 'Body', to: body('activity'), keywords: ['steps', 'workouts', 'exercise'] },
  { id: 'tab.body.temperature', group: 'tabs', label: 'Temperature', hint: 'Body', to: body('temperature'), keywords: ['wrist', 'skin', 'body temperature'] },
  { id: 'tab.body.cardiovascular', group: 'tabs', label: 'Cardiovascular', hint: 'Body', to: body('cardiovascular'), keywords: ['heart', 'cardio', 'blood oxygen', 'vo2 max'] },
  { id: 'tab.body.metabolism', group: 'tabs', label: 'Metabolism', hint: 'Body', to: body('metabolism'), keywords: ['weight', 'body fat', 'composition'] },
  { id: 'tab.sleep.stages', group: 'tabs', label: 'Stages', hint: 'Sleep', to: sleep('stages'), keywords: ['sleep stages', 'deep', 'rem', 'light', 'awake'] },
  { id: 'tab.sleep.trends', group: 'tabs', label: 'Trends', hint: 'Sleep', to: sleep('trends'), keywords: ['sleep trends', 'sleep score'] },
  { id: 'tab.sleep.coaching', group: 'tabs', label: 'Coaching', hint: 'Sleep', to: sleep('coaching'), keywords: ['sleep coaching', 'better nights'] },
  // Log is there on "No amounts" too, so it needs only Nutrition on.
  { id: 'tab.nutrition.log', group: 'tabs', label: 'Log', hint: 'Nutrition', to: nutrition('log'), keywords: ['log food', 'add food', 'barcode', 'scan', 'photo', 'meal', 'estimate'], needs: 'nutrition' },
  { id: 'tab.nutrition.macros', group: 'tabs', label: 'Macros', hint: 'Nutrition', to: nutrition('macros'), keywords: ['protein', 'carbs', 'fat'], needs: 'amounts' },
  { id: 'tab.nutrition.hydration', group: 'tabs', label: 'Hydration', hint: 'Nutrition', to: nutrition('hydration'), keywords: ['water', 'drinks'], needs: 'amounts' },

  // ---------- metrics, each where it's shown ----------
  { id: 'metric.rhr', group: 'metrics', label: 'Resting heart rate', hint: 'Body · Cardiovascular', to: body('cardiovascular'), keywords: ['rhr', 'heart rate', 'pulse', 'bpm'] },
  { id: 'metric.hr', group: 'metrics', label: 'Heart rate', hint: 'Vitals', to: '#/vitals', keywords: ['pulse', 'bpm', 'heart rate today'] },
  { id: 'metric.hrv', group: 'metrics', label: 'HRV', hint: 'Body · Recovery', to: body('recovery'), keywords: ['heart rate variability', 'rmssd', 'sdnn'] },
  { id: 'metric.recovery', group: 'metrics', label: 'Recovery', hint: 'Body · Recovery', to: body('recovery'), keywords: ['whoop recovery', 'readiness'] },
  { id: 'metric.strain', group: 'metrics', label: 'Strain', hint: 'Body · Strain', to: body('strain'), keywords: ['day strain', 'whoop strain', 'load'] },
  { id: 'metric.energy', group: 'metrics', label: 'Active energy', hint: 'Body · Strain', to: body('strain'), keywords: ['calories burned', 'kcal', 'energy burned', 'move'] },
  { id: 'metric.exercise', group: 'metrics', label: 'Exercise minutes', hint: 'Body · Strain', to: body('strain'), keywords: ['exercise', 'active minutes'] },
  { id: 'metric.steps', group: 'metrics', label: 'Steps', hint: 'Body · Activity', to: body('activity'), keywords: ['step count', 'walking', 'activity level'] },
  { id: 'metric.workouts', group: 'metrics', label: 'Workouts', hint: 'Body · Activity', to: body('activity'), keywords: ['workout', 'exercise', 'training', 'run', 'ride', 'latest workout'] },
  { id: 'metric.sleep', group: 'metrics', label: 'Time asleep', hint: 'Sleep', to: '#/sleep', keywords: ['sleep', 'sleep duration', 'hours slept', 'last night'] },
  { id: 'metric.sleep_score', group: 'metrics', label: 'Sleep score', hint: 'Sleep · Trends', to: sleep('trends'), keywords: ['sleep performance', 'sleep efficiency', 'sleep consistency', 'time in bed'] },
  { id: 'metric.stages', group: 'metrics', label: 'Sleep stages', hint: 'Sleep · Stages', to: sleep('stages'), keywords: ['deep sleep', 'rem sleep', 'light sleep', 'awake'] },
  { id: 'metric.spo2', group: 'metrics', label: 'Blood oxygen', hint: 'Body · Cardiovascular', to: body('cardiovascular'), keywords: ['spo2', 'oxygen saturation', 'o2'] },
  { id: 'metric.breathing', group: 'metrics', label: 'Respiratory rate', hint: 'Body · Cardiovascular', to: body('cardiovascular'), keywords: ['breathing', 'breaths', 'rpm', 'respiration'] },
  { id: 'metric.temp', group: 'metrics', label: 'Temperature', hint: 'Body · Temperature', to: body('temperature'), keywords: ['body temperature', 'wrist temperature', 'skin temperature', 'temp'] },
  { id: 'metric.weight', group: 'metrics', label: 'Weight', hint: 'Body · Metabolism', to: body('metabolism'), keywords: ['body weight', 'mass', 'kg', 'lb'] },
  { id: 'metric.body_fat', group: 'metrics', label: 'Body fat', hint: 'Body · Metabolism', to: body('metabolism'), keywords: ['fat percentage', 'body composition'] },
  { id: 'metric.lean', group: 'metrics', label: 'Lean body mass', hint: 'Body · Metabolism', to: body('metabolism'), keywords: ['lean mass', 'muscle', 'body composition'] },
  { id: 'metric.vo2', group: 'metrics', label: 'VO₂ max', hint: 'Body · Cardiovascular', to: body('cardiovascular'), keywords: ['cardio fitness', 'vo2max', 'aerobic fitness'] },
  { id: 'metric.glucose', group: 'metrics', label: 'Glucose', hint: 'Body', to: '#/body', keywords: ['blood glucose', 'blood sugar', 'sugar', 'cgm'] },
  { id: 'metric.labs', group: 'metrics', label: 'Lab results', hint: 'Lab tests', to: '#/labs', keywords: ['lab tests', 'biomarkers', 'cholesterol', 'blood test', 'bloodwork', 'panel'] },
  { id: 'metric.cycle', group: 'metrics', label: 'Period and cycle', hint: 'Cycle', to: '#/cycle', keywords: ['period', 'menstruation', 'ovulation', 'fertile window'], needs: 'cycle' },
  { id: 'metric.food', group: 'metrics', label: 'Food logged', hint: 'Nutrition', to: '#/nutrition', keywords: ['calories eaten', 'meals', 'food'], needs: 'nutrition' },
  { id: 'metric.protein', group: 'metrics', label: 'Protein', hint: 'Nutrition · Macros', to: nutrition('macros'), keywords: ['macros', 'carbs', 'carbohydrates', 'fat eaten'], needs: 'amounts' },
  { id: 'metric.water', group: 'metrics', label: 'Water', hint: 'Nutrition · Hydration', to: nutrition('hydration'), keywords: ['hydration', 'drinks', 'fluid'], needs: 'amounts' },

  // ---------- actions ----------
  { id: 'action.mcfly', group: 'actions', label: 'Ask McFly a question', to: '#/mcfly', keywords: ['ask', 'chat', 'question', 'mcfly'] },
  { id: 'action.labs', group: 'actions', label: 'Add lab results', to: '#/labs', keywords: ['upload', 'lab tests', 'blood test', 'new results'] },
  { id: 'action.connect', group: 'actions', label: 'Connect WHOOP or Apple Health', to: '#/integrations', keywords: ['connect', 'sync', 'import', 'iphone app'] },
  { id: 'action.cards', group: 'actions', label: 'Choose which cards show', to: '#/settings', keywords: ['hide cards', 'show cards', 'layout', 'cards'] },
  { id: 'action.units', group: 'actions', label: 'Change units', to: '#/settings', keywords: ['metric', 'imperial', 'kilometres', 'miles', 'pounds'] },
];

/** The catalogue minus what this person can't open: Cycle without cycle tracking, Admin for others, and so on. */
export function searchItems(a: SearchAccess): SearchItem[] {
  const allowed: Record<Needs, boolean> = { cycle: a.cycleTracking, nutrition: a.nutrition, amounts: a.nutrition && a.nutritionAmounts, family: a.family, admin: a.admin };
  return CATALOGUE.filter((it) => !it.needs || allowed[it.needs]);
}

// ---------- matching ----------

/** Lower case, accents and marks gone ("VO₂" is "vo2"), anything but letters and digits a single space. */
export function normalize(s: string) {
  return s
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

/** Every character of `q` in order in `t`, starting at the start of a word: 10 to 40, tighter is higher. 0 otherwise. */
function fuzzy(q: string, t: string) {
  let best = 0;
  for (let start = t.indexOf(q[0]); start !== -1; start = t.indexOf(q[0], start + 1)) {
    if (start > 0 && t[start - 1] !== ' ') continue;
    let i = start;
    let gaps = 0;
    let ok = true;
    for (let k = 1; k < q.length; k++) {
      let j = i + 1;
      while (j < t.length && t[j] !== q[k]) j++;
      if (j >= t.length) {
        ok = false;
        break;
      }
      gaps += j - i - 1;
      i = j;
    }
    if (ok) best = Math.max(best, Math.max(10, 40 - gaps * 3));
  }
  return best;
}

/**
 * How well one text matches the (normalized) query: 100 the same, 90 it starts the text, 80 each query word starts
 * a word, 70 the words' initials ("rhr", "hr" for heart rate), 50 it's inside the text, then 10–40 for the letters in
 * order (three letters or more). 0 for no match.
 */
export function matchScore(query: string, text: string): number {
  const q = normalize(query);
  const t = normalize(text);
  if (!q || !t) return 0;
  if (t === q) return 100;
  if (t.startsWith(q)) return 90;
  const words = t.split(' ');
  const tokens = q.split(' ');
  if (tokens.every((tok) => words.some((w) => w.startsWith(tok)))) return 80;
  const initials = words.map((w) => w[0]).join('');
  const flatQ = q.replace(/ /g, '');
  if (words.length > 1 && flatQ.length >= 2 && initials === flatQ) return 70;
  if (words.length > 1 && flatQ.length >= 2 && initials.includes(flatQ)) return 60;
  if (t.replace(/ /g, '').includes(flatQ)) return 50;
  return flatQ.length >= 3 ? fuzzy(flatQ, t) : 0;
}

/** An item's score: the best of its label (in full), a keyword (a little less) and where it is (less again). */
export function itemScore(query: string, it: SearchItem): number {
  const label = matchScore(query, it.label);
  const words = Math.max(0, ...(it.keywords ?? []).map((k) => matchScore(query, k) * 0.9));
  const hint = it.hint ? matchScore(query, `${it.hint} ${it.label}`) * 0.8 : 0;
  return Math.max(label, words, hint);
}

export type SearchSection = { group: SearchGroup; label: string; items: SearchItem[] };

/** "Ask McFly about …" for whatever was typed: opens Ask McFly with it as the question (handed over in the tab, never the address). */
export const askItem = (query: string): SearchItem => ({
  id: 'action.ask',
  group: 'actions',
  label: `Ask McFly about “${query.trim()}”`,
  to: '#/mcfly',
  ask: query.trim(),
});

/**
 * The palette's results, in sections. Nothing typed: the pages, then the actions. Otherwise every match, best first
 * (ties go to the earlier group, then the catalogue's order), sections ordered by their best match so the first
 * result is the best one, at most `perGroup` in each, and "Ask McFly about …" last.
 */
export function rank(query: string, items: SearchItem[], perGroup = 6): SearchSection[] {
  const label = (g: SearchGroup) => GROUPS.find((x) => x.id === g)!.label;
  const order = (g: SearchGroup) => GROUPS.findIndex((x) => x.id === g);
  if (!normalize(query)) {
    return (['pages', 'actions'] as const)
      .map((g) => ({ group: g, label: label(g), items: items.filter((it) => it.group === g) }))
      .filter((s) => s.items.length);
  }
  const scored = items
    .map((it, i) => ({ it, i, score: itemScore(query, it) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score || order(a.it.group) - order(b.it.group) || a.i - b.i);
  const sections: SearchSection[] = [];
  for (const { it } of scored) {
    let s = sections.find((x) => x.group === it.group);
    if (!s) sections.push((s = { group: it.group, label: label(it.group), items: [] }));
    if (s.items.length < perGroup) s.items.push(it);
  }
  const ask = askItem(query);
  const actions = sections.find((x) => x.group === 'actions');
  if (actions) {
    sections.splice(sections.indexOf(actions), 1);
    actions.items.push(ask);
    sections.push(actions);
  } else sections.push({ group: 'actions', label: label('actions'), items: [ask] });
  return sections;
}

// ---------- the shortcut ----------

/** `key` can be missing: a browser's autofill sends a keydown without one. */
export type KeyLike = { key?: string; code?: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean; isComposing?: boolean; repeat?: boolean };

/**
 * ⌘K on a Mac (or iPad), Ctrl+K elsewhere; not while composing text or holding the key down. The K is the letter
 * typed. Only when the key gives no Latin letter (a Cyrillic or Greek layout) does the key in QWERTY's K position
 * count, so on Dvorak or Colemak that key (T or E there) keeps its own shortcut.
 */
export function isPaletteShortcut(e: KeyLike, mac: boolean) {
  if (e.isComposing || e.repeat || e.altKey || e.shiftKey) return false;
  const k = typeof e.key === 'string' ? e.key.toLowerCase() : '';
  if (k !== 'k' && !(e.code === 'KeyK' && !/^\p{Script=Latin}$/u.test(k))) return false;
  return mac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
}

export type TargetLike = { tagName?: string; isContentEditable?: boolean; type?: string } | null | undefined;

const NOT_TYPING = new Set(['checkbox', 'radio', 'button', 'submit', 'reset', 'range', 'color', 'file', 'image']);

/** The person is typing somewhere: a text field, a text area, a select or editable content. */
export function isTypingTarget(t: TargetLike) {
  if (!t) return false;
  if (t.isContentEditable) return true;
  const tag = (t.tagName ?? '').toUpperCase();
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  return tag === 'INPUT' && !NOT_TYPING.has((t.type || 'text').toLowerCase());
}
