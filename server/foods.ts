// Food databases (/api/nutrition/foods): USDA FoodData Central (generic foods and US brands; CC0, a key kept on the
// server as FDC_API_KEY, sent in a header so it never sits in a URL) and Open Food Facts (packaged foods worldwide;
// ODbL, no key). The server calls them, so the browser and the iPhone never talk to either: they see the search
// words or the barcode and the server's address, never who asked. Searches and barcodes arrive in a POST body,
// never a URL, and are never logged or stored; only the foods found are kept, in food_cache, shared by everyone.
// Open Food Facts allows few calls a minute per address, so a slow or refused call just leaves its results out.
import { createHash } from 'node:crypto';
import express, { type Request, type Response } from 'express';
import type { FoodResult, FoodSearch, FoodValues, Nutrient, NutritionNumbers } from '../shared/types.ts';
import { HttpError, currentUser } from './auth.ts';
import { type Db, type Queryable } from './db.ts';
import { NUTRIENT_MAX } from './nutrients.ts';

/** A food as healthOS keeps it: amounts per 100 g (or mL), and the portions people pick from. */
export type Food = {
  ref: string;
  name: string;
  brand: string | null;
  source: 'usda' | 'off';
  per100: FoodValues;
  portions: { label: string; grams: number }[];
};

export type FetchFn = (url: string, init?: RequestInit) => Promise<globalThis.Response>;

const USDA = 'https://api.nal.usda.gov/fdc/v1';
const OFF_PRODUCT = 'https://world.openfoodfacts.org/api/v3/product';
const OFF_SEARCH = 'https://search.openfoodfacts.org/search';
/** Open Food Facts asks every caller to name itself. */
const USER_AGENT = 'healthOS/1.0 (+https://health.mcfly.bot)';
const OFF_FIELDS = 'code,product_name,brands,nutriments,serving_size,serving_quantity,quantity,product_quantity_unit';
const TIMEOUT_MS = { usda: 6_000, off: 4_000 };
/** A standard US drink is 14 g of alcohol; ethanol weighs 0.789 g per mL. */
const DRINK_G = 14;
const ETHANOL_G_PER_ML = 0.789;

// ---------- the shared cache ----------

export async function cachedFood(q: Queryable, ref: string): Promise<Food | null> {
  if (!/^(fdc|off):[0-9]{1,14}$/.test(ref)) return null;
  const [row] = await q.query<{ data: string }>('SELECT data FROM food_cache WHERE ref = $1', [ref]);
  if (!row) return null;
  try {
    const food = JSON.parse(row.data) as Food;
    return food.ref === ref && Array.isArray(food.portions) && food.portions.length ? food : null;
  } catch {
    return null;
  }
}

async function cacheFoods(q: Queryable, foods: Food[]) {
  const now = Date.now();
  for (const f of foods) {
    await q.query('INSERT INTO food_cache (ref, data, fetched_at) VALUES ($1, $2, $3) ON CONFLICT (ref) DO UPDATE SET data = excluded.data, fetched_at = excluded.fetched_at', [
      f.ref,
      JSON.stringify(f),
      now,
    ]);
  }
}

/** Which food a barcode was found as, so the next scan needs no network. */
async function cachedBarcode(q: Queryable, gtin: string): Promise<Food | null> {
  const [row] = await q.query<{ data: string }>('SELECT data FROM food_cache WHERE ref = $1', [`gtin:${gtin}`]);
  if (!row) return null;
  try {
    const { ref } = JSON.parse(row.data) as { ref?: unknown };
    return typeof ref === 'string' ? cachedFood(q, ref) : null;
  } catch {
    return null;
  }
}

async function rememberBarcode(q: Queryable, gtin: string, ref: string) {
  await q.query('INSERT INTO food_cache (ref, data, fetched_at) VALUES ($1, $2, $3) ON CONFLICT (ref) DO UPDATE SET data = excluded.data, fetched_at = excluded.fetched_at', [
    `gtin:${gtin}`,
    JSON.stringify({ ref }),
    Date.now(),
  ]);
}

// ---------- amounts ----------

/** One portion's amounts, from the food's per-100 amounts. */
export function portionValues(food: Food, index: number): FoodValues {
  const grams = food.portions[index].grams;
  const out: FoodValues = {};
  for (const [k, v] of Object.entries(food.per100) as [Nutrient, number][]) out[k] = (v * grams) / 100;
  return out;
}

