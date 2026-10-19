// Sleep stages through the night: the timeline the importer (and, ported, the iPhone app) builds from one
// source's samples, and how POST /api/apple/ingest stores it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { Readable } from 'node:stream';
import express from 'express';
import { ingestRouter } from '../server/apple/ingest.ts';
import { parseStream } from '../server/apple/import.ts';
import { type Db, OWNER_ID, upsertDaily } from '../server/db.ts';
import { openStore } from '../server/store.ts';

function sleepXml(records: [source: string, stage: string, start: string, end: string][]) {
  const rows = records.map(
    ([src, stage, start, end]) =>
      `<Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="${src}" startDate="2026-10-${start} -0700" endDate="2026-10-${end} -0700" value="HKCategoryValueSleepAnalysis${stage}"/>`,
  );
  return `<?xml version="1.0"?><HealthData>${rows.join('')}</HealthData>`;
}

async function parse(xml: string) {
  return (await parseStream(Readable.from([Buffer.from(xml)]))).finish();
}
const minutes = (s: { start: string; end: string }) => (Date.parse(s.end) - Date.parse(s.start)) / 60_000;
const clock = (iso: string) => iso.slice(11, 16);

test("a night's timeline: one stage at a time, time in bed only where nothing else was recorded, stages adding up to the totals", async () => {
  const { daily, sleepStages } = await parse(
    sleepXml([
      // In bed covers the whole night, as the iPhone writes it; here the same source wrote it.
      ['Watch', 'InBed', '14 22:00:00', '15 06:30:00'],
      ['Watch', 'AsleepCore', '14 22:20:00', '15 00:00:00'],
      ['Watch', 'AsleepDeep', '15 00:00:00', '15 01:00:00'],
      // An overlapping copy of the same stretch counts once.
      ['Watch', 'AsleepDeep', '15 00:30:00', '15 01:00:00'],
      ['Watch', 'AsleepCore', '15 01:00:00', '15 03:00:00'],
      ['Watch', 'Awake', '15 03:00:00', '15 03:10:00'],
      ['Watch', 'AsleepREM', '15 03:10:00', '15 04:00:00'],
      // Two stretches of the same stage meeting end to end are one.
      ['Watch', 'AsleepCore', '15 04:00:00', '15 05:00:00'],
      ['Watch', 'AsleepCore', '15 05:00:00', '15 06:00:00'],
    ]),
  );
  assert.equal(sleepStages.length, 1);
  const night = sleepStages[0];
  assert.equal(night.date, '2026-10-15');
  assert.deepEqual(
    night.segments.map((g) => `${clock(g.start)}-${clock(g.end)} ${g.stage}`),
    ['22:00-22:20 in_bed', '22:20-00:00 light', '00:00-01:00 deep', '01:00-03:00 light', '03:00-03:10 awake', '03:10-04:00 rem', '04:00-06:00 light', '06:00-06:30 in_bed'],
  );
  // Never overlapping.
  for (let i = 1; i < night.segments.length; i++) assert.ok(night.segments[i].start >= night.segments[i - 1].end);
  // Each stage's stretches add up to that stage's total for the night.
  const total = (stage: string) => night.segments.filter((g) => g.stage === stage).reduce((a, g) => a + minutes(g), 0) / 60;
  const value = (metric: string) => daily.find((d) => d.metric === metric)!.value;
  for (const [stage, metric] of [['deep', 'sleep_deep'], ['rem', 'sleep_rem'], ['light', 'sleep_light'], ['awake', 'sleep_awake']]) {
    assert.equal(Math.round(total(stage) * 1000), Math.round(value(metric) * 1000), stage);
  }
});

test("a same-day nap counts in the totals but isn't drawn: the timeline is the main sleep", async () => {
  const { daily, sleepStages } = await parse(
    sleepXml([
      ['Watch', 'AsleepCore', '14 23:00:00', '15 03:00:00'],
      ['Watch', 'AsleepDeep', '15 03:00:00', '15 04:00:00'],
      ['Watch', 'AsleepCore', '15 04:00:00', '15 07:00:00'],
      ['Watch', 'AsleepCore', '15 14:00:00', '15 14:40:00'],
    ]),
  );
  const segs = sleepStages[0].segments;
  assert.equal(clock(segs[0].start), '23:00');
  assert.equal(clock(segs.at(-1)!.end), '07:00');
  // So the drawn light sleep is 40 minutes short of the day's light sleep: the nap's.
  const light = segs.filter((g) => g.stage === 'light').reduce((a, g) => a + minutes(g), 0);
  assert.equal(light, 7 * 60);
  assert.equal(Math.round(daily.find((d) => d.metric === 'sleep_light')!.value * 60), 7 * 60 + 40);
});

