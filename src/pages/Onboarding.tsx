// "Make this space yours": three steps a new account goes through once, full screen, before the dashboard. Settings.
// onboarding is the step it's on and each Continue saves that step, so a refresh resumes there. #/welcome (Profile →
// Edit preferences) runs the same steps again, prefilled and without the onboarding marker, and returns to Profile.
// Nothing on the server waits for it: the API and the iPhone app work the same before, during and after.
import { useEffect, useRef, useState, type FormEvent, type RefObject } from 'react';
import type { AiStatus } from '../../shared/ai.ts';
import { PEER_MIN_AGE, PEER_MIN_DAYS, PEER_MIN_OTHERS, PEER_WINDOW_DAYS } from '../../shared/peers.ts';
import type { PortraitList } from '../../shared/portraits.ts';
import type { FigureVariant, Gender, OnboardingStep, Perspective, PhotoMeta, Status } from '../../shared/types.ts';
import { useDrawnVariant } from '../components/Figure.tsx';
import { Icon } from '../components/Icon.tsx';
import { WelcomeFoot, WelcomeShell } from '../components/WelcomeShell.tsx';
import { getJson, href, notifyDataChanged, sendJson, signOut, useApi } from '../lib.ts';
import { shrinkReference, uploadReference } from '../portraits.ts';
import {
  type Answers,
  type Mode,
  answersFrom,
  canJoinPeers,
  choosesFigure,
  figureOf,
  forwardSave,
  parseAge,
  portraitNext,
  preview,
  startStep,
  stepsLeft,
} from './onboardingFlow.ts';
import '../styles/onboarding.css';

const STEPS: { n: OnboardingStep; label: string; title: string; lede: string; hint: string }[] = [
  {
    n: 1,
    label: 'Your perspective',
    title: 'How would you like to see yourself?',
    lede: 'Choose a view for your Home and Body pages. You can change it anytime.',
    hint: 'Your image is the default. Your choice is always yours.',
  },
  { n: 2, label: 'A little about you', title: 'The context behind your numbers.', lede: 'A few details help make your workspace more personal.', hint: 'Just a little context.' },
  {
    n: 3,
    label: 'Your community',
    title: 'Your progress, in perspective.',
    lede: 'See where your readings sit among people your age. Participation is optional.',
    hint: 'Your preferences can be changed anytime.',
  },
];

