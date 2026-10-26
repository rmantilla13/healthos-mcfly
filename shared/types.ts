// API shapes shared by the server and the dashboard.

export type Point = { date: string; value: number };
export type Latest = { date: string; value: number; source: string };
export type RangeStatus = 'low' | 'normal' | 'high';

/** How far a reading is from the person's usual: within the band, beyond it, or beyond twice it. */
export type VitalLevel = 'normal' | 'unusual' | 'off';

export type Vital = {
  label: string;
  latest: Latest | null;
  /** Where the latest value sits against the previous 30 days. */
  status: RangeStatus | null;
  /** How far from usual, on the same band as `status` ('normal' exactly when status is). Missing from older servers. */
  level?: VitalLevel | null;
};

export type TimelineEvent = {
  id: string;
  kind: 'sleep' | 'nap' | 'mindful' | 'workout';
  title: string;
  start: string;
  end: string;
  detail?: string;
};

export type Insight = {
  id: string;
  icon: 'trend-up' | 'trend-down' | 'moon' | 'shield' | 'sun' | 'steps' | 'heart';
  text: string;
  date: string;
  /** Page the insight links to. */
  page: Page;
};

export type Page =
  | 'home'
  | 'family'
  | 'vitals'
  | 'sleep'
  | 'activity'
  | 'body'
  | 'nutrition'
  | 'journal'
  | 'labs'
  | 'cycle'
  | 'mcfly'
  | 'integrations'
  | 'profile'
  | 'settings'
  | 'welcome'
  | 'admin';

export type Summary = {
  date: string;
  today: string;
  latestDataDate: string | null;
  name: string;
  demo: boolean;
  stepGoal: number;
  /** spo2 is missing from servers older than the Blood oxygen callout. */
  vitals: { heart: Vital; breathing: Vital; temp: Vital; spo2?: Vital };
  /** Resting heart rate and respiratory rate over the last 30 days, for their Home cards. Missing from older servers. */
  restingHr?: { latest: Latest | null; series: Point[] };
  respRate?: { latest: Latest | null; series: Point[] };
  readiness:
    | { kind: 'recovery'; latest: Latest; average: number | null; zone: 'red' | 'yellow' | 'green' }
    | { kind: 'vo2max'; latest: Latest; previous: number | null }
    | null;
  spo2: { latest: Latest | null; series: Point[]; status: RangeStatus | null };
  hrv: { metric: 'hrv_rmssd' | 'hrv_sdnn'; latest: Latest | null; series: Point[]; baseline: number | null; status: 'optimal' | 'normal' | 'low' | null };
  sleep: { latest: Latest | null; series: Point[]; change: number | null };
  load:
    | { kind: 'strain'; latest: Latest; average: number | null; series: Point[] }
    | { kind: 'energy'; latest: Latest; average: number | null; series: Point[] }
    | null;
  activity: { latest: Latest | null; series: Point[] };
  timeline: { date: string; events: TimelineEvent[] };
  insights: Insight[];
  /** Missing from servers older than this field. */
  week?: WeekSummary;
  /** Gentle heads-ups about the latest readings. Absent when there are none, or from older servers. */
  flags?: Flag[];
};

export type Flag = { id: string; tone: 'caution' | 'info'; title: string; text: string; page: 'vitals' };

/** Monday through the summary's date, each figure next to the same weekdays of the week before. */
export type WeekSummary = {
  start: string;
  end: string;
  days: number;
  sleep: { avg: number | null; prev: number | null };
  steps: { avg: number | null; prev: number | null; goalDays: number; daysWithData: number };
  workouts: { count: number; minutes: number };
  hrv: { avg: number | null; prev: number | null };
  restingHr: { avg: number | null; prev: number | null };
  recovery: { avg: number | null; prev: number | null };
};

export type Workout = {
  id: string;
  source: string;
  sport: string;
  start: string;
  end: string;
  date: string;
  duration_min: number;
  energy_kcal: number | null;
  distance_m: number | null;
  avg_hr: number | null;
  max_hr: number | null;
  strain: number | null;
};

export type Trends = Record<string, Point[]>;

export type Units = 'metric' | 'imperial';

