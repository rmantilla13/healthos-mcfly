// The nutrients healthOS keeps, their ceilings, and what a person's numbers setting lets them see. Apart from
// server/nutrition.ts so the food log (server/foodlog.ts) can share them without a circular import.
import type { Nutrient, NutritionNumbers } from '../shared/types.ts';

/** In the order they're shown. Daily totals: energy in kcal, masses in g except sodium (mg), alcohol in drinks. */
export const NUTRIENTS: readonly Nutrient[] = ['energy_kcal', 'protein_g', 'carbs_g', 'fat_g', 'fiber_g', 'sugar_g', 'sat_fat_g', 'sodium_mg', 'alcohol_drinks'];

/** Above any real day's total: a bigger number is a unit mix-up, not a meal. */
export const NUTRIENT_MAX: Record<Nutrient, number> = {
  energy_kcal: 30_000,
  protein_g: 2_000,
  carbs_g: 3_000,
  fat_g: 2_000,
  fiber_g: 500,
  sugar_g: 2_000,
  sat_fat_g: 1_000,
  sodium_mg: 50_000,
  alcohol_drinks: 100,
};

export const isNutrient = (v: unknown): v is Nutrient => typeof v === 'string' && (NUTRIENTS as readonly string[]).includes(v);

/** What a person sees of one day's values: the setting decides, here, before anything leaves the server. */
export function shown(values: Partial<Record<Nutrient, number>>, numbers: NutritionNumbers): Partial<Record<Nutrient, number>> {
  if (numbers === 'none') return {};
  const out: Partial<Record<Nutrient, number>> = {};
  for (const n of NUTRIENTS) {
    if (numbers === 'no_energy' && n === 'energy_kcal') continue;
    const v = values[n];
    if (v !== undefined) out[n] = Math.round(v * 10) / 10;
  }
  return out;
}