test('the timeline comes from the source that won the night; unspecified sleep is "asleep"; slivers fold in', async () => {
  const { sleepStages } = await parse(
    sleepXml([
      ['Watch', 'AsleepCore', '14 23:00:00', '15 06:00:00'],
      ['Watch', 'AsleepDeep', '15 01:00:00', '15 01:00:30'],
      ['OtherApp', 'AsleepUnspecified', '14 23:30:00', '15 05:00:00'],
    ]),
  );
  assert.deepEqual(
    sleepStages[0].segments.map((g) => g.stage),
    ['light'],
    'the Watch had the most sleep; its 30-second deep sliver joins the light around it',
  );
  const other = await parse(sleepXml([['OldWatch', 'Asleep', '14 23:00:00', '15 06:00:00']]));
  assert.deepEqual(other.sleepStages[0].segments.map((g) => g.stage), ['asleep']);
});

// ---------- ingest ----------

const TOKEN = 'test-token-0123456789abcdef';

async function serve(db: Db, fn: (post: (body: unknown) => Promise<Response>) => Promise<void>) {
  const app = express();
  app.use('/api', ingestRouter(db, TOKEN));
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/api/apple/ingest`;
  try {
    await fn((body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` }, body: JSON.stringify(body) }));
  } finally {
    server.close();
  }
}

const stored = (db: Db, date: string) =>
  db.query<{ start: string; end: string; stage: string; source: string }>('SELECT start, "end", stage, source FROM sleep_stages WHERE user_id = $1 AND date = $2 ORDER BY start', [OWNER_ID, date]);
const seg = (start: string, end: string, stage: string) => ({ start: `2026-10-15T${start}:00-07:00`, end: `2026-10-15T${end}:00-07:00`, stage });

test('ingest stores each night it is sent, replacing it; an empty night clears it; bad stretches are left out', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  await serve(db, async (post) => {
    // An empty push says the server stores stages.
    assert.equal(((await (await post({})).json()) as { sleepStages: number }).sleepStages, 0);

    const first = await post({ sleepStages: [{ date: '2026-10-15', segments: [seg('01:00', '02:00', 'deep'), seg('00:00', '01:00', 'light')] }] });
    assert.equal(first.status, 200);
    assert.equal(((await first.json()) as { sleepStages: number }).sleepStages, 1);
    assert.deepEqual((await stored(db, '2026-10-15')).map((r) => [r.stage, r.source]), [['light', 'apple'], ['deep', 'apple']]);

    // Sent again, the night is the phone's whole night: the old stretches go.
    await post({
      sleepStages: [
        {
          date: '2026-10-15',
          segments: [
            seg('00:00', '03:00', 'light'),
            seg('02:00', '02:30', 'rem'), // overlaps the one before: left out
            seg('03:00', '03:00', 'awake'), // empty: left out
            seg('03:00', '04:00', 'rem'),
          ],
        },
      ],
    });
    assert.deepEqual((await stored(db, '2026-10-15')).map((r) => r.stage), ['light', 'rem']);

    await post({ sleepStages: [{ date: '2026-10-15', segments: [] }] });
    assert.equal((await stored(db, '2026-10-15')).length, 0);

    // A wrong shape fails the request, and with it nothing else in it is written.
    const bad = await post({ daily: [{ date: '2026-10-15', metric: 'steps', value: 1 }], sleepStages: [{ date: '2026-10-15', segments: [seg('00:00', '01:00', 'dozing')] }] });
    assert.equal(bad.status, 400);
    assert.match(((await bad.json()) as { error: string }).error, /sleepStages\[0\]\.segments\[0\]\.stage/);
    assert.equal((await db.query('SELECT 1 FROM daily')).length, 0);
  });
});

test('an export import fills the stages too, so replacing Apple data keeps the nights drawn', async (t) => {
  const db = await openStore();
  t.after(() => db.close());
  const { importAppleHealth } = await import('../server/apple/import.ts');
  const { mkdtemp, writeFile } = await import('node:fs/promises');
  const path = await import('node:path');
  const os = await import('node:os');
  const dir = await mkdtemp(path.join(os.tmpdir(), 'healthos-stages-'));
  const file = path.join(dir, 'export.xml');
  await writeFile(file, sleepXml([['Watch', 'AsleepCore', '14 23:00:00', '15 02:00:00'], ['Watch', 'AsleepDeep', '15 02:00:00', '15 03:00:00']]));
  await upsertDaily(db, OWNER_ID, [{ date: '2026-10-15', metric: 'steps', source: 'apple', value: 1 }]);
  await importAppleHealth({ db, userId: OWNER_ID }, file);
  assert.deepEqual((await stored(db, '2026-10-15')).map((r) => r.stage), ['light', 'deep']);
});
