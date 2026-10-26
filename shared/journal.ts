// The health journal: private check-ins, kept apart from everything else (server/journal.ts). Nothing that reads
// health data (the summary, the Family board, peer comparisons, McFly's tools, the admin screens) reads these.

/** How the day feels, 1 (rough) to 5 (great); null when the person didn't say. */
export type Mood = 1 | 2 | 3 | 4 | 5;

export const MOODS: { value: Mood; label: string }[] = [
  { value: 1, label: 'Rough' },
  { value: 2, label: 'Low' },
  { value: 3, label: 'Okay' },
  { value: 4, label: 'Good' },
  { value: 5, label: 'Great' },
];

export const JOURNAL_MAX_CHARS = 4000;

export type JournalEntry = {
  id: string;
  /** The person's own day (YYYY-MM-DD) and wall-clock time (HH:MM) of the check-in. */
  date: string;
  time: string;
  mood: Mood | null;
  text: string;
  createdAt: number;
  updatedAt: number;
};

/** GET /api/journal?days=: newest first. older: there are check-ins from before those days (missing from older servers). */
export type JournalData = { today: string; entries: JournalEntry[]; older?: boolean };

/** POST /api/journal and PATCH /api/journal/:id. date and time default to now in the person's time zone. */
export type JournalInput = { text: string; mood?: Mood | null; date?: string; time?: string };