export type Settings = {
  name: string;
  stepGoal: number;
  units: Units;
  demo: 'auto' | 'on' | 'off';
  timeZone: string | null;
  /** "Sex for health calculations"; null until chosen. It picks the cycle tracking hint and, for a lab result printed without a range, the sex-specific typical range. */
  sex: Sex | null;
  /** Cycle tracking is on: the Cycle page, GET /api/cycle and McFly's cycle tool. Off by default. */
  cycleTracking: boolean;
  /** On the Family board: on unless turned off. Mutual: off, you neither see anyone nor are seen. */
  familySharing: boolean;
  /** Your cycle phase on your Family board tile. Off by default; only while cycle tracking and sharing are on. */
  shareCyclePhase: boolean;
  /** The one-time note that the Family board shows your daily status was dismissed. */
  familyNoticeSeen: boolean;
  /** Nutrition is on: the Nutrition page, GET /api/nutrition and McFly's nutrition tool. Off by default; only you turn it on. */
  nutrition: boolean;
  /** How much of your nutrition you see, McFly included, chosen when you turn it on. Null until chosen. */
  nutritionNumbers: NutritionNumbers | null;
  /** The app whose totals to use on a day two apps logged food. Null: whichever logged the most that day. */
  nutritionApp: string | null;
  /** Targets the person set for themselves, if any. healthOS never suggests one. */
  nutritionTargets: NutritionTargets;
  /** Cards this person doesn't want on Home, Sleep or Body (ids from shared/cards.ts). Layout only. */
  hiddenCards: string[];
  /** Optional cards (defaultHidden in shared/cards.ts) this person turned on. Layout only. Missing from older servers. */
  shownCards?: string[];
  // The rest come from onboarding ("Make this space yours") and Profile → Your profile & perspective. All are
  // missing from servers older than onboarding, so readers treat absent as the default.
  /** How Home and Body show you: your portrait, a digital human, or the numbers alone. Default 'portrait'. */
  perspective?: Perspective;
  /** How the person describes themselves. Never used for health calculations (that's `sex`). */
  gender?: Gender | null;
  /** Which digital human to show; null follows gender (woman or man), and otherwise the man until one is chosen. */
  figure?: FigureVariant | null;
  /** Age in whole years, kept current from the age given and the day it was given. Null until given. */
  age?: number | null;
  /** In anonymous peer comparisons (server/peers.ts). Off unless the person ticked it. */
  peerComparison?: boolean;
  /** The onboarding step a new account is on; null when done (and for every account that predates it). */
  onboarding?: OnboardingStep | null;
};

export type Perspective = 'portrait' | 'digital' | 'stats';
export type Gender = 'woman' | 'man' | 'nonbinary' | 'unsaid';
export type FigureVariant = 'woman' | 'man';
export type OnboardingStep = 1 | 2 | 3;

export type PhotoMeta = {
  version: number;
  width: number;
  height: number;
  /** Face box [x, y, w, h], 0–1 within the cut-out. */
  face: [number, number, number, number];
  shoulderY: number;
  /** Silhouette per row (100 rows, top to bottom): [left, right] edge, 0–1 of the width; [1, 0] where empty. */
  outline?: [number, number][];
  dots: { temp: [number, number]; breathing: [number, number]; heart: [number, number] };
};

export type Role = 'admin' | 'user';
export type SessionUser = { id: string; email: string; name: string; role: Role };

export type Status = {
  /** Running on Vercel: uploads that need the Mac (export import, photo processing) are off. */
  hosted: boolean;
  demo: boolean;
  user: SessionUser;
  settings: Settings;
  photo: PhotoMeta | null;
  apple: {
    lastImport: { records: number; days: number; workouts: number; firstDate: string | null; lastDate: string | null; importedAt: string } | null;
    /** Last push from the iOS companion app (POST /api/apple/ingest). */
    lastSync: { daily: number; workouts: number; events: number; syncedAt: string } | null;
    job: ImportJob;
    /** Whether this person has created an iPhone app token. */
    iphoneToken: boolean;
  };
  whoop: {
    configured: boolean;
    connected: boolean;
    redirectUri: string;
    syncing: boolean;
    lastSync: string | null;
    lastError: string | null;
  };
  /** A Fitbit (Google Takeout) export read in the browser and sent here (server/fitbit.ts). Missing from older servers. */
  fitbit?: { lastImport: FitbitImportSummary | null };
};

export type FitbitImportSummary = { days: number; firstDate: string | null; lastDate: string | null; metrics: string[]; importedAt: string };

/** POST /api/sync: the status, and whether a WHOOP sync was started by this call. */
export type SyncResult = Status & { whoopStarted: boolean };

export type ImportJob =
  | { state: 'idle' }
  | { state: 'uploading' | 'parsing'; bytesRead: number; totalBytes: number; records: number }
  | { state: 'done'; records: number; days: number }
  | { state: 'error'; error: string };

