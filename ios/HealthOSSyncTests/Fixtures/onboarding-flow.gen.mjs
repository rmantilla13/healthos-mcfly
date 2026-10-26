// The web's own rules (src/pages/onboardingFlow.ts) run over a spread of answers, for the iPhone's port
// (Onboarding/OnboardingFlow.swift) to match in OnboardingTests. From the repository's root, after a change there:
//   node ios/HealthOSSyncTests/Fixtures/onboarding-flow.gen.mjs > ios/HealthOSSyncTests/Fixtures/onboarding-flow.json
import { pathToFileURL } from 'node:url';

const f = await import(pathToFileURL(`${process.cwd()}/src/pages/onboardingFlow.ts`).href);
const genders = [null, 'woman', 'man', 'nonbinary', 'unsaid'];
const figures = [null, 'woman', 'man'];
const answers = [];
for (const perspective of ['portrait', 'digital', 'stats']) answers.push({ perspective, gender: null, figure: null, age: '', peer: false });
for (const gender of genders) for (const figure of figures) answers.push({ perspective: 'portrait', gender, figure, age: '40', peer: true });
for (const age of ['', '0', '16', '17', '18', 'x', '121', ' 33 ']) answers.push({ perspective: 'digital', gender: 'man', figure: null, age, peer: true });
answers.push({ perspective: 'stats', gender: 'unsaid', figure: 'woman', age: '40', peer: false });

// Rows name their answers by index ("a"), so each is written once.
const out = { answers, startStep: [], answersFrom: [], parseAge: [], figureOf: [], stepSave: [], forwardSave: [], preview: [], portraitNext: [] };
for (const onboarding of [null, 1, 2, 3, 4, 0]) for (const mode of ['new', 'edit']) out.startStep.push({ onboarding, mode, step: f.startStep({ onboarding }, mode) });
for (const settings of [{}, { perspective: 'stats', gender: 'nonbinary', figure: 'woman', age: 33, peerComparison: true }, { perspective: 'digital', gender: 'man', figure: null, age: null, peerComparison: false }])
  out.answersFrom.push({ settings, answers: f.answersFrom(settings) });
for (const text of ['', '0', '7', '17', '18', '40', '120', '121', 'x', ' 33 ', '1000', '33.5', '-4', '٣٣']) out.parseAge.push({ text, age: f.parseAge(text) });
for (const gender of genders) for (const figure of figures) out.figureOf.push({ gender, figure, variant: f.figureOf({ gender, figure }) });
answers.forEach((a, i) => {
  for (const mode of ['new', 'edit']) {
    for (const step of [1, 2, 3]) {
      const to = step < 3 ? step + 1 : null;
      out.stepSave.push({ step, a: i, mode, to, body: f.stepSave(step, a, mode, to) });
    }
    for (const from of [1, 2, 3]) for (const to of [2, 3, null]) if (to === null || to > from) out.forwardSave.push({ from, a: i, mode, to, left: f.stepsLeft(from, to), body: f.forwardSave(from, a, mode, to) });
  }
});
for (const perspective of ['portrait', 'digital', 'stats']) for (const gender of genders) for (const hasPhoto of [false, true]) for (const drawn of ['man', 'woman']) {
  const a = { perspective, gender, figure: null, age: '', peer: false };
  out.preview.push({ answers: a, hasPhoto, drawn, card: f.preview(a, hasPhoto, drawn) });
}
const key = (provider) => ({ provider, last4: '1234', model: null, addedAt: 1, lastUsedAt: null, lastError: null });
for (const ai of [null, { byok: true, portraits: true, keys: [key('openai')] }, { byok: true, portraits: false, keys: [key('anthropic')] }, { byok: false, portraits: true, keys: [] }, { byok: false, portraits: false, keys: [] }])
  for (const hasPhoto of [false, true]) out.portraitNext.push({ ai, hasPhoto, line: f.portraitNext(ai ?? undefined, hasPhoto) });
console.log(JSON.stringify(out, null, 0).replace(/\},\{"(step|from|onboarding|settings|text|gender|answers|ai|perspective)"/g, '},\n{"$1"'));