/** A value kept only when it's a real number in range; per 100 g, nothing has more than 900 kcal (pure fat). */
function put(out: FoodValues, key: Nutrient, value: unknown) {
  const v = typeof value === 'string' ? Number(value) : value;
  if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > NUTRIENT_MAX[key]) return;
  if (key === 'energy_kcal' && v > 950) return;
  if (key !== 'energy_kcal' && key !== 'sodium_mg' && key !== 'alcohol_drinks' && v > 100) return;
  out[key] = v;
}

const round1 = (n: number) => Math.round(n * 10) / 10;

/** Database names are often in capitals ("CHEDDAR CHEESE"): those read better in sentence case. */
function tidyName(s: string) {
  const t = s.replace(/\s+/g, ' ').trim();
  return t === t.toUpperCase() && /[A-Z]/.test(t) ? t.charAt(0) + t.slice(1).toLowerCase() : t;
}

const label100 = (unit: 'g' | 'ml') => ({ label: unit === 'ml' ? '100 mL' : '100 g', grams: 100 });

// ---------- USDA FoodData Central ----------

type UsdaFood = {
  fdcId?: unknown;
  description?: unknown;
  dataType?: unknown;
  brandName?: unknown;
  brandOwner?: unknown;
  gtinUpc?: unknown;
  servingSize?: unknown;
  servingSizeUnit?: unknown;
  householdServingFullText?: unknown;
  foodMeasures?: { disseminationText?: unknown; gramWeight?: unknown; rank?: unknown }[];
  foodNutrients?: { nutrientId?: unknown; unitName?: unknown; value?: unknown }[];
};

const USDA_IDS: Record<number, Nutrient> = { 1003: 'protein_g', 1005: 'carbs_g', 1004: 'fat_g', 1079: 'fiber_g', 2000: 'sugar_g', 1258: 'sat_fat_g' };

/** A search result as a Food. Search results give every food type's amounts per 100 g (or 100 mL for drinks). */
export function usdaFood(f: UsdaFood): Food | null {
  if (typeof f.fdcId !== 'number' || !Number.isInteger(f.fdcId) || typeof f.description !== 'string' || !f.description.trim()) return null;
  const byId = new Map<number, { unit: string; value: unknown }>();
  for (const n of f.foodNutrients ?? []) if (typeof n.nutrientId === 'number') byId.set(n.nutrientId, { unit: String(n.unitName ?? '').toUpperCase(), value: n.value });
  const per100: FoodValues = {};
  // Energy: kcal; Foundation foods may report it only as Atwater energy.
  for (const id of [1008, 2047, 2048]) {
    const e = byId.get(id);
    if (e && e.unit === 'KCAL') {
      put(per100, 'energy_kcal', e.value);
      if (per100.energy_kcal !== undefined) break;
    }
  }
  for (const [id, key] of Object.entries(USDA_IDS)) {
    const n = byId.get(Number(id));
    if (n && n.unit === 'G') put(per100, key, n.value);
  }
  const sodium = byId.get(1093);
  if (sodium) put(per100, 'sodium_mg', sodium.unit === 'G' ? Number(sodium.value) * 1000 : sodium.value);
  const alcohol = byId.get(1018);
  if (alcohol && alcohol.unit === 'G' && Number(alcohol.value) > 0) put(per100, 'alcohol_drinks', Number(alcohol.value) / DRINK_G);
  if (!Object.keys(per100).length) return null;

  const branded = f.dataType === 'Branded';
  const sizeUnit = String(f.servingSizeUnit ?? '').toLowerCase();
  const unit: 'g' | 'ml' = branded && (sizeUnit === 'ml' || sizeUnit === 'mlt') ? 'ml' : 'g';
  const portions: Food['portions'] = [];
  if (branded && typeof f.servingSize === 'number' && f.servingSize > 0 && f.servingSize <= 5000 && ['g', 'grm', 'ml', 'mlt'].includes(sizeUnit)) {
    const size = `${round1(f.servingSize)} ${unit === 'ml' ? 'mL' : 'g'}`;
    const household = typeof f.householdServingFullText === 'string' ? f.householdServingFullText.trim().toLowerCase() : '';
    portions.push({ label: household ? `${household} (${size})` : `1 serving (${size})`, grams: f.servingSize });
  }
  const measures = (f.foodMeasures ?? [])
    .filter((m) => typeof m.disseminationText === 'string' && m.disseminationText.trim() && typeof m.gramWeight === 'number' && m.gramWeight > 0 && m.gramWeight <= 5000)
    .filter((m) => !/quantity not specified/i.test(String(m.disseminationText)))
    .sort((a, b) => Number(a.rank ?? 99) - Number(b.rank ?? 99))
    .slice(0, 6);
  for (const m of measures) portions.push({ label: `${String(m.disseminationText).trim()} (${round1(Number(m.gramWeight))} g)`, grams: Number(m.gramWeight) });
  portions.push(label100(unit));
  if (unit === 'g' && !portions.some((p) => p.grams === 28.35)) portions.push({ label: '1 oz (28.35 g)', grams: 28.35 });

  const brand = typeof f.brandName === 'string' && f.brandName.trim() ? f.brandName : typeof f.brandOwner === 'string' && f.brandOwner.trim() ? f.brandOwner : null;
  return {
    ref: `fdc:${f.fdcId}`,
    name: tidyName(f.description).slice(0, 120),
    brand: brand ? tidyName(brand).slice(0, 80) : null,
    source: 'usda',
    per100,
    portions,
  };
}

