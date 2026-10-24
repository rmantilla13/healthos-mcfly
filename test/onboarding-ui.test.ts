// The onboarding page's rules (src/pages/onboardingFlow.ts): where a person starts, what each step saves (and that
// editing from Profile never writes the onboarding marker), the age it takes, and the step 2 preview card.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Settings } from '../shared/types.ts';
import { type Answers, answersFrom, canJoinPeers, figureOf, parseAge, preview, startStep, stepSave } from '../src/pages/onboardingFlow.ts';

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

test('the preview card says what Home will show', () => {
  assert.equal(preview(answers({ perspective: 'digital', gender: 'woman' }), false).title, 'Digital woman');
  assert.equal(preview(answers({ perspective: 'digital' }), false).eyebrow, 'Your digital human');
  assert.equal(preview(answers({ perspective: 'stats' }), true).title, 'Just the statistics');
  assert.match(preview(answers({ gender: 'man' }), false).text, /Until your portrait is made.*digital man/);
  assert.doesNotMatch(preview(answers(), true).text, /Until/);
});
