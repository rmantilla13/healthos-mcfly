// Cycle tracking: estimates from a person's own history, the Apple Health import, and over HTTP who can see
// what: hidden while tracking is off, never across accounts, never in the admin view or the summary.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import type { AddressInfo } from 'node:net';
import type { CycleDay } from '../shared/types.ts';
import { importAppleHealth, parseStream } from '../server/apple/import.ts';
import { createApp } from '../server/app.ts';
import { hashPassword } from '../server/auth.ts';
import { type TempReading, analyzeCycle, cyclePhase, detectShift, logDays, parseCycleDay, toRows, upsertCycle } from '../server/cycle/index.ts';
import { type VitalRow, cycleInsights } from '../server/cycle/insights.ts';
import { addDays, todayLocal } from '../server/dates.ts';
import { OWNER_ID, deleteSource } from '../server/db.ts';
import type { McflyClient } from '../server/mcfly.ts';
import { openStore } from '../server/store.ts';

// ---------- estimates ----------

/** Five days of flow from each start. */
const periodsFrom = (...starts: string[]): CycleDay[] =>
  starts.flatMap((s) => (['medium', 'heavy', 'medium', 'light', 'light'] as const).map((flow, i) => ({ date: addDays(s, i), flow })));
const history = periodsFrom('2026-07-01', '2026-07-29', '2026-08-26');
const phaseOn = (days: CycleDay[], today: string) => cyclePhase(analyzeCycle(days, today), days, today);

test('28-day cycles give a next period with a range, ovulation and graded fertile days', () => {
  const a = analyzeCycle(history, '2026-09-10');
  assert.deepEqual(
    a.periods.map((p) => [p.start, p.end, p.days]),
    [
      ['2026-07-01', '2026-07-05', 5],
      ['2026-07-29', '2026-08-02', 5],
      ['2026-08-26', '2026-08-30', 5],
    ],
  );
  assert.deepEqual(a.cycles, [
    { start: '2026-07-01', days: 28 },
    { start: '2026-07-29', days: 28 },
  ]);
  assert.deepEqual(a.stats, { cycleDays: 28, periodDays: 5, shortest: 28, longest: 28, variation: null, regular: null, follicularDays: null, lutealDays: null });
  assert.deepEqual(a.current, { start: '2026-08-26', day: 16 });
  // Typical luteal phase (12.4 days) until this person's own shows: ovulation on day 16, the next period after 28.
  assert.deepEqual(a.estimate, {
    nextPeriod: { date: '2026-09-23', earliest: '2026-09-20', latest: '2026-09-27' },
    ovulation: '2026-09-10',
    fertile: { start: '2026-09-04', end: '2026-09-12' },
    basis: 'calendar',
    cycles: 2,
    confidence: 'low',
  });
  assert.equal(a.noEstimate, null);
  // The days before ovulation carry the most; no day is ever left as "safe", just unlisted.
  const levels = Object.fromEntries(a.fertility.map((f) => [f.date, f.level]));
  assert.equal(levels['2026-09-08'], 'high');
  assert.equal(levels['2026-09-04'], 'medium');
  assert.ok(a.fertility.every((f) => f.basis === 'estimate' && f.chance > 0 && f.chance <= 1));
  assert.deepEqual(
    a.history.map((h) => h.status),
    ['no_data', 'no_data', 'waiting'],
  );
});

test('the range narrows as regular cycles come in, and stays wide for variable ones', () => {
  const starts = (lengths: number[]) => lengths.reduce<string[]>((out, n) => [...out, addDays(out.at(-1)!, n)], ['2026-01-05']);
  const spread = (a: ReturnType<typeof analyzeCycle>) => (a.estimate ? Date.parse(a.estimate.nextPeriod.latest) - Date.parse(a.estimate.nextPeriod.earliest) : NaN) / 86_400_000;
  const regular = starts([27, 27, 27, 27, 27, 27, 27]);
  const r = analyzeCycle(periodsFrom(...regular), addDays(regular.at(-1)!, 3));
  assert.equal(r.estimate?.nextPeriod.date, addDays(regular.at(-1)!, 27), 'their own length, not the typical 29');
  assert.equal(r.estimate?.confidence, 'high');
  assert.equal(r.stats.regular, true);
  const variable = starts([24, 35, 26, 38, 25, 33, 29]);
  const v = analyzeCycle(periodsFrom(...variable), addDays(variable.at(-1)!, 3));
  assert.ok(spread(v) > spread(r) + 4, `${spread(v)} vs ${spread(r)}`);
  assert.equal(v.stats.regular, false);
  assert.equal(v.stats.variation, 13, 'the last six: 25 to 38');
});

