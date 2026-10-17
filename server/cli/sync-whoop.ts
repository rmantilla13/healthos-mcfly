// Usage: npm run sync:whoop [-- --full]   (the owner's WHOOP; HEALTHOS_USER_ID=<id> for someone else)
import { OWNER_ID, getStore } from '../db.ts';
import { isConnected, syncState, syncWhoop } from '../whoop.ts';

const scope = { db: await getStore(), userId: process.env.HEALTHOS_USER_ID || OWNER_ID };
if (!(await isConnected(scope))) {
  console.error('WHOOP is not connected for this account. Connect it from Integrations first.');
  process.exit(1);
}
await syncWhoop(scope, { full: process.argv.includes('--full') });
console.log('WHOOP sync complete:', (await syncState(scope)).lastCounts);
await scope.db.close();
