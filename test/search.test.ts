// The ⌘K palette's catalogue and ranking (shared/search.ts): who sees what, how a query matches, and the shortcut.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { type SearchAccess, isPaletteShortcut, isTypingTarget, itemScore, matchScore, normalize, rank, searchItems } from '../shared/search.ts';

const EVERYONE: SearchAccess = { cycleTracking: false, nutrition: false, nutritionAmounts: false, family: false, admin: false };
const ALL: SearchAccess = { cycleTracking: true, nutrition: true, nutritionAmounts: true, family: true, admin: true };
const ids = (a: SearchAccess) => searchItems(a).map((it) => it.id);
const flat = (q: string, a: SearchAccess = ALL) => rank(q, searchItems(a)).flatMap((s) => s.items);

test('the catalogue offers only what this person can open', () => {
  const base = ids(EVERYONE);
  for (const id of ['page.home', 'page.vitals', 'page.body', 'page.sleep', 'page.nutrition', 'page.labs', 'page.mcfly', 'page.integrations', 'page.settings'])
    assert.ok(base.includes(id), id);
  // Cycle only with cycle tracking on, Family only with sign-in and sharing, Admin only for admins.
  for (const id of ['page.cycle', 'metric.cycle', 'page.family', 'page.admin']) assert.ok(!base.includes(id), id);
  // Nutrition's page is always there (it explains itself while off), its tabs and amounts only with amounts on.
  for (const id of ['tab.nutrition.macros', 'tab.nutrition.hydration', 'metric.protein', 'metric.water', 'metric.food']) assert.ok(!base.includes(id), id);
  assert.ok(!ids({ ...EVERYONE, nutrition: true, nutritionAmounts: false }).includes('tab.nutrition.macros'));
  assert.ok(ids({ ...EVERYONE, nutrition: true, nutritionAmounts: false }).includes('metric.food'));
  // Amounts without Nutrition on (a stale setting) still shows nothing of it.
  assert.ok(!ids({ ...EVERYONE, nutritionAmounts: true }).includes('metric.water'));
  const all = ids(ALL);
  for (const id of ['page.cycle', 'page.family', 'page.admin', 'tab.nutrition.macros', 'metric.water']) assert.ok(all.includes(id), id);
  assert.equal(new Set(all).size, all.length, 'ids are unique');
});

