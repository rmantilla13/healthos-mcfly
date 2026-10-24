// Home's "Today's nutrition": the day from 6:00 to 21:00 as 12 segments, each tinted where something was logged (the
// food log's own entries, GET /api/nutrition/log, by their time), and McFly's orb to log the next one. Only with
// Nutrition on, and only what the person chose to see: energy only in 'all', amounts never in 'none' (the server
// leaves them out anyway). Off, it's the same empty card, and the orb opens Nutrition, which explains it and offers
// to turn it on. Empty segments stay plain: a tint always means something was logged then.
import { useId } from 'react';
import type { FoodEntry, FoodLog, NutritionNumbers } from '../../../shared/types.ts';
import { daysBetween, fmt, fmtDate, href, useApi } from '../../lib.ts';
import { Orb } from '../Orb.tsx';

const START = 6 * 60;
const SEGMENT = 75;
const SEGMENTS = 12;
const TICKS = ['6:00', '9:00', '12:00', '15:00', '18:00', '21:00'];
/** The food log keeps this many days (GET /api/nutrition/log?days=, at most 31). */
const LOG_DAYS = 31;

const minutes = (time: string) => Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5));
/** The segment a time falls in; before 6:00 counts as the first, after 21:00 as the last. */
const segmentOf = (time: string) => Math.min(SEGMENTS - 1, Math.max(0, Math.floor((minutes(time) - START) / SEGMENT)));
/** Morning, midday or later: the tint a logged segment takes, by its first entry's time. */
const partOf = (time: string) => (minutes(time) < 11 * 60 ? 'morning' : minutes(time) < 15 * 60 ? 'midday' : 'evening');
const listTimes = (ts: string[]) => (ts.length < 2 ? ts.join('') : `${ts.slice(0, -1).join(', ')} and ${ts.at(-1)}`);

/** The orb and where it goes: the food log's composer with Nutrition on (`compose=1`), Nutrition's own page while it's off. */
function LogButton({ on }: { on: boolean }) {
  return (
    <a className="home-orb-btn" href={on ? '#/nutrition?tab=log&compose=1' : href('nutrition')} aria-label={on ? 'Log food' : 'Open Nutrition'}>
      <Orb size={22} />
    </a>
  );
}

export function TodayNutritionCard({ numbers, date, today }: { numbers: NutritionNumbers | null; date: string; today: string }) {
  const on = numbers !== null;
  const titleId = useId();
  // The day Home shows, as a count of days back (never a date in the address), within what the log keeps. While
  // Nutrition is off there's nothing for any day, so it's today's invitation.
  const back = on ? Math.max(0, daysBetween(date, today)) : 0;
  const days = back + 1;
  const kept = days <= LOG_DAYS;
  const { data } = useApi<FoodLog>(on && kept ? `/nutrition/log?days=${days}` : null);
  const entries = data?.enabled ? data.entries.filter((e) => e.date === date) : [];
  const isToday = back === 0;
  const title = isToday ? "Today's nutrition" : `Nutrition · ${fmtDate(date, { weekday: 'short', month: 'short', day: 'numeric' })}`;

  const bySegment = new Map<number, FoodEntry[]>();
  for (const e of entries) bySegment.set(segmentOf(e.time), [...(bySegment.get(segmentOf(e.time)) ?? []), e]);
  const times = [...entries].sort((a, b) => a.time.localeCompare(b.time)).map((e) => e.time);
  const label = entries.length
    ? `${entries.length} ${entries.length === 1 ? 'entry' : 'entries'} ${isToday ? 'today' : 'that day'}, at ${listTimes(times)}`
    : isToday
      ? 'Nothing logged yet today'
      : 'Nothing logged that day';

  // Energy only for people who chose to see it; the server sends none otherwise.
  const kcal = numbers === 'all' ? entries.reduce((t, e) => t + (e.values.energy_kcal ?? 0), 0) : 0;
  const latest = entries.length ? [...entries].sort((a, b) => b.time.localeCompare(a.time))[0] : null;

  return (
    <section className="card metric-cream home-nutrition" aria-labelledby={titleId}>
      <div className="home-card-head">
        <h2 id={titleId}>{title}</h2>
        <LogButton on={on} />
      </div>
      <div className="home-meal-track" role="img" aria-label={label}>
        {Array.from({ length: SEGMENTS }, (_, i) => {
          const here = bySegment.get(i);
          return <span key={i} className="home-meal-seg" data-part={here ? partOf(here[0].time) : undefined} />;
        })}
      </div>
      <div className="home-meal-ticks" aria-hidden="true">
        {TICKS.map((t) => (
          <span key={t}>{t}</span>
        ))}
      </div>
      {entries.length ? (
        <div className="home-nutrition-day">
          <p className="home-nutrition-count">
            {entries.length} {entries.length === 1 ? 'entry' : 'entries'}
            {kcal > 0 && <> · {fmt(kcal)} kcal</>}
          </p>
          {latest && (
            <p className="home-nutrition-latest">
              Latest: {latest.name}, {latest.time}
            </p>
          )}
        </div>
      ) : (
        <div className="home-card-empty">
          {on && !kept ? (
            <>
              <p className="home-card-empty-title">Older than a month</p>
              <p>Home shows the last 31 days of your food log.</p>
            </>
          ) : isToday ? (
            <>
              <p className="home-card-empty-title">A fresh start</p>
              <p>Log your first meal to see your day take shape.</p>
            </>
          ) : (
            <>
              <p className="home-card-empty-title">Nothing logged that day</p>
              <p>Meals you log appear here at the time you had them.</p>
            </>
          )}
        </div>
      )}
    </section>
  );
}
