// Usage: npm run sync:whoop [-- --full]
import { getStore } from '../db.ts';
import { requestContext } from '../query.ts';
import { isConnected, syncState, syncWhoop } from '../whoop.ts';

const db = await getStore();
if (!(await isConnected(db))) {
  console.error('WHOOP is not connected. Start the app (npm run dev) and connect it from Integrations first.');
  process.exit(1);
}
const { settings } = await requestContext(db, false);
await syncWhoop(db, { full: process.argv.includes('--full'), timeZone: settings.timeZone ?? undefined });
console.log('WHOOP sync complete:', (await syncState(db)).lastCounts);
await db.close();
