import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mapWhoop } from '../server/whoop.ts';

const H = 3_600_000;

test('maps WHOOP cycles, sleep, recovery and workouts onto local days', () => {
  const { daily, events, workouts } = mapWhoop({
    // Fell asleep 23:10 New York time on Oct 13 (03:10Z Oct 14): that cycle is Oct 14's day.
    cycles: [
      {
        id: 101,
        start: '2026-10-14T03:10:00.000Z',
        end: null,
        timezone_offset: '-04:00',
        score_state: 'SCORED',
        score: { strain: 12.4, kilojoule: 8368, average_heart_rate: 68, max_heart_rate: 171 },
      },
    ],
    sleeps: [
      {
        id: 'sleep-a',
        cycle_id: 101,
        start: '2026-10-14T03:10:00.000Z',
        end: '2026-10-14T11:00:00.000Z',
        timezone_offset: '-04:00',
        nap: false,
        score_state: 'SCORED',
        score: {
          stage_summary: {
            total_in_bed_time_milli: 7.8 * H,
            total_awake_time_milli: 0.5 * H,
            total_light_sleep_time_milli: 3.5 * H,
            total_slow_wave_sleep_time_milli: 1.8 * H,
            total_rem_sleep_time_milli: 2 * H,
          },
          respiratory_rate: 14.6,
          sleep_performance_percentage: 88,
        },
      },
      {
        id: 'nap-b',
        start: '2026-10-14T18:00:00.000Z',
        end: '2026-10-14T18:30:00.000Z',
        timezone_offset: '-04:00',
        nap: true,
        score_state: 'SCORED',
        score: {
          stage_summary: {
            total_in_bed_time_milli: 0.5 * H,
            total_awake_time_milli: 0,
            total_light_sleep_time_milli: 0.5 * H,
            total_slow_wave_sleep_time_milli: 0,
            total_rem_sleep_time_milli: 0,
          },
        },
      },
    ],
    recoveries: [
      {
        cycle_id: 101,
        sleep_id: 'sleep-a',
        created_at: '2026-10-14T11:05:00.000Z',
        score_state: 'SCORED',
        score: { user_calibrating: false, recovery_score: 71, resting_heart_rate: 52, hrv_rmssd_milli: 64.2, spo2_percentage: 96.5, skin_temp_celsius: 33.7 },
      },
      { cycle_id: 99, sleep_id: 'x', created_at: '2026-10-12T11:00:00.000Z', score_state: 'PENDING_SCORE' },
    ],
    workouts: [
      {
        id: 'w1',
        start: '2026-10-14T16:30:00.000Z',
        end: '2026-10-14T17:15:00.000Z',
        timezone_offset: '-04:00',
        sport_name: 'weightlifting',
        score_state: 'SCORED',
        score: { strain: 9.1, average_heart_rate: 128, max_heart_rate: 160, kilojoule: 1255.2 },
      },
    ],
  });

  const get = (metric: string) => daily.find((d) => d.metric === metric && d.date === '2026-10-14')?.value;
  assert.equal(get('strain'), 12.4);
  assert.equal(Math.round(get('whoop_kcal')!), 2000);
  assert.equal(get('recovery'), 71);
  assert.equal(get('hrv_rmssd'), 64.2);
  assert.equal(get('resting_hr'), 52);
  assert.equal(get('spo2'), 96.5);
  assert.equal(get('resp_rate'), 14.6);
  // 7.3h main sleep + 0.5h nap.
  assert.equal(Math.round(get('sleep_hours')! * 10) / 10, 7.8);
  assert.equal(get('sleep_deep'), 1.8);
  assert.equal(daily.filter((d) => d.metric === 'recovery').length, 1, 'unscored recoveries are skipped');

  assert.deepEqual(
    events.map((e) => [e.kind, e.start, e.date]),
    [
      ['sleep', '2026-10-13T23:10:00-04:00', '2026-10-14'],
      ['nap', '2026-10-14T14:00:00-04:00', '2026-10-14'],
    ],
  );
  assert.equal(workouts[0].sport, 'Weightlifting');
  assert.equal(workouts[0].start, '2026-10-14T12:30:00-04:00');
  assert.equal(workouts[0].duration_min, 45);
  assert.equal(Math.round(workouts[0].energy_kcal!), 300);
});
