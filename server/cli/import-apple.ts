// Usage: npm run import:apple -- ~/Downloads/export.zip
import path from 'node:path';
import { importAppleHealth } from '../apple/import.ts';
import { getDb } from '../db.ts';

const file = process.argv[2];
if (!file) {
  console.error('Usage: npm run import:apple -- <path to export.zip or export.xml>');
  process.exit(1);
}

const started = Date.now();
let lastPrint = 0;
const result = await importAppleHealth(getDb(), path.resolve(file), ({ bytesRead, totalBytes, records }) => {
  if (Date.now() - lastPrint < 500) return;
  lastPrint = Date.now();
  const pct = totalBytes ? ` ${Math.min(100, Math.round((bytesRead / totalBytes) * 100))}%` : '';
  process.stdout.write(`\rReading export.xml…${pct}  ${records.toLocaleString()} records`);
});
process.stdout.write('\n');
console.log(
  `Imported ${result.records.toLocaleString()} records covering ${result.days} days (${result.firstDate} → ${result.lastDate}), ` +
    `${result.workouts} workouts, in ${((Date.now() - started) / 1000).toFixed(1)}s.`,
);