// ---------- auth & admin ----------

export type AuthMe = {
  mode: 'open' | 'required' | 'misconfigured';
  authenticated: boolean;
  /** No accounts exist yet: the first sign-in with the original password creates the admin. */
  setup: boolean;
  user: SessionUser | null;
};

export type AdminUser = {
  id: string;
  email: string;
  name: string;
  role: Role;
  status: 'active' | 'disabled';
  createdAt: number;
  lastLoginAt: number | null;
  data: { rows: number; days: number; first: string | null; last: string | null };
  apple: { lastImport: string | null; lastSync: string | null; iphoneToken: boolean };
  whoop: { connected: boolean; lastSync: string | null; lastError: string | null; historyComplete: boolean };
  photo: boolean;
  /** Ask McFly over the last 30 days: how many questions and tokens, never their content. voiceNotes30d: voice notes
   *  transcribed on the server's OpenAI key (missing from older servers). */
  mcfly: { questions30d: number; tokens30d: number; voiceNotes30d?: number };
  /** Cards hidden on their dashboard (layout only). */
  hiddenCards: string[];
  /** Optional cards they turned on (layout only). Missing from older servers. */
  shownCards?: string[];
};

export type AdminInvite = {
  id: string;
  kind: 'invite' | 'reset';
  email: string | null;
  role: Role;
  userId: string | null;
  createdAt: number;
  expiresAt: number;
  usedAt: number | null;
  usedBy: string | null;
  revokedAt: number | null;
};

export type PlatformSettings = {
  registration: 'invite' | 'closed';
  default_units: 'metric' | 'imperial';
  default_step_goal: string;
  invite_days: string;
  mcfly_model: string;
  mcfly_daily_limit: string;
  /** Defaults for a person's own OpenAI or Gemini key (server/admin.ts). Missing from older servers. */
  openai_model?: string;
  openai_vision_model?: string;
  openai_transcribe_model?: string;
  gemini_model?: string;
};

export type AdminOverview = {
  users: AdminUser[];
  invites: AdminInvite[];
  settings: PlatformSettings;
  whoop: { configured: boolean; redirectUri: string };
  mcfly: { configured: boolean };
};

// ---------- Ask McFly ----------

/**
 * GET /api/mcfly. On the shared key, limit and usedToday are the admin's daily limit; on a person's own key they're
 * its anti-abuse cap (limited false). provider, source and limited are missing from older servers, and while nothing
 * is set up.
 */
export type McflyStatus = {
  configured: boolean;
  limit: number;
  usedToday: number;
  provider?: 'anthropic' | 'openai' | 'gemini';
  source?: 'own' | 'shared';
  /** The shared daily limit applies (shown as "N questions left today"). */
  limited?: boolean;
};
export type McflyTurn = { role: 'user' | 'assistant'; content: string };

/**
 * A picture in one of McFly's answers. McFly only chooses what to show; the server reads the numbers from the
 * person's own data, in their units, so a chart can't carry a made-up value. Dates are YYYY-MM-DD (a week's
 * Monday, a month's 1st).
 */
export type McflyVisual =
  | {
      kind: 'trend' | 'bars';
      title: string;
      unit: string;
      resolution: 'day' | 'week' | 'month';
      points: Point[];
      /** The average of the daily values (weekly charts too), over `days` days. */
      mean: number | null;
      days?: number;
      /** A daily total whose today isn't over: left out of the average. */
      partialToday?: boolean;
      goal?: number;
    }
  | { kind: 'compare'; title: string; unit: string; periods: { label: string; from: string; to: string; mean: number | null; days: number; partialToday?: boolean }[] }
  | { kind: 'stats'; title: string; items: { label: string; value: number | null; unit: string; note: string; from?: string; to?: string }[] }
  | { kind: 'stages'; title: string; rows: { date: string; values: Record<string, number> }[] }
  | { kind: 'sports'; title: string; items: { sport: string; count: number; minutes: number }[] };

/** McFly's recap of the last completed Monday–Sunday. Never draws on cycle data. */
export type Digest = {
  weekStart: string;
  weekEnd: string;
  /** Light markdown, about 120 words at most. */
  text: string;
  generatedAt: string;
};

/**
 * GET /api/mcfly/digest. digest is null when there's nothing to show; with reason 'limit' it's the last
 * digest written (an older week), if any.
 */
export type DigestReply = { configured: boolean; digest: Digest | null; reason?: 'not_configured' | 'off' | 'limit' | 'no_data' };

