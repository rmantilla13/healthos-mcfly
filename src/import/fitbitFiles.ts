// The chosen export, file by file: each .zip's wanted entries (src/import/zip.ts), or the files of an unzipped folder,
// read as text and handed to the FitbitReader. Runs in the worker (fitbit.worker.ts), or here when workers can't.
import { FitbitReader, type FitbitFound, fitbitFileKind } from './fitbit.ts';
import { ZipError, listZip, readZipText } from './zip.ts';

/** A chosen file, and where it sits in a chosen folder ("Takeout/Fitbit/Global Export Data/…"); its name otherwise. */
export type FitbitInput = { file: File; path: string };
export type FitbitProgress = { read: number; total: number };

type Job = { path: string; text: () => Promise<string> };

export async function readFitbitFiles(inputs: FitbitInput[], timeZone: string, onProgress: (p: FitbitProgress) => void): Promise<FitbitFound> {
  const jobs: Job[] = [];
  for (const { file, path } of inputs) {
    if (/\.zip$/i.test(file.name)) {
      for (const entry of await listZip(file)) if (fitbitFileKind(entry.name)) jobs.push({ path: entry.name, text: () => readZipText(file, entry) });
    } else if (/\.(tgz|tar\.gz|tar)$/i.test(file.name)) {
      throw new ZipError('This is a .tgz archive. Open it to unpack it, then choose the folder; or export again from Takeout as a .zip.');
    } else if (fitbitFileKind(path)) jobs.push({ path, text: () => file.text() });
  }
  const reader = new FitbitReader(timeZone);
  let last = 0;
  onProgress({ read: 0, total: jobs.length });
  for (let i = 0; i < jobs.length; i++) {
    reader.add(jobs[i].path, await jobs[i].text());
    // A few updates a second is plenty for the progress line.
    if (Date.now() - last > 150 || i === jobs.length - 1) {
      last = Date.now();
      onProgress({ read: i + 1, total: jobs.length });
    }
  }
  return reader.result();
}
