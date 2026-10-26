// "Ask McFly", floating at the bottom right of Home (above the tab bar on a phone): McFly's orb and a line, and a
// link to the Ask McFly page.
import { href } from '../../lib.ts';
import { Icon } from '../Icon.tsx';
import { Orb } from '../Orb.tsx';

export function AskPill() {
  return (
    <a className="ask-pill" href={href('mcfly')}>
      <Orb size={24} />
      <span className="ask-pill-text">
        <b>Ask McFly</b>
        <small>A little more clarity</small>
      </span>
      <Icon name="message-square-text" size={16} />
    </a>
  );
}
