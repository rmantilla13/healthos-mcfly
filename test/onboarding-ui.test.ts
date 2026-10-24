// The onboarding page's rules (src/pages/onboardingFlow.ts): where a person starts, what each step saves (and that
// editing from Profile never writes the onboarding marker), what a step tab that jumps ahead saves, the age it takes,
// step 1's portrait line and the step 2 preview card.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Settings } from '../shared/types.ts';
import { type Answers, answersFrom, canJoinPeers, figureOf, forwardSave, parseAge, portraitNext, preview, startStep, stepSave, stepsLeft } from '../src/pages/onboardingFlow.ts';

const answers = (a: Partial<Answers> = {}): Answers => ({ perspective: 'portrait', gender: null, figure: null, age: '', peer: false, ...a });

test('a new account resumes at its step; editing starts at the first', () => {
  assert.equal(startStep({ onboarding: 2 }, 'new'), 2);
  assert.equal(startStep({ onboarding: 3 }, 'new'), 3);
  assert.equal(startStep({ onboarding: null }, 'new'), 1);
  assert.equal(startStep({ onboarding: 3 }, 'edit'), 1);
});

test('the steps start from the settings as they are', () => {
  const a = answersFrom({ perspective: 'stats', gender: 'nonbinary', figure: 'woman', age: 33, peerComparison: true } as Settings);
  assert.deepEqual(a, { perspective: 'stats', gender: 'nonbinary', figure: 'woman', age: '33', peer: true });
  // An older server without the fields: the defaults.
  assert.deepEqual(answersFrom({} as Settings), answers());
});

test('an age is a whole number of years from 1 to 120', () => {
  assert.equal(parseAge('33'), 33);
  assert.equal(parseAge(' 7 '), 7);
  for (const bad of ['', '0', '121', '33.5', '3x', '-4', '1000']) assert.equal(parseAge(bad), null, bad);
  assert.equal(canJoinPeers(17), false);
  assert.equal(canJoinPeers(18), true);
  assert.equal(canJoinPeers(null), false);
});

test('each step saves its own answers and, for a new account, the next step', () => {
  assert.deepEqual(stepSave(1, answers({ perspective: 'digital' }), 'new', 2), { perspective: 'digital', onboarding: 2 });
  assert.deepEqual(stepSave(2, answers({ gender: 'woman', figure: 'man', age: '40' }), 'new', 3), { gender: 'woman', figure: null, age: 40, onboarding: 3 });
  assert.deepEqual(stepSave(2, answers({ gender: 'unsaid', figure: 'woman', age: '40' }), 'new', 3), { gender: 'unsaid', figure: 'woman', age: 40, onboarding: 3 });
  // No gender chosen: neither it nor the figure is sent (a figure chosen before stays). An unreadable age is never
  // sent as null, which would delete the one saved.
  assert.deepEqual(stepSave(2, answers({ figure: 'woman', age: 'x' }), 'new', 3), { onboarding: 3 });
  assert.deepEqual(stepSave(3, answers({ age: '40', peer: true }), 'new', null), { peerComparison: true, onboarding: null });
});

test('editing from Profile never touches the onboarding marker', () => {
  for (const step of [1, 2, 3] as const) assert.equal('onboarding' in stepSave(step, answers({ age: '40' }), 'edit', null), false);
});

