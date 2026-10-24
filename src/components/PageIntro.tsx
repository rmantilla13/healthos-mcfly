// A page's intro row, under the shell's title: a heading and a line about the page on the left, its actions (pills)
// on the right, and under them an optional slot for the page's tabs, range filters or day picker. The slot keeps one
// height (.page-head-tools' min-height) whether it holds a picker or not, so tabs never jump between tabs.
import type { ReactNode } from 'react';
import { href } from '../lib.ts';
import { Icon } from './Icon.tsx';

export function PageIntro({ title, sub, actions, children }: { title?: ReactNode; sub?: ReactNode; actions?: ReactNode; children?: ReactNode }) {
  return (
    <header className="page-intro">
      {(title || sub || actions) && (
        <div className="page-intro-row">
          <div className="page-intro-text">
            {title && <h2>{title}</h2>}
            {sub && <p>{sub}</p>}
          </div>
          {actions && <div className="page-intro-actions">{actions}</div>}
        </div>
      )}
      {children && <div className="page-intro-slot">{children}</div>}
    </header>
  );
}

/** The "Manage sources ↗" pill, for an intro's actions: Integrations. */
export function ManageSources({ label = 'Manage sources' }: { label?: string }) {
  return (
    <a className="pill" href={href('integrations')}>
      {label}
      <Icon name="arrow-up-right" size={14} />
    </a>
  );
}
