// API shapes shared by the server and the dashboard.

export type Point = { date: string; value: number };
export type Latest = { date: string; value: number; source: string };
export type RangeStatus = 'low' | 'normal' | 'high';

export type Vital = {
  label: string;
  latest: Latest | null;
  /** Where the latest value sits against the previous 30 days. */
  status: RangeStatus | null;
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

export type Page = 'home' | 'vitals' | 'sleep' | 'activity' | 'body' | 'mcfly' | 'integrations' | 'settings' | 'admin';

export type Summary = {
  date: string;
  today: string;
  latestDataDate: string | null;
  name: string;
  demo: boolean;
  stepGoal: number;
  vitals: { heart: Vital; breathing: Vital; temp: Vital };
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
};

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

export type Settings = { name: string; stepGoal: number; units: Units; demo: 'auto' | 'on' | 'off'; timeZone: string | null };

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
};

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
  /** Ask McFly over the last 30 days: how many questions and tokens, never their content. */
  mcfly: { questions30d: number; tokens30d: number };
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
};

export type AdminOverview = {
  users: AdminUser[];
  invites: AdminInvite[];
  settings: PlatformSettings;
  whoop: { configured: boolean; redirectUri: string };
  mcfly: { configured: boolean };
};

// ---------- Ask McFly ----------

export type McflyStatus = { configured: boolean; limit: number; usedToday: number };
export type McflyTurn = { role: 'user' | 'assistant'; content: string };

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