test('a step tab that jumps ahead saves every step it passes, in one request', () => {
  // Step 2 edited, Back to step 1 (nothing saved), then the 03 tab: the gender and age are saved with step 1's view.
  const a = answers({ perspective: 'digital', gender: 'man', age: '40', peer: true });
  assert.deepEqual(stepsLeft(1, 3), [1, 2]);
  assert.deepEqual(forwardSave(1, a, 'edit', 3), { perspective: 'digital', gender: 'man', figure: null, age: 40 });
  assert.deepEqual(forwardSave(1, a, 'new', 3), { perspective: 'digital', gender: 'man', figure: null, age: 40, onboarding: 3 });
  // Continue saves only the step it leaves, and finishing from step 3 only step 3.
  assert.deepEqual(stepsLeft(1, 2), [1]);
  assert.deepEqual(forwardSave(1, a, 'edit', 2), { perspective: 'digital' });
  assert.deepEqual(stepsLeft(3, null), [3]);
  assert.deepEqual(forwardSave(3, a, 'edit', null), { peerComparison: true });
  // From step 2 to finish (never a tab today, but the same rule): steps 2 and 3, the age before the switch.
  assert.deepEqual(forwardSave(2, a, 'new', null), { gender: 'man', figure: null, age: 40, peerComparison: true, onboarding: null });
  // Step 2 is among the steps a jump from 1 to 3 leaves, so the page asks for the age before it saves.
  assert.ok(stepsLeft(1, 3).includes(2));
  assert.ok(!stepsLeft(1, 2).includes(2));
});

test('taking part is only ever sent on with an adult age', () => {
  assert.equal(stepSave(3, answers({ age: '16', peer: true }), 'new', null).peerComparison, false);
  assert.equal(stepSave(3, answers({ age: '', peer: true }), 'edit', null).peerComparison, false);
  assert.equal(stepSave(3, answers({ age: '18', peer: false }), 'edit', null).peerComparison, false);
});

test('the digital human follows Woman and Man, and is chosen for any other answer', () => {
  assert.equal(figureOf({ gender: 'woman', figure: 'man' }), 'woman');
  assert.equal(figureOf({ gender: 'man', figure: null }), 'man');
  assert.equal(figureOf({ gender: 'nonbinary', figure: 'woman' }), 'woman');
  assert.equal(figureOf({ gender: 'unsaid', figure: null }), 'man');
  assert.equal(figureOf({ gender: null, figure: null }), 'man');
});

test('the preview card says what Home will show, naming the figure actually drawn', () => {
  assert.equal(preview(answers({ perspective: 'digital', gender: 'woman' }), false, 'woman').title, 'Digital woman');
  // The woman's artwork isn't there yet, so the man's is drawn, and that's what it's called.
  assert.equal(preview(answers({ perspective: 'digital', gender: 'woman' }), false, 'man').title, 'Digital man');
  assert.match(preview(answers({ gender: 'nonbinary', figure: 'woman' }), false, 'man').text, /Until your portrait is made.*digital man/);
  assert.equal(preview(answers({ perspective: 'digital' }), false, 'man').eyebrow, 'Your digital human');
  assert.equal(preview(answers({ perspective: 'stats' }), true, 'man').title, 'Just the statistics');
  assert.match(preview(answers({ gender: 'man' }), false, 'man').text, /Until your portrait is made.*digital man/);
  assert.doesNotMatch(preview(answers(), true, 'man').text, /Until/);
});

test("step 1's portrait line says where a portrait is made on this server, and nothing until it knows", () => {
  const key = { provider: 'openai' as const, last4: '1234', model: null, addedAt: 1, lastUsedAt: null, lastError: null };
  assert.equal(portraitNext(undefined, false), null);
  assert.match(portraitNext({ byok: true, portraits: true, keys: [key] }, false) ?? '', /on your OpenAI key\.$/);
  assert.match(portraitNext({ byok: true, portraits: false, keys: [] }, false) ?? '', /connect your own there/);
  // The server's key, and no way to store one's own: no connect clause.
  const shared = portraitNext({ byok: false, portraits: true, keys: [] }, false) ?? '';
  assert.match(shared, /this healthOS server's OpenAI key/);
  assert.doesNotMatch(shared, /connect/);
  // Neither: no promise of a portrait studio that can't make one.
  const none = portraitNext({ byok: false, portraits: false, keys: [] }, false) ?? '';
  assert.match(none, /aren't available on this server yet.*the digital human meanwhile/);
  assert.doesNotMatch(none, /OpenAI|connect/);
  assert.match(portraitNext({ byok: false, portraits: false, keys: [] }, true) ?? '', /your cut-out photo meanwhile/);
});