test('before two complete cycles, the estimate leans on typical cycles and stays out of `estimate`', () => {
  const one = analyzeCycle(periodsFrom('2026-08-26'), '2026-09-10');
  // Older iPhone builds read `estimate` and would say "from your last 0 cycles": it stays null, as it always was.
  assert.equal(one.estimate, null);
  assert.equal(one.noEstimate, 'cycles');
  assert.equal(one.earlyEstimate?.cycles, 0);
  assert.equal(one.earlyEstimate?.confidence, 'low');
  assert.equal(one.earlyEstimate?.nextPeriod.date, '2026-09-24', '29.3 days on');
  assert.deepEqual(one.current, { start: '2026-08-26', day: 16 });
  // The phase can lean on it, but days to the next period only come from a full estimate.
  assert.deepEqual(phaseOn(periodsFrom('2026-08-26'), '2026-09-20'), { name: 'luteal', day: 26, nextPeriodIn: null, basis: 'estimate' });
  assert.equal(analyzeCycle(periodsFrom('2026-07-29', '2026-08-26'), '2026-09-10').estimate, null, 'one complete cycle');
  const stale = analyzeCycle(history, '2026-12-01');
  assert.equal(stale.estimate, null);
  assert.equal(stale.earlyEstimate, null);
  assert.equal(stale.noEstimate, 'stale');
  assert.equal(analyzeCycle([], '2026-09-10').noEstimate, 'cycles');
});

test('a marked first day wins over flow logged the day before; spotting and a skipped day start nothing', () => {
  const days: CycleDay[] = [
    ...periodsFrom('2026-07-01'),
    { date: '2026-07-15', spotting: true },
    { date: '2026-07-28', flow: 'light' },
    { date: '2026-07-29', flow: 'heavy', periodStart: true },
    { date: '2026-07-31', flow: 'medium' }, // after a day with nothing logged: still the same period
    { date: '2026-08-26', flow: 'none' }, // logged "no flow" isn't bleeding
  ];
  const a = analyzeCycle(days, '2026-08-27');
  assert.deepEqual(
    a.periods.map((p) => [p.start, p.end]),
    [
      ['2026-07-01', '2026-07-05'],
      ['2026-07-29', '2026-07-31'],
    ],
  );
});

test("an LH surge this cycle moves ovulation and the next period; past cycles' luteal phase is used", () => {
  // Last cycle: surge on 08-12, so ovulation 08-13 and a 12-day luteal phase before the 08-26 period.
  const past: CycleDay = { date: '2026-08-12', ovulationTest: 'lh_surge' };
  const calendar = analyzeCycle([...history, past], '2026-09-05');
  assert.deepEqual(calendar.ovulations, [{ date: '2026-08-13', basis: 'lh_test' }]);
  assert.deepEqual(
    calendar.history.map((h) => [h.status, h.follicularDays, h.lutealDays]),
    [
      ['no_data', null, null],
      ['lh_test', 16, 12],
      ['waiting', null, null],
    ],
  );
  assert.equal(calendar.estimate?.basis, 'calendar');

  const surged = analyzeCycle([...history, past, { date: '2026-09-07', ovulationTest: 'negative' }, { date: '2026-09-11', ovulationTest: 'lh_surge' }], '2026-09-14');
  assert.equal(surged.estimate?.basis, 'lh_test');
  assert.equal(surged.estimate?.confidence, 'medium');
  assert.equal(surged.estimate?.ovulation, '2026-09-12');
  assert.deepEqual(surged.estimate?.nextPeriod, { date: '2026-09-25', earliest: '2026-09-23', latest: '2026-09-27' });
  assert.deepEqual(surged.estimate?.fertile, { start: '2026-09-07', end: '2026-09-13' });
  // The day before ovulation is the most fertile, and the window closes the day after it.
  const top = surged.fertility.reduce((a, b) => (b.chance > a.chance ? b : a));
  assert.deepEqual([top.date, top.level], ['2026-09-11', 'peak']);
  assert.ok(surged.fertility.every((f) => f.basis === 'logged'));
});

// ---------- temperature ----------

const temps = (from: string, values: number[]): CycleDay[] => values.map((bbt, i) => ({ date: addDays(from, i), bbt }));
const RISING = [36.3, 36.35, 36.3, 36.25, 36.3, 36.3, 36.3, 36.4, 36.45, 36.6];

test('a sustained thermometer rise confirms ovulation on the last low day, and the estimate follows it', () => {
  const a = analyzeCycle([...history, ...temps('2026-08-31', RISING)], '2026-09-10');
  assert.equal(a.estimate?.basis, 'bbt');
  assert.equal(a.estimate?.tempSource, 'bbt');
  assert.equal(a.estimate?.confidence, 'high');
  assert.equal(a.estimate?.ovulation, '2026-09-06');
  assert.equal(a.estimate?.nextPeriod.date, '2026-09-19', 'ovulation plus the typical luteal phase');
  assert.equal(a.estimate?.fertile.end, '2026-09-07', 'the window closes once the rise confirms ovulation');
  assert.deepEqual(a.history.at(-1)?.temperature, { source: 'bbt', readings: 10, coverline: 0.05, rise: 0.18 });
  assert.equal(a.history.at(-1)?.status, 'confirmed');
  assert.equal(a.history.at(-1)?.follicularDays, 12);
});

