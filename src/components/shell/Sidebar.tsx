// The sidebar on a computer: the healthOS mark, the main pages, and your chip at the bottom (the account menu).
import type { Page } from '../../../shared/types.ts';
import { href } from '../../lib.ts';
import { Icon } from '../Icon.tsx';
import { type AccountProps, AccountChip } from './AccountMenu.tsx';
import { Logo } from './Logo.tsx';
import type { NavItem } from './nav.ts';

export function Sidebar({ page, nav, account }: { page: Page; nav: NavItem[]; account: AccountProps }) {
  return (
    <aside className="sidebar">
      <a className="brand" href={href('home')}>
        <Logo />
        <span>healthOS</span>
      </a>
      <nav aria-label="Main">
        {nav.map((n) => (
          <a key={n.page} href={href(n.page)} className={page === n.page ? 'nav-item is-active' : 'nav-item'} aria-current={page === n.page ? 'page' : undefined}>
            <Icon name={n.icon} size={16} />
            <span>{n.label}</span>
          </a>
        ))}
      </nav>
      <div className="sidebar-foot">
        <AccountChip {...account} />
      </div>
    </aside>
  );
}
