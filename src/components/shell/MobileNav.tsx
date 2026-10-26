// On a phone (≤820px) the sidebar gives way to these: a slim top bar (the mark, the page's name, Search and your
// avatar) and a tab bar at the bottom (Home, Vitals, Body, Nutrition, and More for the rest). Hidden on a computer.
import type { Page } from '../../../shared/types.ts';
import { href } from '../../lib.ts';
import { Icon } from '../Icon.tsx';
import { openSearch } from '../Search.tsx';
import { type AccountProps, AccountAvatar } from './AccountMenu.tsx';
import { Logo } from './Logo.tsx';
import { MenuButton, MenuEyebrow } from './Menu.tsx';
import { type NavItem, PAGE_META, TAB_PAGES } from './nav.ts';

export function MobileBar({ page, account }: { page: Page; account: AccountProps }) {
  return (
    <header className="mobile-bar">
      <a className="mobile-brand" href={href('home')} aria-label="healthOS, Home">
        <Logo size={26} />
      </a>
      <span className="mobile-title">{PAGE_META[page].title}</span>
      <button type="button" className="icon-btn" onClick={openSearch} aria-label="Search" aria-haspopup="dialog">
        <Icon name="search" size={16} />
      </button>
      <AccountAvatar id="phone" {...account} />
    </header>
  );
}

/** The rest of the pages, under More: what the tab bar has no room for, then Ask McFly, Profile and Integrations. */
const MORE_EXTRA: NavItem[] = [
  { page: 'mcfly', label: 'Ask McFly', icon: 'message-square-text' },
  { page: 'profile', label: 'Profile', icon: 'person-standing' },
  { page: 'integrations', label: 'Integrations', icon: 'link' },
];

export function TabBar({ page, nav }: { page: Page; nav: NavItem[] }) {
  const tabs = nav.filter((n) => TAB_PAGES.includes(n.page));
  const more = [...nav.filter((n) => !TAB_PAGES.includes(n.page)), ...MORE_EXTRA];
  const inMore = more.some((n) => n.page === page);
  return (
    <nav className="tab-bar" aria-label="Main">
      {tabs.map((n) => (
        <a key={n.page} href={href(n.page)} className={page === n.page ? 'tab is-active' : 'tab'} aria-current={page === n.page ? 'page' : undefined}>
          <Icon name={n.icon} size={20} />
          <span>{n.label}</span>
        </a>
      ))}
      <MenuButton
        id="more"
        className={inMore ? 'tab is-active' : 'tab'}
        label="More pages"
        placement="up"
        menu={
          <>
            <MenuEyebrow>More</MenuEyebrow>
            {more.map((n) => (
              <a key={n.page} role="menuitem" tabIndex={-1} className="menu-item" href={href(n.page)} aria-current={page === n.page ? 'page' : undefined}>
                <Icon name={n.icon} />
                {n.label}
              </a>
            ))}
          </>
        }
      >
        <Icon name="more-horizontal" size={20} />
        <span>More</span>
      </MenuButton>
    </nav>
  );
}