// ---------- Day view (GET /api/day) ----------

export type DayMetric = 'steps' | 'active_energy' | 'heart_rate';

/** One metric's day, by local hour (index 0 = midnight to 1 AM). Every array has 24 entries. */
export type DaySeries = {
  /** A sum per hour (steps, active energy) or an average (heart rate); null where nothing was recorded. */
  hours: (number | null)[];
  /**
   * The median for each hour over the previous 30 days. For summed metrics it's the running total by the
   * end of that hour ("typical by now"); for heart rate it's the typical hourly average. null where fewer
   * than 3 days qualify.
   */
  typical: (number | null)[];
  /** Heart rate only: the lowest and highest reading in each hour. */
  min?: (number | null)[];
  max?: (number | null)[];
  /**
   * Steps only: the day's count as Home and the charts show it, and where it came from. When it's WHOOP's
   * (its API has no hours), it's larger than the hours add up to: those come from the iPhone or Watch.
   */
  total?: { value: number; source: string };
};

export type DayData = {
  /** The day shown. */
  date: string;
  /** The person's today, in their time zone. */
  today: string;
  /** The last hour (0–23) with any reading on `date`, or null when the day has none. */
  asOf: number | null;
  /** Only metrics the person has hourly data for at all; an empty object means "no Day view". */
  metrics: Partial<Record<DayMetric, DaySeries>>;
};

// ---------- Sleep timing (GET /api/sleep) ----------

/** One night: the longest sleep that ended on its wake date, from any source. Naps aren't nights. */
export type SleepNight = {
  /** The wake date. */
  date: string;
  /** ISO timestamps with the local offset they were recorded in. */
  bed: string;
  wake: string;
  /** Minutes after 18:00 local the evening before the wake date (23:30 → 330, 01:10 → 430). */
  bedMin: number;
  /** Minutes after midnight local of the wake date. */
  wakeMin: number;
  /** The middle of the night, minutes after 18:00 like bedMin. */
  midMin: number;
  /** The day's sleep_hours as Home shows it, else the event's length. */
  hours: number | null;
  /** The wake date is a Saturday or Sunday. */
  weekend: boolean;
};

export type SleepTiming = {
  /** Oldest first. */
  nights: SleepNight[];
  stats: {
    nights: number;
    avgBedMin: number | null;
    avgWakeMin: number | null;
    /** Standard deviations in minutes; need 7 nights. */
    bedSd: number | null;
    wakeSd: number | null;
    /** Average midpoint (minutes after 18:00) on weekday and weekend wake dates; need 2 nights each. */
    midWeekday: number | null;
    midWeekend: number | null;
    /** midWeekend − midWeekday, minutes. */
    socialJetlag: number | null;
    /** Hours: the median of the last 60 nights, held within 7–9; needs 14 nights. */
    need: number | null;
    /** Hours short of `need`, added up over the nights of the last 7 days. */
    debt: number | null;
    /** How many nights `debt` adds up. */
    debtNights: number;
  };
};

// ---------- One night (GET /api/sleep/night?date=) ----------

/** A stretch of one sleep stage, as the device recorded it. `asleep`: asleep with no stage (older watches,
 * phones); `in_bed`: in bed, not asleep yet (or again). */
export type SleepStage = 'awake' | 'rem' | 'light' | 'deep' | 'asleep' | 'in_bed';
export type SleepSegment = {
  /** ISO timestamps with the local offset they were recorded in. */
  start: string;
  end: string;
  stage: SleepStage;
};

/** The night that ended on `date` (the wake date), for the Sleep page. */
export type SleepNightDetail = {
  date: string;
  today: string;
  /** The device the night's figures come from. 'fitbit' is from servers since the Fitbit export import. */
  source: 'apple' | 'whoop' | 'fitbit' | null;
  /** First and last moment asleep (Apple), or the sleep record's start and end (WHOOP). */
  fellAsleep: string | null;
  wokeUp: string | null;
  asleepHours: number | null;
  inBedHours: number | null;
  /** Hours in each stage, from the same device as the stages chart. */
  stages: { awake: number; rem: number; light: number; deep: number } | null;
  /** WHOOP's sleep performance, else asleep ÷ in bed (labelled as efficiency); 0–100. */
  score: { kind: 'performance' | 'efficiency'; value: number } | null;
  // The next three are missing from servers older than the Sleep page's three cards.
  /** WHOOP's sleep performance for the night (the sleep you got against the sleep you needed), 0–100; null without one. */
  performance?: number | null;
  /** The night's sleep efficiency, 0–100: the device's own (WHOOP, Fitbit) when it gives one, else time asleep ÷ time
   * in bed from that one device; null without both. */
  efficiency?: number | null;
  /** The latest night with any sleep recorded, up to today, from any of the person's sources; null when there's none. */
  lastNight?: string | null;
  /** Stage by stage through the night, oldest first. Only when the iPhone app sent them (Apple Watch nights);
   * WHOOP's API gives totals only. */
  segments: SleepSegment[];
  /** Minutes from getting into bed to falling asleep, when the segments include time in bed. */
  latencyMin: number | null;
  /** The middle of the longest stretch of deep sleep. */
  deepPeak: string | null;
  /** Plain sentences about this night against the person's own recent nights. */
  insights: { id: string; icon: 'moon' | 'trend-up' | 'trend-down' | 'shield' | 'sun'; text: string }[];
};