test('the rise rules: the third reading must clear the cover line, one more confirms, and a spike is not a rise', () => {
  const at = (values: number[]) => values.map((deviation, i) => ({ date: addDays('2026-09-01', i), deviation }));
  const opts = { start: '2026-08-26', earliest: 6, rise: 0.2 };
  assert.equal(detectShift(at([0, 0.05, 0, -0.05, 0, 0, 0, 0.1, 0.15, 0.3]), opts)?.ovulation, '2026-09-07');
  // Higher, but the third isn't 0.2 °C above the cover line and nothing follows: not yet.
  assert.equal(detectShift(at([0, 0.05, 0, -0.05, 0, 0, 0.1, 0.1, 0.15]), opts), null);
  // ...a fourth reading above it confirms.
  assert.equal(detectShift(at([0, 0.05, 0, -0.05, 0, 0, 0.1, 0.1, 0.15, 0.12]), opts)?.ovulation, '2026-09-06');
  // Three high readings, then back down for the rest: a spike.
  assert.equal(detectShift(at([0, 0.05, 0, -0.05, 0, 0, 0.3, 0.3, 0.3, 0, 0, -0.05, 0, 0]), opts), null);
  // A positive LH test just before lets two readings confirm it.
  assert.equal(detectShift(at([0, 0.05, 0, -0.05, 0, 0, 0.15, 0.3]), { ...opts, lhSurge: '2026-09-06' })?.ovulation, '2026-09-06');
  assert.equal(detectShift(at([0, 0.05, 0, -0.05, 0, 0, 0.15, 0.3]), opts), null);
});

test("wearables' nightly temperatures find ovulation on their own, against the person's level on that device", () => {
  // Apple Watch reads about two degrees below the mouth, with more night-to-night noise; the rise is smaller.
  const wobble = [0.04, -0.03, 0.02, -0.05, 0.03, 0, -0.02, 0.05, -0.04, 0.01, 0.02, -0.03];
  const wrist: TempReading[] = [];
  for (let i = 0; i < 60; i++) {
    const date = addDays('2026-07-29', i);
    const cd = i < 28 ? i + 1 : i - 27; // cycle 07-29 (28 days), then 08-26
    const luteal = i < 28 ? cd > 15 : cd > 13;
    wrist.push({ date, source: 'wrist', value: 34.6 + (luteal ? 0.32 : 0) + wobble[i % wobble.length] });
  }
  const a = analyzeCycle(history, '2026-09-23', wrist);
  assert.deepEqual(
    a.history.map((h) => [h.status, h.ovulation?.date, h.temperature?.source]),
    [
      ['no_data', undefined, undefined],
      ['confirmed', '2026-08-12', 'wrist'],
      ['confirmed', '2026-09-07', 'wrist'],
    ],
  );
  assert.equal(a.history[1].lutealDays, 13);
  assert.equal(a.estimate?.tempSource, 'wrist');
  assert.ok(a.temperatures.every((t) => Math.abs(t.deviation) < 0.5), 'deviations from their own level, not °C');
});

test('readings marked as disturbed, and outliers, are left out', () => {
  const days: CycleDay[] = [...history, ...temps('2026-08-31', [36.3, 36.35, 36.3, 36.25, 36.3, 36.3, 36.3, 36.75, 36.8, 36.8])];
  // Three days of fever, with nothing after them yet, read as a rise...
  assert.equal(analyzeCycle(days, '2026-09-09').estimate?.basis, 'bbt');
  // ...until the days are marked as sick.
  const sick = days.map((d) => (d.date >= '2026-09-07' && d.date <= '2026-09-09' ? { ...d, tempDisturbed: 'sick' as const } : d));
  const a = analyzeCycle(sick, '2026-09-09');
  assert.equal(a.estimate?.basis, 'calendar');
  assert.deepEqual(
    a.temperatures.filter((t) => t.excluded).map((t) => [t.date, t.excluded]),
    [
      ['2026-09-07', 'disturbed'],
      ['2026-09-08', 'disturbed'],
      ['2026-09-09', 'disturbed'],
    ],
  );
  // One reading far from its neighbours on either side is an outlier.
  const odd = analyzeCycle([...history, ...temps('2026-08-31', [36.3, 36.35, 36.3, 37.2, 36.3, 36.3, 36.3])], '2026-09-06');
  assert.deepEqual(
    odd.temperatures.filter((t) => t.excluded).map((t) => [t.date, t.excluded]),
    [['2026-09-03', 'outlier']],
  );
  // Implausible thermometer readings aren't used at all.
  assert.equal(analyzeCycle([...history, { date: '2026-09-01', bbt: 39.5 }], '2026-09-06').temperatures.length, 0);
});

test('temperatures that keep coming with no rise push ovulation, and the next period, later', () => {
  const flat = Array.from({ length: 19 }, (_, i) => 36.3 + (i % 3 === 0 ? 0.05 : 0));
  const tracked = analyzeCycle([...history, ...temps('2026-08-27', flat)], '2026-09-14');
  const calendar = analyzeCycle(history, '2026-09-14');
  assert.ok(tracked.estimate!.ovulation > calendar.estimate!.ovulation, `${tracked.estimate!.ovulation} vs ${calendar.estimate!.ovulation}`);
  assert.ok(tracked.estimate!.nextPeriod.date > calendar.estimate!.nextPeriod.date);
  assert.ok(tracked.fertility.some((f) => f.date >= '2026-09-14'), 'still fertile days ahead while no rise has shown');
});

// ---------- where today falls ----------

