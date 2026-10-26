// The account menu ("Your workspace"), opened from the avatar at the top right, the sidebar's "Your profile" chip and
// the phone's top bar: Profile, Integrations, Privacy & data, Admin for admins, and Sign out when sign-in is on.
import type { Status } from '../../../shared/types.ts';
import { href, signOut } from '../../lib.ts';
import { Icon } from '../Icon.tsx';
import { AvatarFace } from './Avatar.tsx';
import { MenuButton, MenuEyebrow } from './Menu.tsx';

export type AccountProps = { status: Status | undefined; signedIn: boolean; isAdmin: boolean };

function AccountItems({ signedIn, isAdmin }: AccountProps) {
  return (
    <>
      <MenuEyebrow>Your workspace</MenuEyebrow>
      <a role="menuitem" tabIndex={-1} className="menu-item" href={href('profile')}>
        <Icon name="person-standing" />
        Profile
      </a>
      <a role="menuitem" tabIndex={-1} className="menu-item" href={href('integrations')}>
        <Icon name="link" />
        Integrations
      </a>
      <a role="menuitem" tabIndex={-1} className="menu-item" href="/privacy.html" target="_blank" rel="noopener">
        <Icon name="shield" />
        Privacy &amp; data
      </a>
      {isAdmin && (
        <a role="menuitem" tabIndex={-1} className="menu-item" href={href('admin')}>
          <Icon name="users" />
          Admin
        </a>
      )}
      {signedIn && (
        <>
          <div role="separator" className="menu-sep" />
          <button role="menuitem" tabIndex={-1} type="button" className="menu-item menu-item-quiet" onClick={signOut}>
            <Icon name="log-out" />
            Sign out
          </button>
        </>
      )}
    </>
  );
}

/** The avatar button (top bar, phone bar). */
export function AccountAvatar({ id, ...props }: AccountProps & { id: string }) {
  return (
    <MenuButton id={id} className="avatar" label="Your workspace" buttonLabel="Your workspace" placement="down" menu={<AccountItems {...props} />}>
      <AvatarFace status={props.status} />
    </MenuButton>
  );
}

/** The sidebar's chip: your avatar, your name and "Your profile"; it opens the same menu, upward. */
export function AccountChip(props: AccountProps) {
  const name = props.status?.settings.name?.trim() || props.status?.user.name || 'You';
  return (
    <MenuButton id="chip" className="user-chip" label="Your workspace" placement="up" menu={<AccountItems {...props} />}>
      <span className="avatar">
        <AvatarFace status={props.status} />
      </span>
      <span className="user-chip-text">
        <b>{name}</b>
        <small>Your profile</small>
      </span>
      <Icon name="chevron-up" size={14} />
    </MenuButton>
  );
}
