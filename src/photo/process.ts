// Profile photo processing in the browser, for the hosted app (the Mac uses server/photo/cutout.swift with
// Apple Vision). A port of that tool's geometry: the same crop, padding, callout points, outline, avatar and
// edge clean-up, with Google's MediaPipe models (Apache-2.0) in place of Vision. The photo never leaves this
// device: only the finished cut-out, avatar and layout points are uploaded.
import type { PhotoMeta } from '../../shared/types.ts';
import wasmLoaderPath from '@mediapipe/tasks-vision/vision_wasm_internal.js?url';
import wasmBinaryPath from '@mediapipe/tasks-vision/vision_wasm_internal.wasm?url';

export type PhotoLayout = Omit<PhotoMeta, 'version' | 'dots'> & { dots: PhotoMeta['dots'] & { wrist?: [number, number] } };
export type ProcessedPhoto = { cutout: Blob; avatar: Blob; meta: PhotoLayout };

const MODELS = '/mediapipe';
/** The cut-out's longest side once uploaded: plenty for the Home figure, and well under the upload limit. */
const UPLOAD_SIDE = 1200;

class PhotoError extends Error {}

type Pt = { x: number; y: number };

async function decode(file: File): Promise<HTMLCanvasElement> {
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
  } catch {
    throw new PhotoError("Couldn't read that image. Use a JPEG or PNG photo.");
  }
  // Cap the size so processing stays quick, as the Mac tool does.
  const scale = Math.min(1, 1800 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  const ctx = canvas.getContext('2d')!;
  // Transparent PNGs (already cut out) go onto a neutral backdrop, like a studio wall.
  ctx.fillStyle = 'rgb(153, 150, 150)';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  return canvas;
}

async function models() {
  const vision = await import('@mediapipe/tasks-vision');
  const fileset = { wasmLoaderPath, wasmBinaryPath };
  const base = { delegate: 'CPU' as const };
  const [faces, segmenter, pose] = await Promise.all([
    vision.FaceDetector.createFromOptions(fileset, { baseOptions: { ...base, modelAssetPath: `${MODELS}/blaze_face_short_range.tflite` }, runningMode: 'IMAGE' }),
    vision.ImageSegmenter.createFromOptions(fileset, {
      baseOptions: { ...base, modelAssetPath: `${MODELS}/selfie_multiclass_256x256.tflite` },
      runningMode: 'IMAGE',
      outputConfidenceMasks: true,
      outputCategoryMask: false,
    }),
    vision.PoseLandmarker.createFromOptions(fileset, { baseOptions: { ...base, modelAssetPath: `${MODELS}/pose_landmarker_lite.task` }, runningMode: 'IMAGE', numPoses: 1 }),
  ]);
  return { faces, segmenter, pose };
}

const toBlob = (canvas: HTMLCanvasElement) =>
  new Promise<Blob>((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new PhotoError("Couldn't encode the image."))), 'image/png'));

/** Bilinear sample of a low-resolution mask, so a 256 px mask doesn't give a blocky edge at photo size. */
function sampler(mask: Float32Array, mw: number, mh: number, W: number, H: number) {
  return (x: number, y: number) => {
    const fx = Math.min(mw - 1, Math.max(0, ((x + 0.5) * mw) / W - 0.5));
    const fy = Math.min(mh - 1, Math.max(0, ((y + 0.5) * mh) / H - 0.5));
    const x0 = Math.floor(fx);
    const y0 = Math.floor(fy);
    const x1 = Math.min(mw - 1, x0 + 1);
    const y1 = Math.min(mh - 1, y0 + 1);
    const tx = fx - x0;
    const ty = fy - y0;
    const a = mask[y0 * mw + x0] * (1 - tx) + mask[y0 * mw + x1] * tx;
    const b = mask[y1 * mw + x0] * (1 - tx) + mask[y1 * mw + x1] * tx;
    return a * (1 - ty) + b * ty;
  };
}

/** In-place box blur of radius r, rows then columns, twice (close to a Gaussian). */
function blur(a: Float32Array, W: number, H: number, r: number) {
  const tmp = new Float32Array(Math.max(W, H));
  const pass = (len: number, count: number, at: (line: number, i: number) => number) => {
    for (let line = 0; line < count; line++) {
      let sum = 0;
      for (let i = -r; i <= r; i++) sum += a[at(line, Math.min(len - 1, Math.max(0, i)))];
      for (let i = 0; i < len; i++) {
        tmp[i] = sum / (2 * r + 1);
        sum += a[at(line, Math.min(len - 1, i + r + 1))] - a[at(line, Math.max(0, i - r))];
      }
      for (let i = 0; i < len; i++) a[at(line, i)] = tmp[i];
    }
  };
  for (let k = 0; k < 2; k++) {
    pass(W, H, (y, x) => y * W + x);
    pass(H, W, (x, y) => y * W + x);
  }
}

