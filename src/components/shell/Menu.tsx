// A popover menu (the ARIA menu pattern) under or over the button that opens it, and a sheet from the bottom on a
// phone. Arrow keys, Home and End move between its items; Escape closes it and puts focus back on the button; Tab or a
// click outside closes it. One menu is open at a time across the shell (MenuContext), so the avatar, the sidebar's
// "Your profile" chip and the phone's More button never leave two open.
import { type ReactNode, type RefObject, createContext, useContext, useEffect, useId, useRef } from 'react';

export const MenuContext = createContext<{ open: string | null; setOpen: (id: string | null) => void }>({ open: null, setOpen: () => {} });

/**
 * A button that opens `menu`. Its id names it in MenuContext; `placement` says which way the menu opens on a computer.
 * `label` names the menu; `buttonLabel` names a button that shows no words of its own (an avatar).
 */
export function MenuButton({
  id,
  className,
  label,
  buttonLabel,
  placement,
  menu,
  children,
}: {
  id: string;
  className: string;
  label: string;
  buttonLabel?: string;
  placement: 'down' | 'up';
  menu: ReactNode;
  children: ReactNode;
}) {
  const { open, setOpen } = useContext(MenuContext);
  const trigger = useRef<HTMLButtonElement>(null);
  const isOpen = open === id;
  const menuId = useId();
  return (
    <div className={`menu-anchor menu-${placement}`}>
      <button
        ref={trigger}
        type="button"
        className={className}
        aria-label={buttonLabel}
        aria-haspopup="menu"
        aria-expanded={isOpen}
        aria-controls={isOpen ? menuId : undefined}
        onClick={() => setOpen(isOpen ? null : id)}
      >
        {children}
      </button>
      {isOpen && (
        <Menu id={menuId} label={label} trigger={trigger} onClose={() => setOpen(null)}>
          {menu}
        </Menu>
      )}
    </div>
  );
}

function Menu({ id, label, trigger, onClose, children }: { id: string; label: string; trigger: RefObject<HTMLButtonElement | null>; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const close = useRef(onClose);
  close.current = onClose;
  const items = () => [...(ref.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])];

  // Focus starts on the first item.
  useEffect(() => {
    items()[0]?.focus({ preventScroll: true });
  }, []);

  // A press anywhere but the menu and its own button closes it (the button toggles it itself).
  useEffect(() => {
    const onDown = (e: PointerEvent) => {
      const t = e.target instanceof Node ? e.target : null;
      if (t && (ref.current?.contains(t) || trigger.current?.contains(t))) return;
      close.current();
    };
    document.addEventListener('pointerdown', onDown);
    return () => document.removeEventListener('pointerdown', onDown);
  }, [trigger]);

  const move = (to: (i: number, n: number) => number) => {
    const list = items();
    if (!list.length) return;
    const i = list.indexOf(document.activeElement as HTMLElement);
    list[to(i, list.length)]?.focus();
  };

  return (
    <>
      <div className="menu-scrim" aria-hidden="true" />
      <div
        ref={ref}
        id={id}
        className="menu"
        role="menu"
        aria-label={label}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') move((i, n) => (i + 1) % n);
          else if (e.key === 'ArrowUp') move((i, n) => (i - 1 + n) % n);
          else if (e.key === 'Home') move(() => 0);
          else if (e.key === 'End') move((_, n) => n - 1);
          else if (e.key === 'Escape') {
            e.stopPropagation();
            close.current();
            trigger.current?.focus();
          } else if (e.key === 'Tab') close.current();
          else return;
          if (e.key !== 'Tab') e.preventDefault();
        }}
        // Choosing an item closes the menu (a link still opens: an <a> follows its href after it's gone).
        onClick={(e) => {
          if ((e.target as Element).closest('[role="menuitem"]')) close.current();
        }}
      >
        {children}
      </div>
    </>
  );
}

/** A menu's heading line ("YOUR WORKSPACE"). */
export const MenuEyebrow = ({ children }: { children: ReactNode }) => (
  <p className="menu-eyebrow eyebrow" aria-hidden="true">
    {children}
  </p>
);
