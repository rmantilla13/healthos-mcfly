// The shell's pages: each one's title (the header's h1), and the main navigation in the sidebar's order, with Family
// and Cycle only for people who have them. Route ids never change ('labs' is Blood records; 'settings' opens Profile).
import type { Page } from '../../../shared/types.ts';
import type { IconName } from '../Icon.tsx';

/** The header's title for each page. The subtitle is the same on every page (SUBTITLE); Home greets you instead. */
export const PAGE_META: Record<Page, { title: string }> = {
  home: { title: 'Home' },
  family: { title: 'Family' },
  vitals: { title: 'Vitals' },
  sleep: { title: 'Sleep' },
  activity: { title: 'Body' },
  body: { title: 'Body' },
  nutrition: { title: 'Nutrition' },
  journal: { title: 'Journal' },
  labs: { title: 'Blood records' },
  cycle: { title: 'Cycle' },
  mcfly: { title: 'Ask McFly' },
  integrations: { title: 'Integrations' },
  profile: { title: 'Profile' },
  settings: { title: 'Profile' },
  welcome: { title: 'Welcome' },
  admin: { title: 'Admin' },
};

export const SUBTITLE = 'Your health, in perspective.';

export type NavItem = { page: Page; label: string; icon: IconName };

const NAV: NavItem[] = [
  { page: 'home', label: 'Home', icon: 'home' },
  { page: 'vitals', label: 'Vitals', icon: 'vitals' },
  { page: 'body', label: 'Body', icon: 'body' },
  { page: 'nutrition', label: 'Nutrition', icon: 'nutrition' },
  { page: 'journal', label: 'Journal', icon: 'journal' },
  { page: 'sleep', label: 'Sleep', icon: 'sleep' },
  { page: 'labs', label: 'Blood records', icon: 'records' },
];

/** After Home, for signed-in people who share with family (everyone, unless they turned it off). */
const FAMILY_NAV: NavItem = { page: 'family', label: 'Family', icon: 'family' };
/** After Body, only for people who turned cycle tracking on. */
const CYCLE_NAV: NavItem = { page: 'cycle', label: 'Cycle', icon: 'cycle' };

/** The main navigation for this person: Home, [Family], Vitals, Body, [Cycle], Nutrition, Journal, Sleep, Blood records. */
export function mainNav({ family, cycle }: { family: boolean; cycle: boolean }): NavItem[] {
  return NAV.flatMap((n) => (n.page === 'home' && family ? [n, FAMILY_NAV] : n.page === 'body' && cycle ? [n, CYCLE_NAV] : [n]));
}

/** On a phone, the tab bar holds these four; the rest are under More. */
export const TAB_PAGES: Page[] = ['home', 'vitals', 'body', 'nutrition'];