test('the phase follows the cycle: menstrual, follicular, ovulatory, luteal', () => {
  // Next period estimated 09-23, ovulation 09-10, high fertility 09-06 to 09-10.
  assert.deepEqual(phaseOn(history, '2026-08-27'), { name: 'menstrual', day: 2, nextPeriodIn: 27, basis: 'logged' });
  assert.deepEqual(phaseOn(history, '2026-09-01'), { name: 'follicular', day: 7, nextPeriodIn: 22, basis: 'estimate' });
  assert.deepEqual(phaseOn(history, '2026-09-06'), { name: 'ovulatory', day: 12, nextPeriodIn: 17, basis: 'estimate' });
  assert.deepEqual(phaseOn(history, '2026-09-15'), { name: 'luteal', day: 21, nextPeriodIn: 8, basis: 'estimate' });
  // A late period reads as due, not a negative count.
  assert.equal(phaseOn(history, '2026-09-27')?.nextPeriodIn, 0);
});

test('menstrual needs bleeding logged this period; an LH surge makes the luteal phase logged; no cycle, no phase', () => {
  const two = periodsFrom('2026-07-01', '2026-07-29');
  // Only the first day logged so far: still menstrual within the usual 5 days, not after.
  const firstDay: CycleDay[] = [...two, { date: '2026-08-26', flow: 'medium' }];
  assert.equal(phaseOn(firstDay, '2026-08-29')?.name, 'menstrual');
  assert.equal(phaseOn(firstDay, '2026-09-01')?.name, 'follicular');
  // A start marked with no bleeding logged isn't a period day.
  assert.equal(phaseOn([...two, { date: '2026-08-26', periodStart: true }], '2026-08-27')?.name, 'follicular');

  const surged = [...history, { date: '2026-09-11', ovulationTest: 'lh_surge' as const }];
  assert.deepEqual(phaseOn(surged, '2026-09-12'), { name: 'ovulatory', day: 18, nextPeriodIn: 13, basis: 'logged' });
  assert.deepEqual(phaseOn(surged, '2026-09-14'), { name: 'luteal', day: 20, nextPeriodIn: 11, basis: 'logged' });

  assert.equal(phaseOn([], '2026-09-10'), null);
  assert.equal(phaseOn(history, '2026-12-01'), null, 'long past');
});

// ---------- patterns ----------

test('insights: the body after ovulation, when symptoms come, and cycles outside the usual ranges', () => {
  const starts = ['2026-03-02', '2026-03-30', '2026-04-27', '2026-05-25', '2026-06-22'];
  const days: CycleDay[] = [...periodsFrom(...starts)];
  const wrist: TempReading[] = [];
  const vitals: VitalRow[] = [];
  for (let i = 0; i < 4 * 28; i++) {
    const date = addDays(starts[0], i);
    const luteal = (i % 28) + 1 > 15;
    wrist.push({ date, source: 'wrist', value: 34.6 + (luteal ? 0.3 : 0) + (i % 3) * 0.02 });
    vitals.push({ date, metric: 'resting_hr', source: 'whoop', value: 55 + (luteal ? 3 : 0) });
    vitals.push({ date, metric: 'resting_hr', source: 'apple', value: 62 }); // fewer days: not used
    vitals.push({ date, metric: 'hrv_rmssd', source: 'whoop', value: 60 - (luteal ? 6 : 0) });
  }
  vitals.splice(vitals.findIndex((v) => v.source === 'apple'), 1);
  for (const s of starts.slice(0, 4)) {
    days.push({ date: addDays(s, 0), symptoms: ['cramps'] }, { date: addDays(s, 1), symptoms: ['cramps', 'fatigue'] });
    days.push({ date: addDays(s, 24), symptoms: ['breast_tenderness', 'bloating'] }, { date: addDays(s, 25), symptoms: ['breast_tenderness'] });
  }
  const today = '2026-06-25';
  const a = analyzeCycle(days, today, wrist);
  const ins = cycleInsights(a, days, vitals, today);
  assert.deepEqual(
    ins.body.slice(0, 2).map((b) => [b.metric, b.follicular, b.luteal, b.unit, b.cycles]),
    [
      ['resting_hr', 55, 58, 'bpm', 4], // WHOOP's, the device with the most days
      ['hrv', 60, 54, 'ms', 4],
    ],
  );
  const t = ins.body[2];
  assert.equal(t.metric, 'temperature');
  assert.ok(t.follicular < 0 && t.luteal > 0 && Math.abs(t.luteal - t.follicular - 0.3) < 0.03, JSON.stringify(t));
  assert.deepEqual(
    ins.symptoms.map((s) => [s.symptom, s.days, s.cycles, s.phase]),
    [
      ['breast_tenderness', 8, 4, 'luteal'],
      ['cramps', 8, 4, 'menstrual'],
      ['bloating', 4, 4, 'luteal'],
      ['fatigue', 4, 4, 'menstrual'],
    ],
  );
  assert.deepEqual(ins.deviations, []);

  // Long cycles and long periods are noted; regular ones aren't.
  const long = ['2026-01-01', '2026-02-15', '2026-04-01', '2026-05-16'];
  const longDays = [...periodsFrom(...long), ...long.flatMap((s) => [5, 6, 7, 8, 9].map((n) => ({ date: addDays(s, n), flow: 'light' as const })))];
  const d = cycleInsights(analyzeCycle(longDays, '2026-05-20'), longDays, [], '2026-05-20').deviations;
  assert.deepEqual(d, [
    { kind: 'infrequent', count: 3, of: 3 },
    { kind: 'prolonged', count: 3, of: 3 },
  ]);
});