async function usdaSearch(fetchFn: FetchFn, key: string, body: Record<string, unknown>): Promise<UsdaFood[]> {
  const res = await fetchFn(`${USDA}/foods/search`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Api-Key': key },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TIMEOUT_MS.usda),
  });
  if (!res.ok) throw new Error(`usda ${res.status}`);
  const data = (await res.json()) as { foods?: unknown };
  return Array.isArray(data.foods) ? (data.foods as UsdaFood[]) : [];
}

// ---------- Open Food Facts ----------

type OffProduct = {
  code?: unknown;
  product_name?: unknown;
  brands?: unknown;
  nutriments?: Record<string, unknown>;
  serving_size?: unknown;
  serving_quantity?: unknown;
  quantity?: unknown;
  product_quantity_unit?: unknown;
};

export function offFood(p: OffProduct): Food | null {
  const code = typeof p.code === 'string' ? p.code : typeof p.code === 'number' ? String(p.code) : '';
  if (!/^\d{1,14}$/.test(code) || typeof p.product_name !== 'string' || !p.product_name.trim()) return null;
  const n = p.nutriments ?? {};
  const per100: FoodValues = {};
  put(per100, 'energy_kcal', n['energy-kcal_100g'] ?? (typeof n.energy_100g === 'number' ? n.energy_100g / 4.184 : undefined));
  put(per100, 'protein_g', n.proteins_100g);
  put(per100, 'carbs_g', n.carbohydrates_100g);
  put(per100, 'fat_g', n.fat_100g);
  put(per100, 'fiber_g', n.fiber_100g);
  put(per100, 'sugar_g', n.sugars_100g);
  put(per100, 'sat_fat_g', n['saturated-fat_100g']);
  const sodium = typeof n.sodium_100g === 'number' ? n.sodium_100g : typeof n.salt_100g === 'number' ? n.salt_100g / 2.5 : undefined;
  if (sodium !== undefined) put(per100, 'sodium_mg', sodium * 1000);
  // alcohol_100g is % by volume.
  if (typeof n.alcohol_100g === 'number' && n.alcohol_100g > 0 && n.alcohol_100g <= 100) put(per100, 'alcohol_drinks', (n.alcohol_100g * ETHANOL_G_PER_ML) / DRINK_G);
  if (!Object.keys(per100).length) return null;

  const unitText = `${String(p.product_quantity_unit ?? '')} ${String(p.quantity ?? '')}`.toLowerCase();
  const unit: 'g' | 'ml' = /\b(ml|cl|l|fl)\b/.test(unitText) ? 'ml' : 'g';
  const portions: Food['portions'] = [];
  const serving = typeof p.serving_quantity === 'number' ? p.serving_quantity : Number(p.serving_quantity);
  if (Number.isFinite(serving) && serving > 0 && serving <= 5000) {
    const text = typeof p.serving_size === 'string' ? p.serving_size.trim().slice(0, 60) : '';
    const size = `${round1(serving)} ${unit === 'ml' ? 'mL' : 'g'}`;
    portions.push({ label: text && !text.toLowerCase().replace(/\s/g, '').startsWith(size.toLowerCase().replace(/\s/g, '')) ? `${text} (${size})` : `1 serving (${size})`, grams: serving });
  }
  portions.push(label100(unit));
  const brands = Array.isArray(p.brands) ? p.brands.filter((b): b is string => typeof b === 'string') : typeof p.brands === 'string' ? p.brands.split(',') : [];
  const brand = brands.map((b) => b.trim()).find(Boolean) ?? null;
  return { ref: `off:${code}`, name: tidyName(p.product_name).slice(0, 120), brand: brand ? brand.slice(0, 80) : null, source: 'off', per100, portions };
}