export function Onboarding({ status, reload, signedIn, mode }: { status: Status; reload: () => void; signedIn: boolean; mode: Mode }) {
  const [step, setStep] = useState<OnboardingStep>(() => startStep(status.settings, mode));
  // The furthest step reached: its tab and every one before it open again. Editing has every answer already.
  const [furthest, setFurthest] = useState<OnboardingStep>(() => (mode === 'edit' ? 3 : startStep(status.settings, mode)));
  const [answers, setAnswers] = useState<Answers>(() => answersFrom(status.settings));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ageError, setAgeError] = useState(false);
  const reference = useReferencePhoto();
  const heading = useRef<HTMLHeadingElement>(null);
  const ageInput = useRef<HTMLInputElement>(null);
  // Sent back to step 2 for its age: the field gets focus once it's there, not the heading.
  const focusAge = useRef(false);
  const shown = useRef(step);
  const meta = STEPS[step - 1];
  const set = (patch: Partial<Answers>) => setAnswers((a) => ({ ...a, ...patch }));

  // A new step is announced and starts at its top: focus moves to its heading (not on the first render).
  useEffect(() => {
    if (shown.current === step) return;
    shown.current = step;
    window.scrollTo({ top: 0 });
    if (focusAge.current) {
      focusAge.current = false;
      ageInput.current?.focus();
    } else heading.current?.focus();
  }, [step]);

  /**
   * Back keeps what's chosen here (saved when the person moves forward again); forward saves every step it leaves
   * behind in one go, so a tab that jumps past step 2 still saves its answers, and first asks for its age.
   */
  async function go(to: OnboardingStep | 'done') {
    setError(null);
    if (to !== 'done' && to < step) return setStep(to);
    const target = to === 'done' ? null : to;
    if (stepsLeft(step, target).includes(2) && parseAge(answers.age) === null) {
      setAgeError(true);
      if (step === 2) ageInput.current?.focus();
      else {
        focusAge.current = true;
        setStep(2);
      }
      return;
    }
    setBusy(true);
    try {
      await sendJson('PUT', '/settings', forwardSave(step, answers, mode, target));
    } catch (e) {
      setBusy(false);
      return setError((e as Error).message);
    }
    if (to === 'done') {
      // A new account lands on Home (whatever address it signed up on); editing goes back to Profile. Busy stays on
      // until the dashboard replaces this page.
      location.hash = mode === 'edit' ? href('profile') : href('home');
      reload();
      notifyDataChanged();
      return;
    }
    setBusy(false);
    setStep(to);
    setFurthest((f) => (to > f ? to : f));
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!busy) void go(step === 3 ? 'done' : ((step + 1) as OnboardingStep));
  }

  const back =
    step > 1 ? (
      <button type="button" className="onb-back" onClick={() => go((step - 1) as OnboardingStep)} disabled={busy}>
        <span aria-hidden="true">←</span> Back
      </button>
    ) : mode === 'edit' ? (
      <a className="onb-back" href={href('profile')}>
        <span aria-hidden="true">←</span> Back
      </a>
    ) : null;
  const next = step < 3 ? 'Continue' : mode === 'edit' ? 'Save preferences' : 'Enter my workspace';
  const end =
    mode === 'edit' ? (
      <a className="onb-top-link" href={href('profile')}>
        Back to Profile
      </a>
    ) : signedIn ? (
      <button type="button" className="onb-top-link" onClick={signOut}>
        Sign out
      </button>
    ) : undefined;

  return (
    <WelcomeShell end={end}>
      <form className="card onb-card" onSubmit={submit} aria-labelledby="onb-title" noValidate>
        <StepTabs step={step} furthest={furthest} busy={busy} onOpen={(n) => void go(n)} />
        <div className="onb-head">
          <p className="eyebrow">Make this space yours</p>
          <h1 id="onb-title" ref={heading} tabIndex={-1}>
            {meta.title}
          </h1>
          <p className="onb-lede">{meta.lede}</p>
        </div>

        {step === 1 && <PerspectiveStep answers={answers} set={set} reference={reference} hasPhoto={Boolean(status.photo)} />}
        {step === 2 && (
          <AboutStep
            answers={answers}
            set={set}
            photo={status.photo}
            ageInput={ageInput}
            ageError={ageError}
            onAge={(age) => {
              const n = parseAge(age);
              if (n !== null) setAgeError(false);
              // Under 18, taking part is off: the box on the next step starts empty if the age goes back up.
              set(n !== null && n < PEER_MIN_AGE ? { age, peer: false } : { age });
            }}
          />
        )}
        {step === 3 && <CommunityStep answers={answers} set={set} />}

        <div className="onb-error" role="alert">
          {error && (
            <p className="note-bad">
              <Icon name="alert" size={15} /> {error}
            </p>
          )}
        </div>
        <WelcomeFoot
          start={
            <>
              {back}
              <span className="onb-hint">{meta.hint}</span>
            </>
          }
        >
          <button type="submit" className="btn btn-primary onb-next" disabled={busy}>
            {busy ? 'Saving…' : next}
            {!busy && !(step === 3 && mode === 'edit') && <Icon name="arrow-up-right" size={14} />}
          </button>
        </WelcomeFoot>
      </form>
    </WelcomeShell>
  );
}

