// Line icons on a 24-unit grid, stroked in the text colour. Each is one path, or a few drawn together (a list), so
// shapes that Lucide draws as circles or several strokes keep their look without the dependency. The names are a
// real union (IconName), so a typo is a type error rather than an empty square.
const PERSON_STANDING = ['M13 5a1 1 0 1 1-2 0 1 1 0 0 1 2 0z', 'm9 20 3-6 3 6', 'm6 8 6 2 6-2', 'M12 10v4'] as const;
const UTENSILS = ['M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2', 'M7 2v20', 'M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3zm0 0v7'] as const;
const FILE_TEXT = ['M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z', 'M14 2v4a2 2 0 0 0 2 2h4', 'M10 9H8', 'M16 13H8', 'M16 17H8'] as const;
const SLIDERS = ['M20 7h-9', 'M14 17H5', 'M20 17a3 3 0 1 1-6 0 3 3 0 0 1 6 0z', 'M10 7a3 3 0 1 1-6 0 3 3 0 0 1 6 0z'] as const;

// Some shapes go by two names: the page they stand for, and Lucide's own (body / person-standing).
const PATHS = {
  home: 'M3.5 10.5 12 4l8.5 6.5V20a1 1 0 0 1-1 1h-5v-6h-5v6h-5a1 1 0 0 1-1-1z',
  family: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18.5 14.2a6.5 6.5 0 0 1 3 5.8',
  vitals: 'M3 12h4l2.5-6 4 12 2.5-6H21',
  // A standing figure (Lucide person-standing): Body in the sidebar, Profile in the account menu.
  body: PERSON_STANDING,
  'person-standing': PERSON_STANDING,
  // The head-and-shoulders bust that Body used before.
  user: 'M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4.5 21a7.5 7.5 0 0 1 15 0',
  users: ['M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2', 'M13 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0z', 'M22 21v-2a4 4 0 0 0-3-3.87', 'M16 3.13a4 4 0 0 1 0 7.75'],
  sleep: 'M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z',
  activity: 'M13 3 5 13h6l-1 8 8-10h-6z',
  integrations: 'M9 7V3M15 7V3M7 7h10v4a5 5 0 0 1-10 0zM12 16v5',
  settings:
    'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
  // Two sliders (Lucide settings-2).
  sliders: SLIDERS,
  'settings-2': SLIDERS,
  'arrow-up-right': 'M7 17 17 7M8 7h9v9',
  'chevron-left': 'm15 18-6-6 6-6',
  'chevron-right': 'm9 18 6-6-6-6',
  'chevron-up': 'm18 15-6-6-6 6',
  'chevron-down': 'm6 9 6 6 6-6',
  'trend-up': 'm3 17 6-6 4 4 8-8M15 7h6v6',
  'trend-down': 'm3 7 6 6 4-4 8 8M15 17h6v-6',
  moon: 'M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z',
  shield: 'M12 3 5 6v5c0 4.5 3 8.5 7 10 4-1.5 7-5.5 7-10V6zM9 12l2 2 4-4',
  sun: 'M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4',
  steps: 'M8 14c-1.7 0-3-1.8-3-4.5S6 4 8 4s3 2.5 3 5.5-1.3 4.5-3 4.5zM16 20c-1.7 0-3-1.8-3-4.5S14 10 16 10s3 2.5 3 5.5-1.3 4.5-3 4.5zM6 17h4M14 7h4',
  heart: 'M19.5 12.6 12 20l-7.5-7.4A4.8 4.8 0 0 1 12 6.5a4.8 4.8 0 0 1 7.5 6.1z',
  cycle: 'M12 3.5c3.2 4.2 6 7.4 6 10.6a6 6 0 0 1-12 0c0-3.2 2.8-6.4 6-10.6z',
  labs: 'M9 3h6M10 3v6L4.6 18.4A1.8 1.8 0 0 0 6.2 21h11.6a1.8 1.8 0 0 0 1.6-2.6L14 9V3M7.5 15h9',
  // Blood records: a report with a heart on it, so it isn't Cycle's drop or Journal's page of lines.
  records: ['M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z', 'M14 2v4a2 2 0 0 0 2 2h4', 'M12 18.2 9.7 16a1.6 1.6 0 0 1 2.3-2.2 1.6 1.6 0 0 1 2.3 2.2z'],
  'test-tube': ['M14.5 2v17.5a2.5 2.5 0 0 1-5 0V2', 'M8.5 2h7', 'M14.5 16h-5'],
  // A page of lines (Lucide file-text): Journal.
  journal: FILE_TEXT,
  'file-text': FILE_TEXT,
  file: ['M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z', 'M14 2v4a2 2 0 0 0 2 2h4'],
  search: 'M10.5 18a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15zM21 21l-5.2-5.2',
  // Fork and knife (Lucide utensils).
  nutrition: UTENSILS,
  utensils: UTENSILS,
  // The apple that Nutrition used before.
  apple: 'M12 7.5c-1.6-1.2-5.6-1.4-6.4 3-.6 3.6 1.8 9.5 4.4 9.5 1 0 1.3-.5 2-.5s1 .5 2 .5c2.6 0 5-5.9 4.4-9.5-.8-4.4-4.8-4.2-6.4-3zM12 7.5C12 5 13.2 3.5 15.5 3',
  upload: 'M12 15V3M7 8l5-5 5 5M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4',
  download: 'M12 3v12M7 10l5 5 5-5M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4',
  refresh: 'M21 12a9 9 0 1 1-2.6-6.4L21 8M21 3v5h-5',
  check: 'm5 12 5 5L20 7',
  plus: 'M5 12h14M12 5v14',
  minus: 'M5 12h14',
  x: 'M18 6 6 18M6 6l12 12',
  'log-out': ['M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4', 'm16 17 5-5-5-5', 'M21 12H9'],
  'message-square-text': ['M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z', 'M13 8H7', 'M17 12H7'],
  camera: ['M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3z', 'M15 13a3 3 0 1 1-6 0 3 3 0 0 1 6 0z'],
  image: ['M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z', 'M11 9a2 2 0 1 1-4 0 2 2 0 0 1 4 0z', 'm21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21'],
  mic: ['M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z', 'M19 10v2a7 7 0 0 1-14 0v-2', 'M12 19v3'],
  calendar: ['M8 2v4', 'M16 2v4', 'M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z', 'M3 10h18'],
  'more-horizontal': ['M13 12a1 1 0 1 1-2 0 1 1 0 0 1 2 0z', 'M20 12a1 1 0 1 1-2 0 1 1 0 0 1 2 0z', 'M6 12a1 1 0 1 1-2 0 1 1 0 0 1 2 0z'],
  spark: 'M11 3.5 12.9 9l5.6 2-5.6 2L11 18.5 9.1 13l-5.6-2 5.6-2zM18.5 15.5l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z',
  alert: 'M12 9v4M12 17h.01M10.3 3.9 2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
  table: 'M3 5h18v14H3zM3 10h18M3 15h18M9 5v14',
  chart: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  copy: 'M9 9h11v11H9zM5 15H4V4h11v1',
  link: 'M10 14a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1M14 10a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1',
} as const satisfies Record<string, string | readonly string[]>;

export type IconName = keyof typeof PATHS;

export function Icon({ name, size = 18, strokeWidth = 1.5 }: { name: IconName; size?: number; strokeWidth?: number }) {
  const d: string | readonly string[] = PATHS[name];
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="icon"
    >
      {typeof d === 'string' ? <path d={d} /> : d.map((p) => <path key={p} d={p} />)}
    </svg>
  );
}
