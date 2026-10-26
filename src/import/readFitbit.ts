// Starts reading a chosen Fitbit export in a Web Worker (fitbit.worker.ts), or on the page where workers can't run.
// cancel() stops it, when the sheet closes mid-read.
import type { FitbitFound } from './fitbit.ts';
import { type FitbitInput, type FitbitProgress, readFitbitFiles } from './fitbitFiles.ts';
import type { FitbitWorkerIn, FitbitWorkerOut } from './fitbit.worker.ts';
import { ZipError } from './zip.ts';

const UNREADABLE = "This export couldn't be read. Choose the .zip from Takeout, or its unzipped folder.";

export function readFitbitExport(inputs: FitbitInput[], timeZone: string, onProgress: (p: FitbitProgress) => void): { done: Promise<FitbitFound>; cancel: () => void } {
  let worker: Worker | null = null;
  try {
    worker = new Worker(new URL('./fitbit.worker.ts', import.meta.url), { type: 'module' });
  } catch {
    worker = null;
  }
  if (!worker) {
    let cancelled = false;
    const done = readFitbitFiles(inputs, timeZone, (p) => !cancelled && onProgress(p)).catch((err: unknown) => {
      throw new Error(err instanceof ZipError ? err.message : UNREADABLE);
    });
    return { done, cancel: () => void (cancelled = true) };
  }
  const w = worker;
  const done = new Promise<FitbitFound>((resolve, reject) => {
    w.onmessage = (e: MessageEvent<FitbitWorkerOut>) => {
      const m = e.data;
      if (m.kind === 'progress') onProgress({ read: m.read, total: m.total });
      else {
        w.terminate();
        if (m.kind === 'done') resolve(m.found);
        else reject(new Error(m.message));
      }
    };
    w.onerror = () => {
      w.terminate();
      reject(new Error(UNREADABLE));
    };
    w.postMessage({ inputs, timeZone } satisfies FitbitWorkerIn);
  });
  return { done, cancel: () => w.terminate() };
}