// ---------- Patterns (GET /api/patterns) ----------

/** Something that tends to go together in a person's own history. Correlation only, never cause. */
export type Pattern = {
  id: string;
  icon: 'moon' | 'heart' | 'steps' | 'sun' | 'spark' | 'trend-up' | 'trend-down';
  /** One sentence. */
  text: string;
  /** What it rests on: how many days in each group, over what window. */
  detail: string;
  /** Days in the smaller group. */
  n: number;
  /** Signed difference, in `unit`: the days that meet the condition less the days that don't. */
  effect: number;
  /** 'min' | 'ms' | '%' | 'bpm' | 'points' */
  unit: string;
  page: 'vitals' | 'sleep' | 'activity' | 'body';
};

/** At most six, strongest first, over the 180 days to the latest data date. */
export type Patterns = { start: string; end: string; patterns: Pattern[] };

// ---------- Cycle tracking (GET /api/cycle) ----------
// Reproductive-health data: opt-in per person, never part of /api/summary or the admin view.

export type Sex = 'female' | 'male' | 'unspecified';
export type Flow = 'none' | 'unspecified' | 'light' | 'medium' | 'heavy';
export type OvulationTest = 'negative' | 'lh_surge' | 'estrogen_surge' | 'indeterminate';
export type CervicalMucus = 'dry' | 'sticky' | 'creamy' | 'watery' | 'egg_white';
export type SexualActivity = 'protected' | 'unprotected' | 'unspecified';
/** Apple Health's cycle symptoms, so the iPhone app can sync the same set. */
export type Symptom =
  | 'cramps'
  | 'bloating'
  | 'breast_tenderness'
  | 'headache'
  | 'acne'
  | 'fatigue'
  | 'mood_changes'
  | 'back_pain'
  | 'nausea'
  | 'appetite_changes'
  | 'sleep_changes'
  | 'hot_flashes';
/** Why a day's temperature may be off. That morning's readings, from every device, are left out of the analysis. */
export type TempDisturbance = 'sick' | 'alcohol' | 'sleep' | 'travel' | 'other';

/** What was logged on one day. A field that's absent wasn't logged. */
export type CycleFields = {
  flow?: Flow;
  /** Marked as the first day of a period (Apple Health's cycle start, or by hand). */
  periodStart?: boolean;
  /** Bleeding between periods. */
  spotting?: boolean;
  ovulationTest?: OvulationTest;
  mucus?: CervicalMucus;
  /** Basal body temperature in °C. */
  bbt?: number;
  sexualActivity?: SexualActivity;
  /** Sorted, no repeats. */
  symptoms?: Symptom[];
  tempDisturbed?: TempDisturbance;
};

export type CycleDay = CycleFields & { date: string };

/** A day as shown: entries made by hand override Apple Health's, field by field. */
export type CycleLogDay = CycleDay & { apple?: CycleFields; manual?: CycleFields };

/** Where a temperature came from: a thermometer (logged or Apple Health), Apple Watch's sleeping wrist temperature, WHOOP's skin temperature. */
export type TempSource = 'bbt' | 'wrist' | 'skin';

export type CycleEstimate = {
  /** The most likely first day of the next period, and the range it falls in about four times in five. */
  nextPeriod: { date: string; earliest: string; latest: string };
  /** The most likely ovulation day. */
  ovulation: string;
  /** The days with a real chance of conception (see `fertility`), first to last. */
  fertile: { start: string; end: string };
  /** calendar: from past cycle lengths; lh_test or bbt: from this cycle's ovulation test or temperature rise (bbt covers wearables too). */
  basis: 'calendar' | 'lh_test' | 'bbt';
  /** How many of this person's own cycles it rests on. Below 2, typical cycles fill in. */
  cycles: number;
  /** How settled it is: low on typical cycles or very variable ones, high once a temperature rise confirms ovulation. */
  confidence?: 'low' | 'medium' | 'high';
  /** With basis bbt: the device whose temperature rise it follows. */
  tempSource?: TempSource;
};

