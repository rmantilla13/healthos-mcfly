// Portraits (server/portraits.ts): a private reference photo, and likenesses generated from it in the healthOS style
// with the person's own OpenAI key. The reference is never shown on the dashboard; a generated portrait the person
// chooses goes through the usual on-device cut-out and becomes their figure (POST /api/profile/photo/upload).

export type PortraitKind = 'reference' | 'generated';
export type PortraitStatus = 'pending' | 'ready' | 'failed';

export type Portrait = {
  id: string;
  kind: PortraitKind;
  status: PortraitStatus;
  mime: string;
  width: number | null;
  height: number | null;
  bytes: number;
  /** For a generated portrait, the reference it came from. */
  referenceId: string | null;
  /** Why generating failed, in plain words. */
  error: string;
  createdAt: number;
};

/** GET /api/portraits. chosen is the generated portrait in use, if any. */
export type PortraitList = { portraits: Portrait[]; chosen: string | null; canGenerate: boolean };

/** POST /api/portraits/reference: a JPEG shrunk on the device (longest side 1600 or less), base64 without a data: prefix. */
export type PortraitReferenceInput = { image: string; width: number; height: number };

/** POST /api/portraits/reference and POST /api/portraits/generate: the photo saved, or the portrait being made. */
export type PortraitCreated = { portrait: Portrait };

export const MAX_REFERENCES = 5;
/** Base64 characters, a little under Vercel's 4.5 MB request limit. */
export const MAX_REFERENCE_BASE64 = 4_400_000;
/** A reference's longest side, in pixels: the device shrinks it to this. */
export const MAX_REFERENCE_EDGE = 1600;
/** Generated portraits kept per person: delete one to make another. */
export const MAX_GENERATED = 20;
/** Portraits a person can make in a day (UTC), each one a paid image call. */
export const PORTRAITS_PER_DAY = 10;
