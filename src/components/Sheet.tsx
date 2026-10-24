// A modal dialog over a light, blurred veil (Edit widgets, and the pages' own forms and explainers). It works like the
// metric sheet: the page behind is inert and doesn't scroll, focus starts on the title and stays inside, Escape or a
// click on the veil closes it, and focus goes back to whatever opened it. Full screen on a phone.
//
//   <Sheet eyebrow="Home" title="Edit widgets" onClose={close} footer={<button className="btn btn-primary">Done</button>}>…</Sheet>
import { type MouseEvent, type ReactNode, useEffect, useId, useRef } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from './Icon.tsx';

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function Sheet({
  eyebrow,
  title,
  onClose,
  children,
  footer,
  size = 'md',
}: {
  /** A short line above the title, in capitals ("Your signals"). */
  eyebrow?: ReactNode;
  title: ReactNode;
  onClose: () => void;
  children: ReactNode;
  /** Buttons along the bottom, right-aligned. */
  footer?: ReactNode;
  /** 480, 650 or 860px wide. */
  size?: 'sm' | 'md' | 'lg';
}) {
  const panel = useRef<HTMLDivElement>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const titleId = useId();
  // Read when the sheet opens, so focus can go back there when it closes.
  const opener = useRef<HTMLElement | null>(document.activeElement instanceof HTMLElement ? document.activeElement : null);
  const close = useRef(onClose);
  close.current = onClose;

  // While open: the app behind is inert (no focus, hidden from screen readers) and doesn't scroll.
  useEffect(() => {
    const root = document.getElementById('root');
    const wasInert = root?.hasAttribute('inert') ?? true;
    if (root && !wasInert) root.setAttribute('inert', '');
    const html = document.documentElement;
    const before = { html: html.style.overflow, body: document.body.style.overflow };
    html.style.overflow = 'hidden';
    document.body.style.overflow = 'hidden';
    heading.current?.focus({ preventScroll: true });
    const back = opener.current;
    return () => {
      if (root && !wasInert) root.removeAttribute('inert');
      html.style.overflow = before.html;
      document.body.style.overflow = before.body;
      if (back?.isConnected) back.focus({ preventScroll: true });
    };
  }, []);

  // Keys are heard on the document, so Escape and Tab work after a click on the sheet's text leaves focus on the body.
  // Keys for something else on top (the search palette) are left to it.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const p = panel.current;
      const target = e.target instanceof Node ? e.target : null;
      const onPage = !target || target === document || target === document.body || target === document.documentElement;
      if (!p || e.defaultPrevented || !(onPage || p.contains(target))) return;
      if (e.key === 'Escape') {
        e.stopPropagation();
        close.current();
        return;
      }
      if (e.key !== 'Tab') return;
      const items = [...p.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => el.offsetParent !== null || el === document.activeElement);
      if (!items.length) return;
      const first = items[0];
      const last = items.at(-1)!;
      const at = document.activeElement;
      const off = at === p || at === heading.current || !p.contains(at);
      if (e.shiftKey && (at === first || off)) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && (at === last || (off && at !== heading.current))) {
        e.preventDefault();
        first.focus();
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  // A press that starts and ends on the veil closes; one that starts inside (selecting text, a drag) doesn't.
  const downOnVeil = useRef(false);
  const onDown = (e: MouseEvent<HTMLDivElement>) => {
    downOnVeil.current = e.target === e.currentTarget;
  };
  const onClick = (e: MouseEvent<HTMLDivElement>) => {
    if (downOnVeil.current && e.target === e.currentTarget) close.current();
    downOnVeil.current = false;
  };

  return createPortal(
    <div className="sheet-veil" onMouseDown={onDown} onClick={onClick}>
      <div ref={panel} className={`sheet sheet-${size}`} role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1}>
        <header className="sheet-head">
          <div>
            {eyebrow && <p className="eyebrow">{eyebrow}</p>}
            <h2 id={titleId} ref={heading} tabIndex={-1}>
              {title}
            </h2>
          </div>
          <button type="button" className="sheet-close" onClick={() => close.current()} aria-label="Close">
            <Icon name="x" size={16} strokeWidth={1.8} />
          </button>
        </header>
        <div className="sheet-body">{children}</div>
        {footer && <footer className="sheet-foot">{footer}</footer>}
      </div>
    </div>,
    document.body,
  );
}