/** 01 Your perspective · 02 A little about you · 03 Your community. A step reached can be opened again. */
function StepTabs({ step, furthest, busy, onOpen }: { step: OnboardingStep; furthest: OnboardingStep; busy: boolean; onOpen: (n: OnboardingStep) => void }) {
  return (
    <nav aria-label="Steps">
      <ol className="onb-steps">
        {STEPS.map((s) => {
          const label = (
            <>
              <span className="onb-step-n">{String(s.n).padStart(2, '0')}</span>
              <span className="onb-step-label">{s.label}</span>
            </>
          );
          return (
            <li key={s.n} className={`onb-step${s.n <= furthest ? ' is-reached' : ''}${s.n === step ? ' is-current' : ''}`}>
              {s.n === step ? (
                <span aria-current="step">{label}</span>
              ) : s.n <= furthest ? (
                <button type="button" onClick={() => onOpen(s.n)} disabled={busy}>
                  {label}
                </button>
              ) : (
                <span>{label}</span>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}

// ---------- step 1: your perspective ----------

const VIEWS: { id: Perspective; title: string; text: string }[] = [
  { id: 'portrait', title: 'Your own portrait', text: 'Your likeness, rendered in the healthOS style from a photo.' },
  { id: 'digital', title: 'Digital human', text: 'A modern Vitruvian figure, no photo needed.' },
  { id: 'stats', title: 'Just the statistics', text: 'Your measurements take the whole stage.' },
];

function PerspectiveStep({ answers, set, reference, hasPhoto }: { answers: Answers; set: (p: Partial<Answers>) => void; reference: ReferencePhoto; hasPhoto: boolean }) {
  return (
    <>
      {/* Native radios: the arrow keys move between the cards and choose, as in any radio group. */}
      <div className="onb-choices" role="radiogroup" aria-labelledby="onb-title">
        {VIEWS.map((v) => (
          <label key={v.id} className={`onb-choice${answers.perspective === v.id ? ' is-on' : ''}`}>
            <input
              type="radio"
              className="onb-radio"
              name="perspective"
              checked={answers.perspective === v.id}
              onChange={() => set({ perspective: v.id })}
              aria-labelledby={`onb-view-${v.id}`}
              aria-describedby={`onb-view-${v.id}-text`}
            />
            <span className="onb-choice-art" aria-hidden="true">
              {v.id === 'portrait' ? <BustArt /> : v.id === 'digital' ? <HumanArt key={figureOf(answers)} variant={figureOf(answers)} /> : <StatsArt />}
            </span>
            <span className="onb-choice-title" id={`onb-view-${v.id}`}>
              {v.title}
              {v.id === 'portrait' && <span className="onb-badge">Default</span>}
            </span>
            <span className="onb-choice-text" id={`onb-view-${v.id}-text`}>
              {v.text}
            </span>
          </label>
        ))}
      </div>
      {answers.perspective === 'portrait' && <ReferenceRow reference={reference} hasPhoto={hasPhoto} />}
    </>
  );
}

function ReferenceRow({ reference, hasPhoto }: { reference: ReferencePhoto; hasPhoto: boolean }) {
  const input = useRef<HTMLInputElement>(null);
  const { photo, note, earlier, choose, remove } = reference;
  const saving = photo?.state === 'saving';
  const { data: ai } = useApi<AiStatus>('/ai');
  const next = portraitNext(ai, hasPhoto);
  return (
    <div className="onb-reference">
      <div className="onb-reference-row">
        {photo && <img className="onb-reference-thumb" src={photo.preview} alt="The photo you chose" />}
        <div className="onb-reference-copy">
          <p className="onb-reference-title">The reference for your portrait</p>
          <p className="onb-reference-text">Choose a clear photo of just you. We use it to create your portrait, with the healthOS figure as the style reference.</p>
          <p className="onb-reference-state" aria-live="polite">
            {photo?.state === 'saving' && 'Saving your photo…'}
            {photo?.state === 'saved' && (
              <span className="onb-saved">
                <Icon name="check" size={14} /> Saved for your portrait studio.
              </span>
            )}
            {!photo && earlier > 0 && 'A photo you added earlier is saved for your portrait studio.'}
          </p>
          {note && <p className="onb-reference-note">{note}</p>}
        </div>
        <input
          ref={input}
          type="file"
          accept="image/*"
          hidden
          onChange={(e) => {
            void choose(e.target.files?.[0]);
            // The same file can be chosen again after Remove.
            e.target.value = '';
          }}
        />
        <div className="onb-reference-actions">
          <button type="button" className="btn" onClick={() => input.current?.click()} disabled={saving}>
            {photo ? 'Change' : 'Choose photo'}
          </button>
          {photo && (
            <button type="button" className="btn btn-quiet" onClick={() => void remove()} disabled={saving}>
              Remove
            </button>
          )}
        </div>
      </div>
      <p className="onb-reference-after">
        {next && `${next} `}Your photo stays private; it is not displayed on your dashboard. You can do this later.
      </p>
    </div>
  );
}

// The portrait's reference photo, chosen on step 1. It lives on the page (not the step) so leaving step 1 while it
// uploads doesn't lose it, and nothing waits for it: Continue works whether it saved, failed or is still going. It's
// shrunk and saved by src/portraits.ts, as the portrait studio in Profile does, and the save answers with its id.

type ReferencePhoto = ReturnType<typeof useReferencePhoto>;
type Chosen = { preview: string; state: 'saving' | 'saved' | 'failed'; id: string | null };

const NOT_SAVED = "Your photo couldn't be saved just now. You can add it later in your Profile.";

function useReferencePhoto() {
  const [photo, setPhoto] = useState<Chosen | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [earlier, setEarlier] = useState(0);

  useEffect(() => {
    getJson<PortraitList>('/portraits')
      .then((list) => setEarlier(list.portraits.filter((p) => p.kind === 'reference').length))
      .catch(() => {});
  }, []);

  async function choose(file: File | undefined) {
    if (!file) return;
    setNote(null);
    if (!file.type.startsWith('image/') && !/\.(heic|heif)$/i.test(file.name)) return setNote('Choose an image file (JPEG or PNG).');
    let shrunk: Awaited<ReturnType<typeof shrinkReference>>;
    try {
      shrunk = await shrinkReference(file);
    } catch {
      return setNote("That photo couldn't be opened here. Try a JPEG or PNG.");
    }
    const replacing = photo?.state === 'saved' ? photo.id : null;
    setPhoto({ preview: shrunk.preview, state: 'saving', id: null });
    let id: string;
    try {
      id = (await uploadReference(shrunk.input)).id;
    } catch {
      setPhoto({ preview: shrunk.preview, state: 'failed', id: null });
      return setNote(NOT_SAVED);
    }
    setPhoto({ preview: shrunk.preview, state: 'saved', id });
    // Changing the photo replaces the one chosen a moment ago, rather than keeping both.
    if (replacing) void sendJson('DELETE', `/portraits/${encodeURIComponent(replacing)}`).catch(() => {});
  }

  async function remove() {
    setNote(null);
    if (photo?.state === 'saved' && photo.id) {
      try {
        await sendJson('DELETE', `/portraits/${encodeURIComponent(photo.id)}`);
      } catch {
        return setNote("Your photo couldn't be removed just now. Try again, or remove it later in your Profile.");
      }
    }
    setPhoto(null);
  }

  return { photo, note, earlier, choose, remove };
}

// ---------- step 2: a little about you ----------

const GENDER_CHOICES: { id: Gender; label: string }[] = [
  { id: 'woman', label: 'Woman' },
  { id: 'man', label: 'Man' },
  { id: 'nonbinary', label: 'Non-binary' },
  { id: 'unsaid', label: 'Prefer not to say' },
];

function AboutStep({
  answers,
  set,
  photo,
  ageInput,
  ageError,
  onAge,
}: {
  answers: Answers;
  set: (p: Partial<Answers>) => void;
  photo: PhotoMeta | null;
  ageInput: RefObject<HTMLInputElement | null>;
  ageError: boolean;
  onAge: (age: string) => void;
}) {
  const variant = figureOf(answers);
  // The title names the figure drawn: the man's until the woman's artwork is there, whichever is chosen.
  const card = preview(answers, Boolean(photo), useDrawnVariant(variant));
  return (
    <div className="onb-about">
      <div className="onb-question">
        <p className="onb-label" id="onb-gender-q">
          How do you describe yourself?
        </p>
        <div className="onb-chips" role="group" aria-labelledby="onb-gender-q" aria-describedby="onb-gender-note">
          {GENDER_CHOICES.map((g) => (
            <button
              key={g.id}
              type="button"
              className={`onb-chip${answers.gender === g.id ? ' is-on' : ''}`}
              aria-pressed={answers.gender === g.id}
              onClick={() => set({ gender: g.id })}
            >
              {g.label}
            </button>
          ))}
        </div>
        <p className="onb-note" id="onb-gender-note">
          Used for your profile, not to assume a body type or assign a health score.
        </p>
      </div>

      <div className="onb-about-row">
        <div className="onb-age">
          <label className="onb-label" htmlFor="onb-age">
            Your age
          </label>
          <div className="onb-age-field">
            <input
              id="onb-age"
              ref={ageInput}
              inputMode="numeric"
              pattern="[0-9]*"
              maxLength={3}
              autoComplete="off"
              value={answers.age}
              onChange={(e) => onAge(e.target.value.replace(/\D/g, '').slice(0, 3))}
              aria-required="true"
              aria-invalid={ageError || undefined}
              aria-describedby={`onb-age-unit${ageError ? ' onb-age-error' : ''} onb-age-note`}
            />
            <span id="onb-age-unit">years</span>
          </div>
          {ageError && (
            <p className="note-bad onb-age-error" id="onb-age-error">
              Enter your age in whole years.
            </p>
          )}
        </div>

        <div className={`onb-preview is-${answers.perspective}`}>
          <span className="onb-preview-art" aria-hidden="true">
            {answers.perspective === 'stats' ? (
              <StatsArt />
            ) : answers.perspective === 'portrait' && photo ? (
              <img src={`/api/profile/cutout.png?v=${photo.version}`} alt="" />
            ) : (
              <HumanArt key={variant} variant={variant} />
            )}
          </span>
          <div className="onb-preview-copy">
            <div aria-live="polite">
              <p className="eyebrow">{card.eyebrow}</p>
              <p className="onb-preview-title">{card.title}</p>
              <p className="onb-preview-text">{card.text}</p>
            </div>
            {choosesFigure(answers.gender) && !(answers.perspective === 'stats') && !(answers.perspective === 'portrait' && photo) && (
              <FigurePick value={variant} onPick={(figure) => set({ figure })} />
            )}
          </div>
        </div>
      </div>
      <p className="onb-note" id="onb-age-note">
        Your age is kept private. Peer comparisons are for people aged {PEER_MIN_AGE} and over.
      </p>
    </div>
  );
}

/** For Non-binary and Prefer not to say: which digital human to show (Settings.figure). */
function FigurePick({ value, onPick }: { value: FigureVariant; onPick: (f: FigureVariant) => void }) {
  return (
    <div className="onb-figure-pick" role="group" aria-labelledby="onb-figure-q">
      <span id="onb-figure-q">Show me as</span>
      {(['woman', 'man'] as const).map((f, i) => (
        <span key={f} className="onb-figure-opt">
          {i > 0 && <span aria-hidden="true">·</span>}
          <button type="button" className={value === f ? 'is-on' : ''} aria-pressed={value === f} onClick={() => onPick(f)}>
            {f === 'woman' ? 'Woman' : 'Man'}
          </button>
        </span>
      ))}
    </div>
  );
}

// ---------- step 3: your community ----------

function CommunityStep({ answers, set }: { answers: Answers; set: (p: Partial<Answers>) => void }) {
  const age = parseAge(answers.age);
  const adult = canJoinPeers(age);
  return (
    <>
      <div className="onb-peers">
        <PeerBars />
        <div className="onb-peers-copy">
          <p className="onb-peers-title">A private place in the bigger picture.</p>
          <p className="onb-peers-text">
            Compare {PEER_WINDOW_DAYS}-day averages within your age group, using the same measurement and source. In comparisons, your name, photo and individual
            readings are never shown to anyone else: others see only group figures.
          </p>
        </div>
      </div>
      <label className={`onb-consent${adult ? '' : ' is-off'}`}>
        {/* Unticked until the person ticks it: sharing in a comparison is their choice, never a default. */}
        <input
          type="checkbox"
          checked={adult && answers.peer}
          disabled={!adult}
          onChange={(e) => set({ peer: e.target.checked })}
          aria-labelledby="onb-consent-title"
          aria-describedby={`onb-consent-text${adult ? '' : ' onb-consent-why'}`}
        />
        <span className="onb-consent-copy">
          <span className="onb-consent-title" id="onb-consent-title">
            Include me in anonymous peer comparisons
          </span>
          <span className="onb-consent-text" id="onb-consent-text">
            Your {PEER_WINDOW_DAYS}-day averages count toward the group's median and quartiles. Results need at least {PEER_MIN_OTHERS} other participating people
            and {PEER_MIN_DAYS} recorded days per person. You can leave anytime in Profile.
          </span>
          {!adult && (
            <span className="onb-consent-why" id="onb-consent-why">
              {age === null ? 'Add your age on step 2 to take part.' : `Peer comparisons are for people aged ${PEER_MIN_AGE} and over.`}
            </span>
          )}
        </span>
      </label>
      <p className="onb-note">
        You see which quarter of this healthOS group your average sits in. Sitting higher in the group does not necessarily mean better health. No public profiles
        or global health scores.
      </p>
    </>
  );
}

// ---------- illustrations (drawn here: no artwork to load) ----------

/** "Your own portrait": a soft beige bust, the head resting on the shoulders. */
function BustArt() {
  return (
    <svg className="onb-bust" viewBox="0 0 100 100" aria-hidden="true">
      <defs>
        <radialGradient id="onb-bust-head" cx="38%" cy="32%" r="75%">
          <stop offset="0%" className="onb-bust-light" />
          <stop offset="100%" className="onb-bust-dark" />
        </radialGradient>
        <radialGradient id="onb-bust-body" cx="36%" cy="20%" r="95%">
          <stop offset="0%" className="onb-bust-light" />
          <stop offset="75%" className="onb-bust-dark" />
        </radialGradient>
      </defs>
      <path d="M12 100 C12 66 30 50 50 50 C70 50 88 66 88 100 Z" fill="url(#onb-bust-body)" />
      <ellipse cx="50" cy="29" rx="17" ry="23" fill="url(#onb-bust-head)" />
    </svg>
  );
}

/** "Digital human": the figure's artwork, the man's when the woman's file isn't there yet. */
function HumanArt({ variant }: { variant: FigureVariant }) {
  const [src, setSrc] = useState(variant);
  return <img className="onb-human" src={`/figures/digital-${src}.webp`} alt="" onError={() => src !== 'man' && setSrc('man')} />;
}

/** "Just the statistics": four sage bars, each at its own height. */
const STAT_BARS = [
  [42, 25],
  [73, 8],
  [58, 17],
  [94, 0],
];
function StatsArt() {
  return (
    <span className="onb-stat-bars">
      {STAT_BARS.map(([h, b], i) => (
        <span key={i} style={{ height: `${h}%`, bottom: `${b}%` }} />
      ))}
    </span>
  );
}

/** Step 3: a spread of readings, you the amber one in the middle. */
function PeerBars() {
  const heights = [22, 38, 74, 50, 92, 110, 96, 24, 50, 74, 50];
  return (
    <svg className="onb-peer-bars" viewBox="0 0 176 120" aria-hidden="true">
      <defs>
        <linearGradient id="onb-peer-sage" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" className="onb-bar-top" />
          <stop offset="100%" className="onb-bar-bottom" />
        </linearGradient>
        <linearGradient id="onb-peer-you" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" className="onb-you-top" />
          <stop offset="100%" className="onb-you-bottom" />
        </linearGradient>
      </defs>
      {heights.map((h, i) => (
        <rect key={i} x={i * 16 + 3} y={60 - h / 2} width={10} height={h} rx={5} fill={i === 5 ? 'url(#onb-peer-you)' : 'url(#onb-peer-sage)'} />
      ))}
    </svg>
  );
}