/** One day's chance of conception, as an estimate: relative to the most fertile day (1). Only days that matter are listed. */
export type FertilityDay = { date: string; chance: number; level: 'medium' | 'high' | 'peak'; basis: 'estimate' | 'logged' };

/** One night's or morning's temperature as the analysis sees it. */
export type CycleTemperature = {
  date: string;
  source: TempSource;
  /** °C as measured. */
  value: number;
  /** °C above or below this person's own level on that device (a rolling median), so devices can share a chart. */
  deviation: number;
  /** Left out: the day was marked as disturbed, or the reading stands far apart from its neighbours. */
  excluded?: 'disturbed' | 'outlier';
};

/** One cycle, from the first day of a period to the day before the next. */
export type CycleHistory = {
  start: string;
  /** null for the current cycle. */
  end: string | null;
  /** Length in days; for the current cycle, days so far. */
  days: number;
  periodDays: number | null;
  ovulation: { date: string; basis: 'bbt' | 'lh_test'; tempSource?: TempSource } | null;
  /**
   * confirmed: a sustained temperature rise; lh_test: a positive test, no rise to confirm it; waiting: the current
   * cycle, nothing yet; not_found: temperatures covered the cycle and showed no rise; no_data: too few to tell.
   */
  status: 'confirmed' | 'lh_test' | 'waiting' | 'not_found' | 'no_data';
  /** Period start to ovulation, and ovulation to the next period: only once ovulation was found. */
  follicularDays: number | null;
  lutealDays: number | null;
  /** The device the cycle's temperature analysis used, with what it found. */
  temperature: {
    source: TempSource;
    readings: number;
    /** °C deviation: the level the rise had to clear, and how far the readings after it sat above the ones before. */
    coverline: number | null;
    rise: number | null;
  } | null;
  symptoms: number;
};

/** Patterns from this person's own cycles. Cycle-derived, so only ever inside /api/cycle. */
export type CycleInsights = {
  /** Resting heart rate, HRV and temperature after ovulation against before it, over cycles where ovulation was found. */
  body: { metric: 'resting_hr' | 'hrv' | 'temperature'; follicular: number; luteal: number; unit: 'bpm' | 'ms' | '°C'; cycles: number }[];
  /** Symptoms logged in two or more cycles, with the phase they mostly fall in (null when they're spread out). */
  symptoms: { symptom: Symptom; days: number; cycles: number; phase: CyclePhase['name'] | null }[];
  /** Recent cycles outside the usual ranges (FIGO 2018), to mention to a clinician if they continue. */
  deviations: {
    kind: 'frequent' | 'infrequent' | 'irregular' | 'prolonged' | 'spotting';
    /** Cycles (or periods) it applies to, of how many recent ones. */
    count: number;
    of: number;
    /** irregular only: longest less shortest, in days. */
    spread?: number;
  }[];
};

export type CycleData = {
  enabled: boolean;
  today: string;
  /** Logged days in the window asked for, oldest first. */
  days: CycleLogDay[];
  /** Detected periods over all history, oldest first. */
  periods: { start: string; end: string; days: number }[];
  /** Lengths between consecutive period starts, oldest first. */
  cycles: { start: string; days: number }[];
  /** Typical values over recent cycles. */
  stats: {
    cycleDays: number | null;
    periodDays: number | null;
    shortest: number | null;
    longest: number | null;
    /** Longest less shortest over recent cycles; regular when it's 9 days or less. */
    variation?: number | null;
    regular?: boolean | null;
    follicularDays?: number | null;
    lutealDays?: number | null;
  };
  current: { start: string; day: number } | null;
  /** Estimates from the person's own history. null until two complete cycles are logged, or when the latest period is long past. */
  estimate: CycleEstimate | null;
  /** Why there's no estimate. */
  noEstimate: 'cycles' | 'stale' | null;
  /**
   * With fewer than two complete cycles: the same estimate, leaning on typical cycles. Kept apart from `estimate`
   * so clients that predate it keep showing "not yet" rather than an estimate from "0 cycles".
   */
  earlyEstimate?: CycleEstimate | null;
  /** Ovulation inferred after the fact, per cycle: a temperature rise (any device), or the day after an LH surge. */
  ovulations: { date: string; basis: 'bbt' | 'lh_test' }[];
  /** Where today falls in the current cycle. null with no current cycle; missing from older servers. */
  phase?: CyclePhase | null;
  /** Every cycle, oldest first. */
  history?: CycleHistory[];
  /** Temperatures in the window asked for, oldest first. */
  temperatures?: CycleTemperature[];
  /** The current cycle's fertile days, estimated, oldest first. */
  fertility?: FertilityDay[];
  insights?: CycleInsights;
};