test('every entry opens a hash route of the app, with nothing typed in it', () => {
  for (const it of searchItems(ALL)) {
    assert.match(it.to, /^#\/[a-z]*(\?tab=[a-z]+)?$/, it.id);
    assert.equal(it.ask, undefined);
  }
  const ask = flat('my sleep last week').find((it) => it.id === 'action.ask')!;
  assert.equal(ask.to, '#/mcfly');
  assert.equal(ask.ask, 'my sleep last week');
  assert.ok(!ask.to.includes('sleep'));
});

test('text is compared without case, accents or marks', () => {
  assert.equal(normalize('VO₂ max'), 'vo2 max');
  assert.equal(normalize('  Body · Cardiovascular '), 'body cardiovascular');
  assert.equal(normalize('Café'), 'cafe');
  assert.equal(matchScore('SLEEP', 'Sleep'), 100);
  assert.equal(matchScore('vo2', 'VO₂ max'), 90);
});

test('a match scores by how it matches: whole, prefix, word prefix, initials, inside, then letters in order', () => {
  assert.equal(matchScore('sleep', 'Sleep'), 100);
  assert.equal(matchScore('sle', 'Sleep stages'), 90);
  assert.equal(matchScore('stag', 'Sleep stages'), 80);
  assert.equal(matchScore('heart rest', 'Resting heart rate'), 80, 'every word, in any order');
  assert.equal(matchScore('rhr', 'Resting heart rate'), 70);
  assert.equal(matchScore('hr', 'Resting heart rate'), 60);
  assert.equal(matchScore('oxyg', 'blood oxygen'), 80);
  assert.equal(matchScore('xygen', 'Blood oxygen'), 50);
  const fuzzy = matchScore('slp', 'Sleep');
  assert.ok(fuzzy > 0 && fuzzy < 50, `fuzzy ${fuzzy}`);
  // Letters in order must start at a word, and need three of them.
  assert.equal(matchScore('eep', 'Sleep'), 50, 'inside the word');
  assert.equal(matchScore('lep', 'Sleep'), 0, 'letters in order, but not from the start of a word');
  assert.equal(matchScore('lp', 'Sleep'), 0);
  assert.equal(matchScore('zzz', 'Sleep'), 0);
  assert.equal(matchScore('', 'Sleep'), 0);
});

test('prefix matches outrank fuzzy ones, and the label outranks a keyword', () => {
  const items = searchItems(ALL);
  const steps = items.find((it) => it.id === 'metric.steps')!;
  const stages = items.find((it) => it.id === 'metric.stages')!;
  assert.ok(itemScore('st', stages) > 0);
  assert.ok(itemScore('ste', steps) > itemScore('ste', stages), 'Steps starts with "ste"; Sleep stages only has it inside a word');
  const results = flat('ste');
  assert.equal(results[0].id, 'metric.steps');
  // The Sleep page itself beats everything that only mentions sleep.
  assert.equal(flat('sleep')[0].id, 'page.sleep');
  assert.equal(flat('slp')[0].id, 'page.sleep', 'missing letters still find it');
});

test('"hr" finds heart rate, resting heart rate and HRV; "hrv" puts HRV first', () => {
  const hr = flat('hr').map((it) => it.id);
  for (const id of ['metric.hrv', 'metric.rhr', 'metric.hr']) assert.ok(hr.includes(id), id);
  assert.equal(flat('hrv')[0].id, 'metric.hrv');
  assert.equal(flat('rhr')[0].id, 'metric.rhr');
  assert.equal(flat('vo2max')[0].id, 'metric.vo2');
  assert.equal(flat('spo2')[0].id, 'metric.spo2');
  assert.equal(flat('blood sugar')[0].id, 'metric.glucose');
  assert.equal(flat('cholesterol')[0].id, 'metric.labs');
});

test('results come in sections, best first, at most six each, with "Ask McFly about …" last', () => {
  const sections = rank('body', searchItems(ALL));
  assert.equal(sections[0].group, 'pages');
  assert.equal(sections[0].items[0].id, 'page.body');
  for (const s of sections) assert.ok(s.items.length <= 7, s.group);
  assert.ok(sections.filter((s) => s.group !== 'actions').every((s) => s.items.length <= 6));
  const last = sections.at(-1)!;
  assert.equal(last.group, 'actions');
  assert.equal(last.items.at(-1)!.id, 'action.ask');
  assert.equal(last.items.at(-1)!.label, 'Ask McFly about “body”');
  // Each group appears once.
  assert.equal(new Set(sections.map((s) => s.group)).size, sections.length);
  // Nothing matches: only the question for McFly is left.
  const none = rank('qqxj', searchItems(ALL));
  assert.deepEqual(
    none.flatMap((s) => s.items).map((it) => it.id),
    ['action.ask'],
  );
});

test('nothing typed: the pages, then the actions, in the catalogue order', () => {
  const sections = rank('   ', searchItems(EVERYONE));
  assert.deepEqual(
    sections.map((s) => s.group),
    ['pages', 'actions'],
  );
  assert.equal(sections[0].items[0].id, 'page.home');
  assert.ok(!sections.flatMap((s) => s.items).some((it) => it.id === 'action.ask'));
});

test('a hidden page never turns up, however it is searched for', () => {
  for (const q of ['admin', 'cycle', 'period', 'family', 'protein', 'hydration']) {
    const found = flat(q, EVERYONE).map((it) => it.id);
    for (const id of ['page.admin', 'page.cycle', 'metric.cycle', 'page.family', 'metric.protein', 'tab.nutrition.hydration']) assert.ok(!found.includes(id), `${q} → ${id}`);
  }
});

test('the shortcut is ⌘K on a Mac and Ctrl+K elsewhere, never while composing or held down', () => {
  const key = (o: Partial<Parameters<typeof isPaletteShortcut>[0]>) => ({ key: 'k', metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...o });
  assert.ok(isPaletteShortcut(key({ metaKey: true }), true));
  assert.ok(!isPaletteShortcut(key({ ctrlKey: true }), true));
  assert.ok(isPaletteShortcut(key({ ctrlKey: true }), false));
  assert.ok(!isPaletteShortcut(key({ metaKey: true }), false));
  assert.ok(isPaletteShortcut(key({ key: 'K', metaKey: true }), true), 'caps lock');
  assert.ok(isPaletteShortcut(key({ key: 'л', code: 'KeyK', ctrlKey: true }), false), 'another keyboard layout');
  assert.ok(isPaletteShortcut(key({ key: 'κ', code: 'KeyK', metaKey: true }), true), 'Greek');
  // Dvorak and Colemak put T and E where QWERTY has K: those shortcuts stay theirs, and their own K opens search.
  assert.ok(!isPaletteShortcut(key({ key: 't', code: 'KeyK', ctrlKey: true }), false), 'Dvorak Ctrl+T');
  assert.ok(!isPaletteShortcut(key({ key: 'e', code: 'KeyK', metaKey: true }), true), 'Colemak ⌘E');
  assert.ok(isPaletteShortcut(key({ key: 'k', code: 'KeyV', ctrlKey: true }), false), 'Dvorak K');
  assert.ok(isPaletteShortcut(key({ key: 'k', code: 'KeyN', metaKey: true }), true), 'Colemak K');
  // An autofill keydown carries no key at all: no shortcut, and no error.
  assert.ok(!isPaletteShortcut(key({ key: undefined, ctrlKey: true }), false), 'no key');
  assert.ok(!isPaletteShortcut({ metaKey: false, ctrlKey: false, altKey: false, shiftKey: false }, true), 'no key or code');
  assert.ok(!isPaletteShortcut(key({ metaKey: true, shiftKey: true }), true));
  assert.ok(!isPaletteShortcut(key({ metaKey: true, altKey: true }), true));
  assert.ok(!isPaletteShortcut(key({ metaKey: true, repeat: true }), true));
  assert.ok(!isPaletteShortcut(key({ metaKey: true, isComposing: true }), true));
  assert.ok(!isPaletteShortcut(key({ key: 'j', metaKey: true }), true));
  assert.ok(!isPaletteShortcut(key({}), true));
});

test('typing somewhere keeps the shortcut out of the way', () => {
  assert.ok(isTypingTarget({ tagName: 'INPUT', type: 'text' }));
  assert.ok(isTypingTarget({ tagName: 'input' }));
  assert.ok(isTypingTarget({ tagName: 'INPUT', type: 'search' }));
  assert.ok(isTypingTarget({ tagName: 'TEXTAREA' }));
  assert.ok(isTypingTarget({ tagName: 'SELECT' }));
  assert.ok(isTypingTarget({ tagName: 'DIV', isContentEditable: true }));
  assert.ok(!isTypingTarget({ tagName: 'INPUT', type: 'checkbox' }));
  assert.ok(!isTypingTarget({ tagName: 'BUTTON' }));
  assert.ok(!isTypingTarget({ tagName: 'BODY' }));
  assert.ok(!isTypingTarget(null));
});