/** Open Food Facts' own limits are per address per minute; staying under them here leaves room for the iPhone. */
const offBudget = { search: { max: 8, calls: [] as number[] }, product: { max: 12, calls: [] as number[] } };
function offAllowed(kind: keyof typeof offBudget) {
  const b = offBudget[kind];
  const now = Date.now();
  b.calls = b.calls.filter((t) => now - t < 60_000);
  if (b.calls.length >= b.max) return false;
  b.calls.push(now);
  return true;
}

async function offFetch(fetchFn: FetchFn, url: string) {
  return fetchFn(url, { headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' }, signal: AbortSignal.timeout(TIMEOUT_MS.off) });
}

// ---------- barcodes ----------

/** A scanned or typed code as GTIN-14 digits (EAN-8, UPC-A, EAN-13 and GTIN-14 all pad to it), or null. */
export function gtin14(raw: string): string | null {
  const digits = raw.replace(/[\s-]/g, '');
  if (!/^\d{8}$|^\d{12,14}$/.test(digits)) return null;
  return digits.padStart(14, '0');
}

/** The forms a code is listed under: UPC-A (12), EAN-13 and GTIN-14, without duplicates. */
function barcodeForms(g14: string) {
  const forms = [g14.slice(2), g14.slice(1), g14].filter((c, i, all) => all.indexOf(c) === i);
  return g14.startsWith('000000') ? [g14.slice(6), ...forms] : forms;
}

/** How Open Food Facts lists a code: EAN-8 as 8 digits, UPC-A and EAN-13 as 13, GTIN-14 as is. */
export const offCode = (g14: string) => (g14.startsWith('000000') ? g14.slice(6) : g14.startsWith('0') ? g14.slice(1) : g14);

// ---------- the routes ----------

const bad = (message: string) => new HttpError(400, message);

/** Per person, per minute: generous for logging, a ceiling for scripts. */
const LOOKUPS_PER_MINUTE = 30;
const lookups = new Map<string, number[]>();
function allowLookup(userId: string) {
  const now = Date.now();
  const recent = (lookups.get(userId) ?? []).filter((t) => now - t < 60_000);
  if (recent.length >= LOOKUPS_PER_MINUTE) return false;
  recent.push(now);
  lookups.set(userId, recent);
  return true;
}

/**
 * Recent searches' results, in this server process only and never stored. Keyed by a hash of the words, so the words
 * themselves aren't kept. (A food someone looked up comes back faster for everyone: that's the shared cache's point,
 * and it says nothing about who.)
 */
const searches = new Map<string, { at: number; refs: string[] }>();
const searchKey = (query: string) => createHash('sha256').update(query.toLowerCase()).digest('hex');
/** Foods not looked up again for this long go from the shared cache; saved entries keep their own amounts. */
const CACHE_TTL_MS = 90 * 24 * 3600_000;

/** The hourly cron's tidy-up: foods nobody has looked up in 90 days, and barcodes that pointed to them. */
export async function pruneFoodCache(q: Queryable) {
  return (await q.query('DELETE FROM food_cache WHERE fetched_at < $1 RETURNING 1', [Date.now() - CACHE_TTL_MS])).length;
}
const SEARCH_TTL_MS = 6 * 3600_000;

export type FoodsDeps = {
  fetchFn: FetchFn;
  /** The person's numbers setting; throws (409) while Nutrition is off. */
  numbersOf: (res: Response) => Promise<NutritionNumbers>;
  shownValues: (values: FoodValues, numbers: NutritionNumbers) => FoodValues;
};

export function foodsRouter(db: Db, deps: FoodsDeps) {
  const router = express.Router();

  const result = (f: Food, numbers: NutritionNumbers): FoodResult => ({
    ref: f.ref,
    name: f.name,
    brand: f.brand,
    source: f.source,
    portions: f.portions.map((p, i) => ({ label: p.label, values: deps.shownValues(portionValues(f, i), numbers) })),
  });

  async function search(query: string): Promise<{ foods: Food[]; notes: string[] }> {
    const key = searchKey(query);
    const hit = searches.get(key);
    if (hit && Date.now() - hit.at < SEARCH_TTL_MS) {
      const foods = (await Promise.all(hit.refs.map((r) => cachedFood(db, r)))).filter((f): f is Food => f !== null);
      if (foods.length === hit.refs.length) return { foods, notes: [] };
    }
    const notes: string[] = [];
    const usdaKey = process.env.FDC_API_KEY;
    const [usda, off] = await Promise.allSettled([
      usdaKey
        ? usdaSearch(deps.fetchFn, usdaKey, { query, dataType: ['Survey (FNDDS)', 'Foundation', 'SR Legacy', 'Branded'], pageSize: 20 })
        : Promise.resolve([] as UsdaFood[]),
      offAllowed('search')
        ? offFetch(deps.fetchFn, `${OFF_SEARCH}?${new URLSearchParams({ q: query, page_size: '10', fields: OFF_FIELDS })}`).then(async (r) => {
            if (!r.ok) throw new Error(`off ${r.status}`);
            const data = (await r.json()) as { hits?: unknown };
            return Array.isArray(data.hits) ? (data.hits as OffProduct[]) : [];
          })
        : Promise.reject(new Error('off budget')),
    ]);
    if (usda.status === 'rejected') notes.push("USDA FoodData Central didn't answer, so its foods are missing. Try again in a minute.");
    if (off.status === 'rejected') notes.push("Open Food Facts didn't answer, so its packaged foods are missing. Try again in a minute.");
    const foods = [
      ...(usda.status === 'fulfilled' ? usda.value.map(usdaFood) : []),
      ...(off.status === 'fulfilled' ? off.value.map(offFood) : []),
    ].filter((f): f is Food => f !== null);
    await cacheFoods(db, foods);
    if (!notes.length) {
      searches.set(key, { at: Date.now(), refs: foods.map((f) => f.ref) });
      if (searches.size > 500) searches.delete(searches.keys().next().value!);
    }
    return { foods, notes };
  }

  async function barcode(g14: string): Promise<{ foods: Food[]; notes: string[] }> {
    const cached = await cachedBarcode(db, g14);
    if (cached) return { foods: [cached], notes: [] };
    const notes: string[] = [];
    if (offAllowed('product')) {
      try {
        const r = await offFetch(deps.fetchFn, `${OFF_PRODUCT}/${offCode(g14)}?fields=${OFF_FIELDS}`);
        if (r.ok) {
          const data = (await r.json()) as { product?: OffProduct };
          const food = data.product ? offFood(data.product) : null;
          if (food) {
            await cacheFoods(db, [food]);
            await rememberBarcode(db, g14, food.ref);
            return { foods: [food], notes };
          }
        } else if (r.status !== 404) notes.push("Open Food Facts didn't answer.");
      } catch {
        notes.push("Open Food Facts didn't answer.");
      }
    } else notes.push('Open Food Facts is busy.');
    const usdaKey = process.env.FDC_API_KEY;
    if (usdaKey) {
      try {
        for (const form of barcodeForms(g14)) {
          const found = (await usdaSearch(deps.fetchFn, usdaKey, { query: form, dataType: ['Branded'], pageSize: 5 })).find(
            (f) => typeof f.gtinUpc === 'string' && gtin14(f.gtinUpc) === g14,
          );
          const food = found ? usdaFood(found) : null;
          if (food) {
            await cacheFoods(db, [food]);
            await rememberBarcode(db, g14, food.ref);
            return { foods: [food], notes: [] };
          }
        }
      } catch {
        notes.push("USDA FoodData Central didn't answer.");
      }
    }
    return { foods: [], notes };
  }

  /** Search both databases by words, or look up a barcode typed as digits. The words come in the body. */
  router.post('/search', async (req: Request, res: Response) => {
    const numbers = await deps.numbersOf(res);
    const raw = (req.body as { query?: unknown } | undefined)?.query;
    if (typeof raw !== 'string') throw bad('Type a food to search for.');
    const query = raw.replace(/\s+/g, ' ').trim();
    if (query.length < 2) throw bad('Type a food to search for.');
    if (query.length > 100) throw bad('Keep the search under 100 characters.');
    if (!allowLookup(currentUser(res).id)) throw new HttpError(429, 'That was a lot of searches. Wait a minute and try again.');
    const code = /^[\d\s-]+$/.test(query) ? gtin14(query) : null;
    const { foods, notes } = code ? await barcode(code) : await search(query);
    const body: FoodSearch = { results: foods.map((f) => result(f, numbers)), notes };
    res.json(body);
  });

  /** A scanned barcode: Open Food Facts, then USDA's branded foods. */
  router.post('/barcode', async (req: Request, res: Response) => {
    const numbers = await deps.numbersOf(res);
    const raw = (req.body as { code?: unknown } | undefined)?.code;
    const code = typeof raw === 'string' ? gtin14(raw) : null;
    if (!code) throw bad("That barcode doesn't look right.");
    if (!allowLookup(currentUser(res).id)) throw new HttpError(429, 'That was a lot of lookups. Wait a minute and try again.');
    const { foods, notes } = await barcode(code);
    const body: FoodSearch = { results: foods.map((f) => result(f, numbers)), notes };
    res.json(body);
  });

  return router;
}
