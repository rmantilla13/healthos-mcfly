// Usage: npm run sync:whoop [-- --full]
import { getDb } from '../db.ts';
import { isConnected, syncState, syncWhoop } from '../whoop.ts';

const db = getDb();
if (!isConnected(db)) {
  console.error('WHOOP is not connected. Start the app (npm run dev) and connect it from Integrations first.');
  process.exit(1);
}
await syncWhoop(db, { full: process.argv.includes('--full') });
console.log('WHOOP sync complete:', syncState.lastCounts);