test('symptoms and a disturbed temperature round-trip through rows, and validate', () => {
  const day: CycleDay = { date: '2026-09-01', symptoms: ['headache', 'cramps'], tempDisturbed: 'alcohol', bbt: 36.4 };
  const rows = toRows(day, 'manual');
  assert.deepEqual(
    rows.map((r) => `${r.kind}=${r.value}`),
    ['bbt=36.4', 'temp_disturbed=alcohol', 'symptom:headache=1', 'symptom:cramps=1'],
  );
  assert.deepEqual(logDays(rows), [
    { date: '2026-09-01', bbt: 36.4, tempDisturbed: 'alcohol', symptoms: ['cramps', 'headache'], manual: { bbt: 36.4, tempDisturbed: 'alcohol', symptoms: ['cramps', 'headache'] } },
  ]);
  const fail = (p: string, m: string): never => {
    throw new Error(`${p}: ${m}`);
  };
  assert.deepEqual(parseCycleDay({ date: '2026-09-01', symptoms: ['cramps', 'cramps'] }, 'b', fail), { date: '2026-09-01', symptoms: ['cramps'] });
  assert.throws(() => parseCycleDay({ date: '2026-09-01', symptoms: ['secret-symptom'] }, 'b', fail), (e: Error) => !e.message.includes('secret-symptom'));
  assert.throws(() => parseCycleDay({ date: '2026-09-01', tempDisturbed: 'hangover' }, 'b', fail), /tempDisturbed: expected one of/);
});

// ---------- Apple Health export ----------

const rec = (type: string, start: string, value: string, extra = '', children = '') =>
  `<Record type="${type}" sourceName="${extra || 'Health'}" startDate="${start} -0500" endDate="${start} -0500" value="${value}"${children ? `>${children}</Record>` : '/>'}`;
const meta = (key: string, value: string) => `<MetadataEntry key="${key}" value="${value}"/>`;

const EXPORT = `<?xml version="1.0" encoding="UTF-8"?>
<HealthData locale="en_US">
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-01 00:00:00', 'HKCategoryValueVaginalBleedingMedium', '', meta('HKMenstrualCycleStart', '1'))}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-02 00:00:00', 'HKCategoryValueMenstrualFlowHeavy', '', meta('HKMenstrualCycleStart', '0'))}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-02 08:00:00', 'HKCategoryValueMenstrualFlowLight', 'Clue')}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-03 00:00:00', '2')}
 ${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-09-05 00:00:00', 'HKCategoryValueMenstrualFlowHeavy', 'WHOOP')}
 ${rec('HKCategoryTypeIdentifierIntermenstrualBleeding', '2026-09-10 00:00:00', 'HKCategoryValueNotApplicable')}
 ${rec('HKCategoryTypeIdentifierOvulationTestResult', '2026-09-13 07:00:00', '1')}
 ${rec('HKCategoryTypeIdentifierOvulationTestResult', '2026-09-14 07:00:00', 'HKCategoryValueOvulationTestResultLuteinizingHormoneSurge')}
 ${rec('HKCategoryTypeIdentifierCervicalMucusQuality', '2026-09-14 07:00:00', 'HKCategoryValueCervicalMucusQualityEggWhite')}
 ${rec('HKCategoryTypeIdentifierSexualActivity', '2026-09-14 22:00:00', 'HKCategoryValueNotApplicable', '', meta('HKSexualActivityProtectionUsed', '0'))}
 ${rec('HKCategoryTypeIdentifierSexualActivity', '2026-09-20 22:00:00', 'HKCategoryValueNotApplicable')}
 <Record type="HKQuantityTypeIdentifierBasalBodyTemperature" sourceName="Health" unit="degF" startDate="2026-09-14 06:30:00 -0500" endDate="2026-09-14 06:30:00 -0500" value="97.7"/>
 <Record type="HKQuantityTypeIdentifierBasalBodyTemperature" sourceName="Health" unit="degF" startDate="2026-09-14 09:30:00 -0500" endDate="2026-09-14 09:30:00 -0500" value="98.6"/>
 <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-09-14 10:00:00 -0500" endDate="2026-09-14 10:05:00 -0500" value="100">${meta('HKMenstrualCycleStart', '1')}</Record>
</HealthData>`;

test('the importer reads cycle records, old and new spellings, into the cycle table only', async () => {
  const db = await openStore();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'healthos-cycle-'));
  const file = path.join(dir, 'export.xml');
  fs.writeFileSync(file, EXPORT);
  await upsertCycle(db, OWNER_ID, [{ date: '2026-09-02', kind: 'flow', source: 'manual', value: 'light' }]);
  try {
    await importAppleHealth({ db, userId: OWNER_ID }, file);
    await importAppleHealth({ db, userId: OWNER_ID }, file); // a re-import replaces, rather than doubles, Apple's rows
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  const rows = await db.query<{ date: string; kind: string; source: string; value: string }>('SELECT date, kind, source, value FROM cycle ORDER BY date, kind, source');
  assert.deepEqual(
    rows.map((r) => `${r.date} ${r.kind} ${r.source} ${r.value}`),
    [
      '2026-09-01 flow apple medium',
      '2026-09-01 period_start apple 1',
      '2026-09-02 flow apple heavy', // Health's heavy beats Clue's light the same day
      '2026-09-02 flow manual light', // what was logged by hand stays through a re-import
      '2026-09-03 flow apple light', // raw value 2
      '2026-09-10 spotting apple 1',
      '2026-09-13 ovulation_test apple negative',
      '2026-09-14 bbt apple 36.5', // the first reading of the day, in °C
      '2026-09-14 mucus apple egg_white',
      '2026-09-14 ovulation_test apple lh_surge',
      '2026-09-14 sexual_activity apple unprotected',
      '2026-09-20 sexual_activity apple unspecified',
    ],
  );
  // Steps still import, and its stray metadata didn't become a period start.
  const [steps] = await db.query<{ value: number }>("SELECT value FROM daily WHERE metric = 'steps'");
  assert.equal(steps.value, 100);
  assert.equal((await db.query("SELECT 1 FROM daily WHERE metric LIKE '%flow%' OR metric LIKE '%bbt%'")).length, 0);

  // Clearing Apple Health removes its cycle rows too, and leaves manual entries.
  await deleteSource(db, OWNER_ID, 'apple');
  assert.deepEqual(await db.query('SELECT source FROM cycle'), [{ source: 'manual' }]);
});

