// The top of every page in the shell: the page's title over "Your health, in perspective.", or on Home a greeting
// ("Hello," / "Ricardo." / "Here's your health today."), with the top bar on the right. The one h1 on the screen.
import type { Page } from '../../../shared/types.ts';
import { fmtDate } from '../../lib.ts';
import type { AccountProps } from './AccountMenu.tsx';
import { PAGE_META, SUBTITLE } from './nav.ts';
import { TopBar } from './TopBar.tsx';

/** The pages that show the shared day (App's date): Home, and Sleep and Body's day pickers. */
const DATED: Page[] = ['home', 'sleep', 'body'];

export function ShellHeader({
  page,
  date,
  setDate,
  reload,
  account,
}: {
  page: Page;
  date: string | null;
  setDate: (d: string | null) => void;
  reload: () => void;
  account: AccountProps;
}) {
  const home = page === 'home';
  const name = account.status?.settings.name?.trim();
  return (
    <header className={`shell-header${home ? ' is-home' : ''}`}>
      <div className="shell-title">
        {home ? (
          <>
            <p className="shell-hello">Hello,</p>
            <h1>{name || 'there'}.</h1>
            <p className="shell-sub">{date ? `Here's your health on ${fmtDate(date, { weekday: 'long', month: 'long', day: 'numeric' })}.` : "Here's your health today."}</p>
          </>
        ) : (
          <>
            <h1>{PAGE_META[page].title}</h1>
            <p className="shell-sub">{SUBTITLE}</p>
          </>
        )}
      </div>
      <TopBar home={home} datedPage={DATED.includes(page)} date={date} setDate={setDate} reload={reload} account={account} />
    </header>
  );
}