export async function processPhoto(file: File, onStep: (step: string) => void = () => {}): Promise<ProcessedPhoto> {
  onStep('Reading your photo…');
  const image = await decode(file);
  const W = image.width;
  const H = image.height;

  onStep('Loading the on-device models…');
  const { faces, segmenter, pose } = await models().catch(() => {
    throw new PhotoError("Couldn't load the photo tools. Check your connection and try again.");
  });
  try {
    onStep('Finding you in the photo…');
    const detections = faces.detect(image).detections;
    const best = detections
      .map((d) => d.boundingBox)
      .filter((b): b is NonNullable<typeof b> => Boolean(b))
      .sort((a, b) => b.width - a.width)[0];
    if (!best) throw new PhotoError('No face found. Use a photo where your face is clearly visible.');
    const faceRect = { x: best.originX, y: best.originY, w: best.width, h: best.height };

    // Person coverage, 0–1. The multiclass model's first mask is the background; everything else is you.
    const seg = segmenter.segment(image);
    const bg = seg.confidenceMasks?.[0];
    if (!bg) throw new PhotoError("Couldn't separate you from the background.");
    const mw = bg.width;
    const mh = bg.height;
    const raw = bg.getAsFloat32Array();
    const mask = new Float32Array(raw.length);
    for (let i = 0; i < raw.length; i++) mask[i] = 1 - raw[i];
    seg.close();

    // Bounding box of the subject, from the mask.
    let minX = mw;
    let minY = mh;
    let maxX = 0;
    let maxY = 0;
    for (let y = 0; y < mh; y++) {
      for (let x = 0; x < mw; x++) {
        if (mask[y * mw + x] > 0.5) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (!(maxX > minX && maxY > minY)) throw new PhotoError("Couldn't find a person in the photo.");
    const sx = W / mw;
    const sy = H / mh;
    const padX = W * 0.03;
    const padTop = H * 0.03;
    const cx0 = Math.max(0, minX * sx - padX);
    const cy0 = Math.max(0, minY * sy - padTop);
    const cx1 = Math.min(W, (maxX + 1) * sx + padX);
    const cy1 = Math.min(H, (maxY + 1) * sy);
    const crop = { x: Math.floor(cx0), y: Math.floor(cy0), w: Math.ceil(cx1) - Math.floor(cx0), h: Math.ceil(cy1) - Math.floor(cy0) };

    // Body points (when visible) for the throat, heart and wrist. MediaPipe's 11/12 are the subject's own
    // left/right shoulders and 15/16 the wrists, as Vision's are; its coordinates are already top-left.
    onStep('Placing your vitals…');
    const lm = pose.detect(image).landmarks[0] ?? [];
    const joint = (i: number, minVisibility = 0.3): Pt | null => {
      const p = lm[i];
      return p && (p.visibility ?? 1) > minVisibility ? { x: p.x * W, y: p.y * H } : null;
    };
    const lShoulder = joint(11);
    const rShoulder = joint(12);
    // MediaPipe has no neck point: Vision's sits between the shoulders.
    const neck = lShoulder && rShoulder ? { x: (lShoulder.x + rShoulder.x) / 2, y: (lShoulder.y + rShoulder.y) / 2 } : null;

    const forehead = { x: faceRect.x + faceRect.w / 2, y: faceRect.y - faceRect.h * 0.08 };
    const chin = { x: faceRect.x + faceRect.w / 2, y: faceRect.y + faceRect.h };
    const neckPoint = neck ?? { x: chin.x, y: chin.y + faceRect.h * 0.45 };
    const throat = { x: chin.x + (neckPoint.x - chin.x) * 0.2, y: chin.y + (neckPoint.y - chin.y) * 0.2 };
    const halfSpan = lShoulder ? lShoulder.x - neckPoint.x : rShoulder ? neckPoint.x - rShoulder.x : faceRect.w * 1.3;
    const heart = { x: neckPoint.x + halfSpan * 0.42, y: neckPoint.y + Math.abs(halfSpan) * 0.5 };
    const shoulderTop = Math.min(...[lShoulder?.y, rShoulder?.y].filter((v): v is number => v !== undefined), neckPoint.y + faceRect.h * 0.1);
    const wrists = [joint(15, 0.1), joint(16, 0.1)].filter((p): p is Pt => p !== null && p.y < H && p.x >= 0 && p.x <= W);
    const wrist = wrists.sort((a, b) => a.y - b.y)[0];
    const norm = (p: Pt): [number, number] => [(p.x - crop.x) / crop.w, (p.y - crop.y) / crop.h];

    // Cut-out. Soft edge pixels mix you and the old backdrop (a pale rim), so their color is replaced by the
    // nearest solid interior color, then the alpha edge is pulled in slightly: as the Mac tool does.
    onStep('Cutting you out…');
    const ctx = image.getContext('2d', { willReadFrequently: true })!;
    const px = ctx.getImageData(0, 0, W, H);
    const d = px.data;
    const sample = sampler(mask, mw, mh, W, H);
    const coverage = new Float32Array(W * H);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) coverage[y * W + x] = sample(x, y);
    // The mask is about 256 px stretched to the photo: soften it by about half a mask pixel so its steps don't
    // show as a jagged edge on the shoulders (two passes of a box blur, along rows then columns).
    blur(coverage, W, H, Math.max(1, Math.round(Math.max(W / mw, H / mh) / 2)));
    const known = new Uint8Array(W * H);
    let edge: number[] = [];
    for (let i = 0; i < W * H; i++) {
      if (coverage[i] >= 0.97) known[i] = 1;
      else if (coverage[i] > 0.02) edge.push(i);
    }
    for (let round = 0; round < 10 && edge.length; round++) {
      const grown: number[] = [];
      const next: number[] = [];
      for (const i of edge) {
        const x = i % W;
        const y = (i - x) / W;
        if (x === 0 || y === 0 || x === W - 1 || y === H - 1) continue;
        let r = 0;
        let g = 0;
        let b = 0;
        let n = 0;
        for (let oy = -1; oy <= 1; oy++) {
          for (let ox = -1; ox <= 1; ox++) {
            const j = i + oy * W + ox;
            if (known[j]) {
              r += d[j * 4];
              g += d[j * 4 + 1];
              b += d[j * 4 + 2];
              n++;
            }
          }
        }
        if (n) {
          d[i * 4] = r / n;
          d[i * 4 + 1] = g / n;
          d[i * 4 + 2] = b / n;
          grown.push(i);
        } else next.push(i);
      }
      for (const i of grown) known[i] = 1;
      edge = next;
    }
    for (let i = 0; i < W * H; i++) {
      // smoothstep(0.4, 0.97): a slightly tighter, still soft edge.
      const t = Math.max(0, Math.min(1, (coverage[i] - 0.4) / 0.57));
      d[i * 4 + 3] = Math.round(t * t * (3 - 2 * t) * 255);
    }
    const cut = document.createElement('canvas');
    const k = Math.min(1, UPLOAD_SIDE / Math.max(crop.w, crop.h));
    cut.width = Math.round(crop.w * k);
    cut.height = Math.round(crop.h * k);
    const full = document.createElement('canvas');
    full.width = W;
    full.height = H;
    full.getContext('2d')!.putImageData(px, 0, 0);
    const cutCtx = cut.getContext('2d')!;
    cutCtx.imageSmoothingQuality = 'high';
    cutCtx.drawImage(full, crop.x, crop.y, crop.w, crop.h, 0, 0, cut.width, cut.height);

    // Silhouette outline, 100 rows: where the person starts and ends across each row (0–1 of the cut-out width).
    const outline: [number, number][] = [];
    for (let i = 0; i < 100; i++) {
      const iy = Math.min(mh - 1, Math.floor((crop.y + ((i + 0.5) / 100) * crop.h) / sy));
      let lo = -1;
      let hi = -1;
      for (let x = 0; x < mw; x++) {
        if (mask[iy * mw + x] > 0.5) {
          if (lo < 0) lo = x;
          hi = x;
        }
      }
      outline.push(lo < 0 ? [1, 0] : [Math.max(0, Math.min(1, (lo * sx - crop.x) / crop.w)), Math.max(0, Math.min(1, ((hi + 1) * sx - crop.x) / crop.w))]);
    }

    // Square avatar around the face, from the original photo.
    const side = Math.min(W, H, faceRect.h * 2.1);
    const ax = Math.min(Math.max(0, faceRect.x + faceRect.w / 2 - side / 2), W - side);
    const ay = Math.min(Math.max(0, faceRect.y + faceRect.h / 2 - side * 0.46), H - side);
    const avatar = document.createElement('canvas');
    avatar.width = 320;
    avatar.height = 320;
    const avCtx = avatar.getContext('2d')!;
    avCtx.imageSmoothingQuality = 'high';
    // The decoded photo itself is untouched: the cut-out was built in a copy of its pixels.
    avCtx.drawImage(image, ax, ay, side, side, 0, 0, 320, 320);

    const clamp01 = ([x, y]: [number, number]): [number, number] => [Math.max(0, Math.min(1, x)), Math.max(0, Math.min(1, y))];
    const dots: PhotoLayout['dots'] = { temp: clamp01(norm(forehead)), breathing: clamp01(norm(throat)), heart: clamp01(norm(heart)) };
    if (wrist) dots.wrist = clamp01(norm(wrist));
    const meta: PhotoLayout = {
      width: cut.width,
      height: cut.height,
      face: [(faceRect.x - crop.x) / crop.w, (faceRect.y - crop.y) / crop.h, faceRect.w / crop.w, faceRect.h / crop.h].map((v) => Math.max(0, Math.min(1, v))) as [number, number, number, number],
      shoulderY: Math.max(0, Math.min(1, (shoulderTop - crop.y) / crop.h)),
      outline,
      dots,
    };
    onStep('Saving…');
    return { cutout: await toBlob(cut), avatar: await toBlob(avatar), meta };
  } finally {
    faces.close();
    segmenter.close();
    pose.close();
  }
}

export const isPhotoError = (e: unknown): e is Error => e instanceof PhotoError;
