// What goes inside an avatar circle (.avatar): your photo's avatar crop when you have one, otherwise your initial.
import type { Status } from '../../../shared/types.ts';

export function AvatarFace({ status }: { status: Status | undefined }) {
  if (status?.photo) return <img src={`/api/profile/avatar.png?v=${status.photo.version}`} alt="" />;
  return <>{initialOf(status?.settings.name)}</>;
}

export const initialOf = (name: string | undefined) => (name?.trim() || '·').slice(0, 1).toUpperCase();
