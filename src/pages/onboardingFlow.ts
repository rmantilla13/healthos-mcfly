// The rules behind "Make this space yours" (Onboarding.tsx), kept apart from the page so they can be tested without a
// browser: where a person starts, what each step saves, and what the preview card on step 2 says.
import { PEER_MIN_AGE } from '../../shared/peers.ts';
import type { FigureVariant, Gender, OnboardingStep, Perspective, Settings } from '../../shared/types.ts';

export type Mode = 'new' | 'edit';
/** Everything the three steps ask, held by the page while the person moves between them. */
export type Answers = { perspective: Perspective; gender: Gender | null; figure: FigureVariant | null; age: string; peer: boolean };

/** A new account resumes at the step it reached (a refresh keeps its place); editing always starts at the first. */
export function startStep(s: Pick<Settings, 'onboarding'>, mode: Mode): OnboardingStep {
  if (mode === 'edit') return 1;
  const step = s.onboarding ?? 1;
  return step === 2 || step === 3 ? step : 1;
}

/** What the steps show first: the person's settings as they are (a new account has the server's defaults). */
export const answersFrom = (s: Settings): Answers => ({
  perspective: s.perspective ?? 'portrait',
  gender: s.gender ?? null,
  figure: s.figure ?? null,
  age: s.age != null ? String(s.age) : '',
  peer: Boolean(s.peerComparison),
});

/** The age as typed, when it's a whole number of years the server takes (1–120); otherwise null. */
export function parseAge(text: string): number | null {
  const t = text.trim();
  if (!/^\d{1,3}$/.test(t)) return null;
  const n = Number(t);
  return n >= 1 && n <= 120 ? n : null;
}

export const canJoinPeers = (age: number | null) => age !== null && age >= PEER_MIN_AGE;

/** Woman and Man show their own digital human; anyone else picks one (the man until they do). */
export const choosesFigure = (g: Gender | null) => g === 'nonbinary' || g === 'unsaid';
export const figureOf = (a: Pick<Answers, 'gender' | 'figure'>): FigureVariant =>
  a.gender === 'woman' || a.gender === 'man' ? a.gender : (a.figure ?? 'man');

/**
 * PUT /api/settings for leaving a step forward: that step's answers and, for a new account, the step it moves on to
 * (null finishes). Editing from Profile never touches the onboarding marker.
 */
export function stepSave(step: OnboardingStep, a: Answers, mode: Mode, to: OnboardingStep | null): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (step === 1) body.perspective = a.perspective;
  if (step === 2) {
    if (a.gender) body.gender = a.gender;
    // Woman and Man follow their gender, so a figure picked for another answer earlier doesn't stick.
    body.figure = choosesFigure(a.gender) ? a.figure : null;
    // The page asks for a valid age before leaving step 2; an unreadable one is never sent as a null (which deletes).
    const age = parseAge(a.age);
    if (age !== null) body.age = age;
  }
  // Only ever on with an adult age: someone who went back and changed it never sends a switch the server refuses.
  if (step === 3) body.peerComparison = a.peer && canJoinPeers(parseAge(a.age));
  if (mode === 'new') body.onboarding = to;
  return body;
}

/** Step 2's preview card: what Home and Body will show, for the view chosen on step 1. */
export function preview(a: Answers, hasPhoto: boolean): { eyebrow: string; title: string; text: string } {
  const human = `Digital ${figureOf(a)}`;
  if (a.perspective === 'digital') return { eyebrow: 'Your digital human', title: human, text: 'A Vitruvian-inspired view for your Home and Body pages.' };
  if (a.perspective === 'stats') return { eyebrow: 'Your view', title: 'Just the statistics', text: 'Your Home and Body pages show your measurements, without a figure.' };
  return hasPhoto
    ? { eyebrow: 'Your view', title: 'Your portrait', text: 'Your Home and Body pages show the portrait from your photo.' }
    : { eyebrow: 'Your view', title: 'Your portrait', text: `Until your portrait is made, your Home and Body pages show the ${human.toLowerCase()}.` };
}
