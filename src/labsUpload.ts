// Getting a lab report ready to keep, on the person's own device: a PDF goes as it is (up to the limit); a photo is
// turned the right way up, made smaller and saved as JPEG until it fits, which also turns iPhone HEIC photos into
// something a browser can show and Claude can read. It's sent as its own bytes to POST /api/labs/documents and kept in
// Lab documents; reading its results (POST /api/labs/extract?document=) happens only when the person asks.
import type { LabDocumentSaved, LabExtract } from '../shared/labs.ts';

/** The server's limit (server/labs.ts MAX_REPORT_BYTES). */
export const MAX_REPORT_BYTES = 4 * 1024 * 1024;
export const REPORT_ACCEPT = 'application/pdf,image/jpeg,image/png,image/webp,image/heic,image/heif,.pdf,.heic,.heif';

/** Photos at or under this are sent untouched: re-encoding a small screenshot only blurs its text. */
const SEND_AS_IS = 1.5 * 1024 * 1024;
/** Long edges to try, largest first: enough for small print on a full page. */
const EDGES = [2400, 2000, 1600];

const typeOf = (file: File) =>
  file.type || (/\.pdf$/i.test(file.name) ? 'application/pdf' : /\.(heic|heif)$/i.test(file.name) ? 'image/heic' : /\.jpe?g$/i.test(file.name) ? 'image/jpeg' : /\.png$/i.test(file.name) ? 'image/png' : '');

async function decode(file: File): Promise<ImageBitmap | HTMLImageElement> {
  try {
    return await createImageBitmap(file, { imageOrientation: 'from-image' });
  } catch {
    // Some browsers decode a format in <img> but not in createImageBitmap.
    const url = URL.createObjectURL(file);
    try {
      const img = new Image();
      img.src = url;
      await img.decode();
      return img;
    } finally {
      URL.revokeObjectURL(url);
    }
  }
}

const jpeg = (canvas: HTMLCanvasElement, quality: number) =>
  new Promise<Blob>((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("Couldn't prepare that photo. Try a screenshot instead."))), 'image/jpeg', quality));

/** The file to send, or an Error whose message says plainly what to do instead. */
export async function prepareReport(file: File): Promise<Blob> {
  const type = typeOf(file);
  if (type === 'application/pdf') {
    if (file.size > MAX_REPORT_BYTES) throw new Error('This PDF is over 4 MB, the most that can be kept. Try a photo or screenshot of the results pages instead.');
    return file.slice(0, file.size, 'application/pdf');
  }
  if (!type.startsWith('image/')) throw new Error('Choose a PDF, or a photo or screenshot of the report.');
  if (['image/jpeg', 'image/png', 'image/webp'].includes(type) && file.size <= SEND_AS_IS) return file.slice(0, file.size, type);

  let image: ImageBitmap | HTMLImageElement;
  try {
    image = await decode(file);
  } catch {
    throw new Error(
      /heic|heif/.test(type)
        ? "This browser can't open HEIC photos. Choose a screenshot of the photo instead, export the photo as a JPEG first, or try Safari."
        : "Couldn't open that image. Try a screenshot of the report instead.",
    );
  }
  const w = image.width;
  const h = image.height;
  for (const edge of EDGES) {
    const scale = Math.min(1, edge / Math.max(w, h));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(w * scale);
    canvas.height = Math.round(h * scale);
    const ctx = canvas.getContext('2d');
    if (!ctx) break;
    // White under any transparency, so a PNG with see-through parts doesn't turn black as a JPEG.
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
    for (const quality of [0.9, 0.8, 0.7]) {
      const blob = await jpeg(canvas, quality);
      if (blob.size <= MAX_REPORT_BYTES) return blob;
    }
  }
  throw new Error("That photo is too large to send, even made smaller. Try a screenshot of just the results.");
}

/** The name to keep a prepared file under: a photo made a JPEG here ends in .jpg, so it opens as what it now is. */
export function reportName(file: File, prepared: Blob) {
  const name = file.name.trim() || 'Lab report';
  if (prepared.type !== 'image/jpeg' || /\.jpe?g$/i.test(name)) return name;
  return `${name.replace(/\.(heic|heif|png|webp|gif)$/i, '')}.jpg`;
}

const UNREACHABLE = "Couldn't reach healthOS. Check your connection and try again.";
/** A reply without our { error } is the platform's: too large, or timed out. */
const platformWords = (status: number) => (status === 413 ? 'That file is too large to send. Try a smaller photo or a screenshot.' : 'Something went wrong. Try again in a moment.');

/**
 * Keep a prepared file in Lab documents, reporting progress as a share of the bytes sent (0 to 1). Errors come back
 * in the server's own words ("You've already uploaded this report."), or plain ones when it never got there.
 */
export function uploadDocument(blob: Blob, name: string, onProgress: (share: number) => void): Promise<LabDocumentSaved> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/labs/documents');
    xhr.setRequestHeader('X-HealthOS', '1');
    xhr.setRequestHeader('Content-Type', blob.type);
    // Headers carry Latin-1 only: the name goes URI-encoded, and the server decodes it.
    xhr.setRequestHeader('X-Filename', encodeURIComponent(name));
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total);
    xhr.onload = () => {
      if (xhr.status === 401) window.dispatchEvent(new Event('healthos:signin'));
      let body: (LabDocumentSaved & { error?: string }) | null = null;
      try {
        body = JSON.parse(xhr.responseText);
      } catch {
        body = null;
      }
      if (xhr.status >= 200 && xhr.status < 300 && body?.document) resolve(body);
      else reject(new Error(body?.error ?? platformWords(xhr.status)));
    };
    xhr.onerror = () => reject(new Error(UNREACHABLE));
    xhr.send(blob);
  });
}

/** Read the results from a kept report: a draft for the person to check, nothing saved. */
export async function readDocument(id: string): Promise<LabExtract> {
  let res: Response;
  try {
    res = await fetch(`/api/labs/extract?document=${encodeURIComponent(id)}`, { method: 'POST', headers: { 'X-HealthOS': '1' } });
  } catch {
    throw new Error(UNREACHABLE);
  }
  if (res.status === 401) window.dispatchEvent(new Event('healthos:signin'));
  const body = (await res.json().catch(() => null)) as (LabExtract & { error?: string }) | null;
  if (!res.ok) throw new Error(body?.error ?? platformWords(res.status));
  return body!;
}