export type CyclePhase = {
  name: 'menstrual' | 'follicular' | 'ovulatory' | 'luteal';
  /** Cycle day, 1 on the first day of the period. */
  day: number;
  /** Days to the estimated next period; null without an estimate. */
  nextPeriodIn: number | null;
  /** logged: from this cycle's own records (bleeding, an LH surge, a temperature rise); estimate: from past cycles. */
  basis: 'logged' | 'estimate';
};

// ---------- Family board (GET /api/family) ----------

/** How someone is doing against their own last 30 days, never against each other. */
export type FamilyStatus = 'good' | 'off' | 'check' | 'quiet' | 'learning';
export type FamilyReason = 'recovery' | 'hrv' | 'resting_hr' | 'sleep';
export type FamilyDevice = 'whoop' | 'watch' | 'iphone';
/** One word for a shared cycle phase. Absent near the next period, so it can never imply "late". */
export type FamilyCyclePhase = 'period' | 'follicular' | 'luteal';

/** One person's tile: all another member learns about them. */
export type FamilyMember = {
  id: string;
  name: string;
  isYou: boolean;
  demo: boolean;
  /** Their today, in their own time zone. */
  today: string;
  /** Photo version for /api/family/:id/avatar.png, null without one. */
  avatar: number | null;
  devices: FamilyDevice[];
  latestDataDate: string | null;
  /** With status quiet: the newest data (or, with fresh phone data, the newest watch or WHOOP data). */
  quietSince: string | null;
  /** null for phone-only people: nothing to compare. */
  status: FamilyStatus | null;
  reasons: FamilyReason[];
  sleep: { hours: number; date: string; usual: number | null; inBed: boolean } | null;
  readiness:
    | { kind: 'recovery'; value: number; date: string; usual: number | null }
    | { kind: 'hrv'; metric: 'hrv_rmssd' | 'hrv_sdnn'; value: number; date: string; usual: number | null }
    | null;
  /** Against their usual (from the same device); present once there's a week of history to compare with. */
  restingHr: { status: RangeStatus; date: string; value: number; usual: number | null } | null;
  /** Today's steps. asOfHour and usualByNow only when the phone or Watch counted them hour by hour. */
  steps: { value: number; source: 'apple' | 'whoop'; asOfHour: number | null; usualByNow: number | null } | null;
  cyclePhase?: FamilyCyclePhase;
  /** The last 30 days, oldest first, for the board's small charts and the person's page. */
  history: FamilyHistory;
};

/** Each metric as the person's own dashboard shows it. Nights the phone logged as time in bed are left out when
 * a watch or WHOOP measured the others (phone-only people get their time in bed, marked as such). */
export type FamilyHistory = {
  sleep: { inBed: boolean; points: Point[] };
  readiness: { kind: 'recovery' | 'hrv_rmssd' | 'hrv_sdnn'; points: Point[] } | null;
  steps: Point[];
  restingHr: Point[];
  /** WHOOP's day strain (0–21), else Apple's active energy in kcal. */
  load: { kind: 'strain' | 'energy'; points: Point[] } | null;
};

export type FamilyBoard = { sharing: false } | { sharing: true; today: string; members: FamilyMember[] };

// ---------- nutrition ----------

/** Daily totals from the apps people log food in. Energy in kcal, masses in g except sodium (mg), alcohol in drinks. */
export type Nutrient = 'energy_kcal' | 'protein_g' | 'carbs_g' | 'fat_g' | 'fiber_g' | 'sugar_g' | 'sat_fat_g' | 'sodium_mg' | 'alcohol_drinks';

/** What a person chose to see: everything, everything but calories, or no amounts at all. */
export type NutritionNumbers = 'all' | 'no_energy' | 'none';

/** Personal daily targets, each set (or not) by the person: shown as a plain line, never scored. */
export type NutritionTargets = { energy_kcal: number | null; protein_g: number | null; water_ml: number | null };

