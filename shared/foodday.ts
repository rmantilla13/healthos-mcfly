// One day of the food log (POST /api/nutrition/log/day {date}): the Nutrition page's Today view, for any day in the
// last year. The date goes in the body, never the address: no URL carries a date or an amount (server/nutrition.ts).
import type { FoodEntry, FoodLog, FoodValues, NutritionNumbers } from './types.ts';

export type FoodDay = {
  numbers: NutritionNumbers;
  /** Today in the person's time zone: the latest day that can be viewed. */
  today: string;
  /** The day shown. */
  date: string;
  /** That day's saved entries, by time, each as the person's setting allows. */
  entries: FoodEntry[];
  /** McFly's estimate waiting for review, whichever day it's for (one waits at a time), as in GET /api/nutrition/log. */
  drafts: FoodEntry[];
  draftBatch: string | null;
  /** The day's saved entries added up, filtered like each entry: never energy in 'no_energy', empty in 'none'. */
  balance: FoodValues;
  /**
   * The app whose totals count for this day across Nutrition ('healthOS' for this log, or a Health app such as
   * MyFitnessPal), or null when nothing was logged anywhere. Apps are never added together (server/nutrition.ts).
   */
  countedApp: string | null;
  can: FoodLog['can'];
};