test("cycle days use the person's own time zone, not the export's one fixed offset", async () => {
  // Made in winter, the export prints a summer day's local midnight (00:00 CDT on Jul 2) as 23:00 the day before.
  const xml = `<HealthData>${rec('HKCategoryTypeIdentifierMenstrualFlow', '2026-07-01 23:00:00', 'HKCategoryValueVaginalBleedingLight').replace('-0500', '-0600').replace('-0500', '-0600')}</HealthData>`;
  const dates = async (timeZone?: string) => (await parseStream(Readable.from([xml]), undefined, { timeZone })).finish().cycle.map((r) => r.date);
  assert.deepEqual(await dates('America/Chicago'), ['2026-07-02']);
  assert.deepEqual(await dates(), ['2026-07-01'], 'without a saved zone, the export offset is all there is');
});

// ---------- over HTTP ----------

process.env.SESSION_SECRET = 'cycle-test-secret-'.padEnd(64, 'x');
const OWNER_PASSWORD = 'owner password 123';
process.env.HEALTHOS_PASSWORD_HASH = await hashPassword(OWNER_PASSWORD);
const OWNER_INGEST = 'owner-ingest-token-0123456789';

// A fake Claude that records each request and replays scripted replies (see test/mcfly.test.ts).
type Block = { type: 'text'; text: string } | { type: 'tool_use'; id: string; name: string; input: unknown };
const reply = (content: Block[], stop_reason: string) => ({
  id: 'msg_test',
  type: 'message',
  role: 'assistant',
  model: 'claude-opus-5-5',
  content,
  stop_reason,
  stop_sequence: null,
  usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
});
let script: ReturnType<typeof reply>[] = [];
const requests: any[] = [];
const fake = {
  beta: {
    messages: {
      stream(params: unknown) {
        requests.push(structuredClone(params));
        const msg = script.shift() ?? reply([{ type: 'text', text: 'OK.' }], 'end_turn');
        let onText: ((t: string) => void) | undefined;
        return {
          on(event: string, fn: (t: string) => void) {
            if (event === 'text') onText = fn;
            return this;
          },
          async finalMessage() {
            for (const b of msg.content) if (b.type === 'text') onText?.(b.text);
            return msg;
          },
          abort() {},
        };
      },
    },
  },
} as unknown as McflyClient;

const db = await openStore();
const app = createApp({ db, hosted: false, ingestToken: OWNER_INGEST, mcflyClient: () => fake });
const server = app.listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
test.after(() => {
  server.close();
});

