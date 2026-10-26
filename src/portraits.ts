// Portraits on the device (shared/portraits.ts). A reference photo is shrunk to a JPEG here before it's uploaded, by
// onboarding's step 1 and Profile's portrait studio alike; and a generated portrait becomes the profile photo through
// the same on-device cut-out as "Use a photo as is" (src/photo/process.ts), so Home, Body, the Family board and the
// iPhone app show it like any photo.
import { MAX_REFERENCE_BASE64, MAX_REFERENCE_EDGE, type Portrait, type PortraitCreated, type PortraitReferenceInput } from '../shared/portraits.ts';
import { sendJson } from './lib.ts';

/** The image, served to its owner only. */
export const portraitImage = (p: Pick<Portrait, 'id'>) => `/api/portraits/${encodeURIComponent(p.id)}/image`;

/** An image file the browser can likely open (HEIC by its name, since some browsers give it no type). */
export const isImageFile = (file: File) => file.type.startsWith('image/') || /\.(heic|heif)$/i.test(file.name);

/**
 * The reference as a JPEG, longest side 1600 or less, drawn afresh on a canvas: that also leaves the file's metadata
 * (where and when it was taken, the camera) behind. Smaller again in the rare case it's still over the upload limit.
 */
export async function shrinkReference(file: File): Promise<{ input: PortraitReferenceInput; preview: string }> {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    for (let edge = MAX_REFERENCE_EDGE; edge >= 400; edge = Math.round(edge * 0.75)) {
      const scale = Math.min(1, edge / Math.max(img.naturalWidth, img.naturalHeight));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.naturalWidth * scale);
      canvas.height = Math.round(img.naturalHeight * scale);
      canvas.getContext('2d')!.drawImage(img, 0, 0, canvas.width, canvas.height);
      const preview = canvas.toDataURL('image/jpeg', 0.86);
      const image = preview.slice(preview.indexOf(',') + 1);
      if (image.length <= MAX_REFERENCE_BASE64) return { input: { image, width: canvas.width, height: canvas.height }, preview };
    }
    throw new Error('Too large');
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** Saves a shrunk reference; the answer is the photo as stored, with its id. */
export const uploadReference = async (input: PortraitReferenceInput) => (await sendJson<PortraitCreated>('POST', '/portraits/reference', input)).portrait;

const base64 = (blob: Blob) =>
  new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1] ?? '');
    reader.onerror = () => reject(new Error("Couldn't read the processed portrait."));
    reader.readAsDataURL(blob);
  });

/**
 * Makes a ready portrait the profile photo: cut out and measured on this device, saved (replacing the photo there was),
 * marked as the portrait in use, and the perspective set to "Your own portrait". onStep gets each step's words.
 */
export async function makeProfilePhoto(p: Portrait, onStep: (step: string) => void) {
  onStep('Loading your portrait…');
  const res = await fetch(portraitImage(p)).catch(() => null);
  if (!res?.ok) throw new Error("Couldn't load this portrait. Check your connection and try again.");
  const blob = await res.blob();
  const file = new File([blob], 'portrait', { type: blob.type || p.mime });
  const { processPhoto } = await import('./photo/process.ts');
  let done: Awaited<ReturnType<typeof processPhoto>>;
  try {
    done = await processPhoto(file, onStep);
  } catch (e) {
    // The cut-out places your vitals from the face; a portrait where it can't find one can't be used.
    if (/No face found/.test((e as Error).message)) throw new Error("healthOS couldn't find a face in this portrait, so it can't place your vitals on it. Try making another.");
    throw e;
  }
  onStep('Saving…');
  const saved = await fetch('/api/profile/photo/upload', {
    method: 'POST',
    headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json' },
    body: JSON.stringify({ cutout: await base64(done.cutout), avatar: await base64(done.avatar), meta: done.meta }),
  }).catch(() => null);
  if (!saved) throw new Error("Couldn't reach healthOS. Check your connection and try again.");
  if (saved.status === 413) throw new Error('This portrait came out too large to save. Try making another.');
  if (!saved.ok) throw new Error(((await saved.json().catch(() => ({}))) as { error?: string }).error ?? "Couldn't save your portrait as your photo.");
  // Marked only once it really is the profile photo.
  await sendJson('POST', `/portraits/${encodeURIComponent(p.id)}/choose`);
  await sendJson('PUT', '/settings', { perspective: 'portrait' });
}
