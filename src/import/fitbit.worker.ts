// Reads a Fitbit export off the main thread, so the page stays responsive through thousands of files. Posts progress
// as it goes and the readings found at the end; nothing here talks to the network.
import { type FitbitInput, readFitbitFiles } from './fitbitFiles.ts';
import type { FitbitFound } from './fitbit.ts';
import { ZipError } from './zip.ts';

export type FitbitWorkerIn = { inputs: FitbitInput[]; timeZone: string };
export type FitbitWorkerOut =
  | { kind: 'progress'; read: number; total: number }
  | { kind: 'done'; found: FitbitFound }
  | { kind: 'error'; message: string };

// The DOM's `self` is the window's type; a worker's postMessage takes no target origin.
const scope = self as unknown as { postMessage(m: FitbitWorkerOut): void; onmessage: ((e: MessageEvent<FitbitWorkerIn>) => void) | null };

scope.onmessage = async (e) => {
  try {
    const found = await readFitbitFiles(e.data.inputs, e.data.timeZone, (p) => scope.postMessage({ kind: 'progress', ...p }));
    scope.postMessage({ kind: 'done', found });
  } catch (err) {
    scope.postMessage({ kind: 'error', message: err instanceof ZipError ? err.message : "This export couldn't be read. Choose the .zip from Takeout, or its unzipped folder." });
  }
};
