// The full-screen frame of the way in: sign-in, an invite's "Create your account" and the onboarding steps share it, so
// registration reads as one flow. The healthOS mark top left, an optional link top right (Sign out, Back to Profile),
// a glass card in the middle and the tagline under it. No sidebar: none of these pages is inside the dashboard yet.
import type { ReactNode } from 'react';
import '../styles/onboarding.css';
import { Logo } from './shell/Logo.tsx';

export function WelcomeShell({ end, main = false, children }: { end?: ReactNode; main?: boolean; children: ReactNode }) {
  // Onboarding already sits inside the app's <main>; the sign-in pages have no other landmark.
  const Body = main ? 'main' : 'div';
  return (
    <div className="onb">
      <header className="onb-top">
        <span className="onb-brand">
          <Logo />
          <span>healthOS</span>
        </span>
        {end}
      </header>
      <Body className="onb-body">{children}</Body>
      <p className="onb-tagline">Your health, in perspective. Only yours.</p>
    </div>
  );
}

/** A step's or a form's last row: Back and a helper line on the left, the main button on the right. */
export function WelcomeFoot({ start, children }: { start?: ReactNode; children: ReactNode }) {
  return (
    <div className="onb-foot">
      <div className="onb-foot-start">{start}</div>
      {children}
    </div>
  );
}