/** One day's totals by app, as the iPhone app sends them. A day with no apps clears that day. */
export type NutritionDayIn = { date: string; apps: { app: string; values: Partial<Record<Nutrient, number>> }[] };

/** One day in the Nutrition view: the app used that day and its totals, as the person's setting allows. */
export type NutritionDay = {
  date: string;
  app: string;
  /** Never energy in 'no_energy'; empty in 'none'. */
  values: Partial<Record<Nutrient, number>>;
  /** Other apps that logged food that day. They're shown, never added in: apps copy each other's logs. */
  otherApps: string[];
};

export type NutritionData = {
  enabled: boolean;
  numbers: NutritionNumbers | null;
  today: string;
  start: string;
  end: string;
  /** Apps with data in the window, most days first. */
  apps: string[];
  /** The app chosen for days two apps logged, or null for automatic. */
  app: string | null;
  /** Days with something logged, oldest first. */
  days: NutritionDay[];
  /** The person's own targets, as far as their setting shows them (no energy target in 'no_energy', none in 'none'). */
  targets: Partial<Record<'energy_kcal' | 'protein_g' | 'water_ml', number>>;
  /** Water (mL) and caffeine (mg) by day over the window, from any app, as the daily metrics already hold them. Empty in 'none'. */
  hydration: { water: Point[]; caffeine: Point[] };
  /** Food patterns over the last 180 days (caffeine and sleep, drinks and next-morning HRV), only when asked for. Empty in 'none'. */
  insights: Pattern[];
};

// ---------- the food log (entries made in healthOS) ----------

/** How an entry was made: typed numbers, a database search, a barcode, or McFly's estimate from a photo or words. */
export type FoodMethod = 'quick' | 'search' | 'barcode' | 'estimate';

/** An entry's amounts: the day's nutrients plus water (mL), which joins the Hydration totals instead. */
export type FoodValues = Partial<Record<Nutrient | 'water_ml', number>>;

/** One food or drink logged in healthOS, on the web or the iPhone. */
export type FoodEntry = {
  id: string;
  date: string;
  /** Local time, HH:MM. */
  time: string;
  name: string;
  /** What one portion is ("1 cup (245 g)"); quantity is how many. */
  portion: string;
  quantity: number;
  /** The whole entry (one portion × quantity), as the person's setting allows: never energy in 'no_energy', empty in 'none'. */
  values: FoodValues;
  method: FoodMethod;
  /** 'fdc:<id>' or 'off:<barcode>' when it came from a food database. */
  ref: string | null;
  /** Bumped on every edit, so the iPhone knows when its copy in Apple Health is out of date. */
  version: number;
  /** Where it was made; the iPhone writes the ones made there to Apple Health. */
  origin: 'web' | 'iphone';
};

/** GET /api/nutrition/log: the person's entries over the last few days, and an estimate waiting for review. */
export type FoodLog = {
  enabled: boolean;
  numbers: NutritionNumbers | null;
  today: string;
  start: string;
  end: string;
  /** Saved entries, oldest first. */
  entries: FoodEntry[];
  /** McFly's latest estimate, not counted until saved. Kept for a day, then dropped. */
  drafts: FoodEntry[];
  /** Which estimate the drafts are: send it with /log/save or /log/discard. Null when there are none. */
  draftBatch: string | null;
  /**
   * What this person can do here: McFly estimates (their own OpenAI or Claude key, else the shared Claude key with a
   * daily limit above 0) and USDA search (needs its key). Newer servers add who reads an estimate (shared/ai.ts
   * AiProvider and AiSource, null when nobody can) and whether voice notes work (an OpenAI key).
   */
  can: { estimate: boolean; usda: boolean; estimateProvider?: 'anthropic' | 'openai' | 'gemini' | null; estimateSource?: 'own' | 'shared' | null; voice?: boolean };
};

/** One portion of a database food, with its amounts for one of it, as the person's setting allows. */
export type FoodPortion = { label: string; values: FoodValues };

/** A database food from a search or a barcode. Save it with its ref and the index of the portion chosen (portionIndex). */
export type FoodResult = {
  ref: string;
  name: string;
  brand: string | null;
  source: 'usda' | 'off';
  portions: FoodPortion[];
};

/** POST /api/nutrition/foods/search and /barcode. notes say which database couldn't be reached, if any. */
export type FoodSearch = { results: FoodResult[]; notes: string[] };

/** POST /api/nutrition/estimate: draft entries to review, and McFly's note on what it assumed. */
export type FoodEstimate = { drafts: FoodEntry[]; batch: string; note: string };