class Client {
  cookie = '';
  async call(method: string, p: string, body?: unknown, headers: Record<string, string> = {}) {
    const res = await fetch(base + p, {
      method,
      headers: { 'X-HealthOS': '1', 'Content-Type': 'application/json', ...(this.cookie ? { Cookie: this.cookie } : {}), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0];
    const text = await res.text();
    let json: any = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
    return { status: res.status, text, json };
  }
  get = (p: string) => this.call('GET', p);
  post = (p: string, b?: unknown) => this.call('POST', p, b ?? {});
}

const owner = new Client();
const bob = new Client();
let bobId = '';
// "Today" on the server is this machine's date: the test accounts have no time zone saved.
const today = todayLocal();
const ago = (n: number) => addDays(today, -n);
const ingest = (body: unknown) => owner.call('POST', '/api/apple/ingest', body, { Authorization: `Bearer ${OWNER_INGEST}` });

test('setup: an owner and an invited member', async () => {
  assert.equal((await owner.post('/api/auth/login', { email: 'owner@example.com', password: OWNER_PASSWORD })).status, 200);
  const inv = await owner.post('/api/admin/invites', {});
  const token = inv.json.url.split('/').at(-1);
  assert.equal((await bob.post('/api/auth/invite', { token, email: 'bob@example.com', name: 'Bob', password: 'bob password 123' })).status, 200);
  bobId = (await bob.get('/api/auth/me')).json.user.id;
});

test('while tracking is off, iPhone cycle records are stored but nothing shows them', async () => {
  const settings = (await owner.get('/api/status')).json.settings;
  assert.equal(settings.cycleTracking, false);
  assert.equal(settings.sex, null);

  const days = [56, 28, 0].flatMap((n) => [
    { date: ago(n + 2), flow: 'medium', periodStart: true },
    { date: ago(n + 1), flow: 'heavy' },
  ]);
  const res = await ingest({ cycle: [...days, { date: ago(10), ovulationTest: 'lh_surge', sexualActivity: 'protected', bbt: 36.6 }] });
  assert.equal(res.status, 200);
  assert.equal(res.json.cycle, 7);
  assert.equal((await db.query('SELECT 1 FROM cycle WHERE user_id = $1', [OWNER_ID])).length, 12); // flow and start, flow, x3; three on one day
  // The saved sync summary, shown on the Integrations page, leaves the cycle count out.
  assert.equal((await owner.get('/api/status')).json.apple.lastSync.cycle, undefined);

  const view = await owner.get('/api/cycle');
  assert.equal(view.status, 200);
  assert.equal(view.json.enabled, false);
  assert.deepEqual([view.json.days, view.json.periods, view.json.estimate], [[], [], null]);
  assert.equal((await owner.post('/api/cycle/day', { date: ago(3), flow: 'light' })).status, 403);
});

test('turning tracking on shows the history and estimates', async () => {
  const status = (await owner.call('PUT', '/api/settings', { sex: 'female', cycleTracking: true })).json;
  assert.equal(status.settings.sex, 'female');
  assert.equal(status.settings.cycleTracking, true);
  const view = (await owner.get('/api/cycle')).json;
  assert.equal(view.enabled, true);
  assert.equal(view.today, today);
  assert.equal(view.periods.length, 3);
  assert.deepEqual(
    view.cycles.map((c: { days: number }) => c.days),
    [28, 28],
  );
  assert.deepEqual(view.current, { start: ago(2), day: 3 });
  assert.equal(view.estimate.nextPeriod.date, addDays(ago(2), 28));
  const tested = view.days.find((d: CycleDay) => d.date === ago(10));
  assert.deepEqual(tested, { date: ago(10), ovulationTest: 'lh_surge', sexualActivity: 'protected', bbt: 36.6, apple: { ovulationTest: 'lh_surge', sexualActivity: 'protected', bbt: 36.6 } });
});

test('the cycle view says where today falls, and nothing while tracking is off', async () => {
  // Two days of bleeding logged per period, and today is day 3: past this person's usual period length.
  assert.deepEqual((await owner.get('/api/cycle')).json.phase, { name: 'follicular', day: 3, nextPeriodIn: 26, basis: 'estimate' });
  assert.equal((await bob.get('/api/cycle')).json.phase, null);
});

test('entries made by hand override Apple Health field by field, and validate without echoing values', async () => {
  assert.equal((await owner.post('/api/cycle/day', { date: ago(1), flow: 'light', mucus: 'creamy' })).status, 200);
  let day = (await owner.get('/api/cycle')).json.days.find((d: CycleDay) => d.date === ago(1));
  assert.deepEqual(day, { date: ago(1), flow: 'light', mucus: 'creamy', apple: { flow: 'heavy' }, manual: { flow: 'light', mucus: 'creamy' } });

  // The body is the day's whole manual entry: sending the date alone clears it, and Apple's value shows again.
  assert.equal((await owner.post('/api/cycle/day', { date: ago(1) })).status, 200);
  day = (await owner.get('/api/cycle')).json.days.find((d: CycleDay) => d.date === ago(1));
  assert.deepEqual(day, { date: ago(1), flow: 'heavy', apple: { flow: 'heavy' } });

  const bad = await owner.post('/api/cycle/day', { date: ago(1), flow: 'gushing-secret' });
  assert.equal(bad.status, 400);
  assert.ok(!bad.text.includes('gushing-secret'));
  assert.equal((await owner.post('/api/cycle/day', { date: ago(1), bbt: 98.6 })).status, 400, 'bbt is °C');
  assert.equal((await owner.post('/api/cycle/day', { date: addDays(today, 1), flow: 'light' })).status, 400);
  assert.equal((await owner.post('/api/cycle/day', { date: '2026-02-30', flow: 'light' })).status, 400);
});

test('an iPhone push replaces its own days and leaves manual entries alone', async () => {
  await owner.post('/api/cycle/day', { date: ago(10), spotting: true });
  assert.equal((await ingest({ cycle: [{ date: ago(10) }] })).status, 200);
  const day = (await owner.get('/api/cycle')).json.days.find((d: CycleDay) => d.date === ago(10));
  assert.deepEqual(day, { date: ago(10), spotting: true, manual: { spotting: true } });
  const bad = await ingest({ cycle: [{ date: ago(1), flow: 'torrent' }] });
  assert.equal(bad.status, 400);
  assert.match(bad.json.error, /^cycle\[0\]\.flow: expected one of/);
});

test("nobody else sees a person's cycle data: not another member, not the admin view, not the summary", async () => {
  assert.equal((await bob.get('/api/cycle')).json.enabled, false);
  await bob.call('PUT', '/api/settings', { cycleTracking: true });
  const empty = (await bob.get('/api/cycle')).json;
  assert.equal(empty.enabled, true);
  assert.deepEqual(empty.days, []);
  assert.equal((await bob.post('/api/cycle/day', { date: ago(4), flow: 'medium' })).status, 200);
  assert.deepEqual(
    (await bob.get('/api/cycle')).json.days.map((d: CycleDay) => d.date),
    [ago(4)],
  );
  assert.ok(!(await owner.get('/api/cycle')).json.days.some((d: CycleDay) => d.date === ago(4) && d.flow === 'medium'));

  const overview = (await owner.get('/api/admin/overview')).text;
  for (const word of ['flow', 'heavy', 'lh_surge', 'sexual', 'protected', 'cycle', 'female', 'mucus']) assert.ok(!overview.includes(word), word);
  const summary = (await owner.get('/api/summary')).text;
  for (const word of ['heavy', 'lh_surge', 'protected', 'mucus', 'spotting']) assert.ok(!summary.includes(word), word);
  assert.equal((await bob.get('/api/admin/overview')).status, 403);
});

test("the view reads the Watch's nightly temperatures and logged symptoms, for that person only", async () => {
  // Apple Watch wrist temperature arrives with the iPhone's daily metrics, never as a cycle record.
  const nights = Array.from({ length: 12 }, (_, i) => ({ date: ago(14 - i), metric: 'wrist_temp', value: 34.6 + (i % 3) * 0.03 }));
  assert.equal((await ingest({ daily: nights })).status, 200);
  assert.equal((await owner.post('/api/cycle/day', { date: ago(3), symptoms: ['cramps', 'headache'], tempDisturbed: 'alcohol' })).status, 200);
  const view = (await owner.get('/api/cycle')).json;
  const wrist = view.temperatures.filter((t: { source: string }) => t.source === 'wrist');
  assert.equal(wrist.length, 12);
  assert.equal(wrist.find((t: { date: string }) => t.date === ago(3)).excluded, 'disturbed');
  assert.deepEqual(view.days.find((d: CycleDay) => d.date === ago(3)).symptoms, ['cramps', 'headache']);
  assert.equal(view.history.at(-2).temperature.source, 'wrist', 'the nights fall in the cycle before this one');
  assert.ok(view.insights && Array.isArray(view.insights.body));
  // Bob tracks his cycle too, and sees none of it.
  const bobs = (await bob.get('/api/cycle')).json;
  assert.deepEqual(bobs.temperatures, []);
  // The summary still carries nothing from the cycle log.
  const summary = (await owner.get('/api/summary')).text;
  for (const word of ['cramps', 'headache', 'alcohol', 'fertil', 'ovulation']) assert.ok(!summary.includes(word), word);
});

test('Ask McFly gets the cycle tool only while tracking is on, and it reads only the asker', async () => {
  await owner.post('/api/cycle/day', { date: ago(5), bbt: 36.6 });
  await owner.call('PUT', '/api/settings', { units: 'imperial' });
  requests.length = 0;
  script = [
    reply([{ type: 'tool_use', id: 'tu_1', name: 'get_cycle', input: { days: 120 } }], 'tool_use'),
    reply([{ type: 'text', text: 'Your next period is estimated around then.' }], 'end_turn'),
  ];
  assert.equal((await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'When is my next period?' }] })).status, 200);
  assert.ok(requests[0].tools.some((t: { name: string }) => t.name === 'get_cycle'));
  assert.match(requests[0].system, /menstrual cycle/);
  const result = JSON.parse(requests[1].messages.at(-1).content[0].content);
  assert.equal(result.periods.length, 3);
  assert.equal(result.estimate.nextPeriod.date, addDays(ago(2), 28));
  assert.ok(!result.entries.some((d: CycleDay) => d.date === ago(4) && d.flow === 'medium'), "Bob's entry isn't in the owner's answer");
  assert.deepEqual(result.entries.find((d: { basalTemp?: unknown }) => d.basalTemp)?.basalTemp, { value: 97.88, unit: '°F' }, 'in their units');

  await owner.call('PUT', '/api/settings', { cycleTracking: false });
  requests.length = 0;
  script = [];
  await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'When is my next period?' }] });
  assert.ok(!requests[0].tools.some((t: { name: string }) => t.name === 'get_cycle'));
  assert.doesNotMatch(requests[0].system, /menstrual/);
  // A model that asks for the tool anyway gets "unknown tool", not data.
  requests.length = 0;
  script = [reply([{ type: 'tool_use', id: 'tu_2', name: 'get_cycle', input: {} }], 'tool_use'), reply([{ type: 'text', text: 'OK.' }], 'end_turn')];
  await owner.post('/api/mcfly/chat', { messages: [{ role: 'user', content: 'Read my cycle.' }] });
  const refused = requests[1].messages.at(-1).content[0];
  assert.equal(refused.is_error, true);
  assert.match(refused.content, /Unknown tool/);
});

test('delete removes all of one person’s cycle data, whether tracking is on or off', async () => {
  const deleted = await owner.post('/api/cycle/delete');
  assert.equal(deleted.status, 200);
  assert.ok(deleted.json.deleted > 0);
  assert.equal((await db.query('SELECT 1 FROM cycle WHERE user_id = $1', [OWNER_ID])).length, 0);
  assert.equal((await db.query('SELECT 1 FROM cycle WHERE user_id = $1', [bobId])).length, 1, "Bob's stays");

  // Deleting an account takes its cycle data with it.
  assert.equal((await owner.call('DELETE', `/api/admin/users/${bobId}`)).status, 200);
  assert.equal((await db.query('SELECT 1 FROM cycle')).length, 0);
});
