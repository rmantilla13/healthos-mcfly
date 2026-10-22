// The Nutrition page's Log tab: what a person logs in healthOS itself. A day's entries, each editable, and one card
// to add more: a food database search (or a typed barcode), McFly's estimate from a photo or a few words (a draft to
// check and save, never saved on its own), or amounts typed in. The server has already removed every number the
// person chose not to see, and saves a database food from its own copy, so this page never needs them. Same tone as
// the rest of Nutrition: no score, no "remaining", no colour for more or less.
import { type FormEvent, useEffect, useRef, useState } from 'react';
import type { FoodEntry, FoodEstimate, FoodLog, FoodResult, FoodSearch, FoodValues, NutritionData, NutritionNumbers, Settings, Status } from '../../shared/types.ts';
import { Icon } from '../components/Icon.tsx';
import { fmt, fmtDate, notifyDataChanged, relativeDay, sendJson, shiftDate, useApi } from '../lib.ts';

type Units = Settings['units'];
type Key = keyof FoodValues;

const FL_OZ_ML = 29.5735;
/** Long edge of a photo sent for an estimate: plenty to tell foods apart, and about 1,600 tokens. */
const PHOTO_EDGE = 1280;

const waterText = (ml: number, units: Units) => (units === 'imperial' ? `${fmt(ml / FL_OZ_ML)} fl oz` : `${fmt(ml)} mL`);

/** Grams: a decimal only for small amounts that have one (0.5 g, not 6.0 g). */
const grams = (v: number) => fmt(v, v < 10 && Math.round(v * 10) % 10 !== 0 ? 1 : 0);

/** An entry's amounts in one line, in the order people read a label. Only what the server sent. */
function amounts(v: FoodValues, units: Units) {
  const parts: string[] = [];
  if (v.energy_kcal !== undefined) parts.push(`${fmt(v.energy_kcal)} kcal`);
  if (v.protein_g !== undefined) parts.push(`${grams(v.protein_g)} g protein`);
  if (v.carbs_g !== undefined) parts.push(`${grams(v.carbs_g)} g carbs`);
  if (v.fat_g !== undefined) parts.push(`${grams(v.fat_g)} g fat`);
  if (v.alcohol_drinks) parts.push(`${Number(v.alcohol_drinks.toFixed(1))} ${v.alcohol_drinks === 1 ? 'drink' : 'drinks'}`);
  if (v.water_ml !== undefined) parts.push(`${waterText(v.water_ml, units)} water`);
  return parts.join(' · ');
}

function addUp(entries: FoodEntry[]) {
  const total: FoodValues = {};
  for (const e of entries) for (const [k, v] of Object.entries(e.values) as [Key, number][]) total[k] = (total[k] ?? 0) + v;
  return total;
}

const scaled = (v: FoodValues, by: number) => Object.fromEntries(Object.entries(v).map(([k, x]) => [k, x * by])) as FoodValues;

const portionText = (e: Pick<FoodEntry, 'portion' | 'quantity'>) => (e.quantity === 1 ? e.portion : `${Number(e.quantity.toFixed(2))} × ${e.portion || 'portion'}`);

/** The amounts this setting lets a person type: never calories in 'no_energy', none at all in 'none'. */
function typedKeys(numbers: NutritionNumbers): { key: Key; label: string; unit: (u: Units) => string }[] {
  if (numbers === 'none') return [];
  return [
    ...(numbers === 'all' ? [{ key: 'energy_kcal' as Key, label: 'Calories', unit: () => 'kcal' }] : []),
    { key: 'protein_g', label: 'Protein', unit: () => 'g' },
    { key: 'carbs_g', label: 'Carbs', unit: () => 'g' },
    { key: 'fat_g', label: 'Fat', unit: () => 'g' },
    { key: 'water_ml', label: 'Water', unit: (u) => (u === 'imperial' ? 'fl oz' : 'mL') },
  ];
}

/** Typed text to a stored amount (water from fl oz when imperial); null for blank, NaN for nonsense. */
function toAmount(key: Key, raw: string, units: Units): number | null {
  const s = raw.trim().replace(',', '.');
  if (!s) return null;
  const n = Number(s);
  return key === 'water_ml' && units === 'imperial' ? n * FL_OZ_ML : n;
}
const fromAmount = (key: Key, v: number | undefined, units: Units) =>
  v === undefined ? '' : String(Math.round((key === 'water_ml' && units === 'imperial' ? v / FL_OZ_ML : v) * 10) / 10);

/** Now, as HH:MM. */
const nowTime = () => new Date().toTimeString().slice(0, 5);

// ---------- the tab ----------

export function FoodLogTab({ status }: { status: Status }) {
  const numbers = status.settings.nutritionNumbers ?? 'none';
  const units = status.settings.units;
  // The setting is in the address so the loaded data, cached by address, is never one filtered for another setting.
  const { data, error, loading } = useApi<FoodLog>(`/nutrition/log?days=14&numbers=${numbers}`);
  const totals = useApi<NutritionData>(`/nutrition?days=14&numbers=${numbers}`);
  const [day, setDay] = useState<string | null>(null);
  if (error && !data) return <div className="page-message">Couldn't load your food log: {error.message}</div>;
  if (!data) return <div className="page-message">Loading…</div>;
  const selected = day && day >= data.start && day <= data.today ? day : data.today;
  const entries = data.entries.filter((e) => e.date === selected);
  const counted = totals.data?.days.find((d) => d.date === selected);
  return (
    <div className={`split split-even food-log ${loading ? 'is-refreshing' : ''}`}>
      <section className="card food-day">
        <header className="food-day-head">
          <button className="btn btn-quiet" aria-label="Day before" disabled={selected <= data.start} onClick={() => setDay(shiftDate(selected, -1))}>
            <Icon name="chevron-left" size={16} />
          </button>
          <div>
            <h2>{relativeDay(selected, data.today)}</h2>
            <span className="muted small">{fmtDate(selected, { weekday: 'long', month: 'long', day: 'numeric' })}</span>
          </div>
          <button className="btn btn-quiet" aria-label="Day after" disabled={selected >= data.today} onClick={() => setDay(shiftDate(selected, 1))}>
            <Icon name="chevron-right" size={16} />
          </button>
        </header>
        {entries.length ? (
          <ul className="food-entries">
            {entries.map((e) => (
              <EntryRow key={e.id} entry={e} numbers={numbers} units={units} />
            ))}
          </ul>
        ) : (
          <p className="muted food-none">Nothing logged in healthOS on this day.</p>
        )}
        {entries.length > 0 && numbers !== 'none' && amounts(addUp(entries), units) && (
          <p className="food-sum">
            <span className="muted small">Logged here</span>
            <span>{amounts(addUp(entries), units)}</span>
          </p>
        )}
        {counted && entries.length > 0 && counted.app !== 'healthOS' && (
          <p className="muted small">
            This day's totals on the other tabs come from {counted.app}. When two apps log the same day, one app's totals count and the other's aren't added in, because
            apps copy each other's food through Apple Health. You can choose which app counts on the Macros tab.
          </p>
        )}
      </section>
      <AddFood log={data} date={selected} numbers={numbers} units={units} />
    </div>
  );
}

// ---------- one entry ----------

function EntryRow({ entry, numbers, units }: { entry: FoodEntry; numbers: NutritionNumbers; units: Units }) {
  const [editing, setEditing] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!confirming) return;
    const t = setTimeout(() => setConfirming(false), 4000);
    return () => clearTimeout(t);
  }, [confirming]);
  async function remove() {
    if (!confirming) return setConfirming(true);
    try {
      await sendJson('DELETE', `/nutrition/log/${entry.id}`);
      notifyDataChanged();
    } catch (e) {
      setError((e as Error).message);
    }
  }
  const line = amounts(entry.values, units);
  return (
    <li className="food-entry">
      <div className="food-entry-main">
        <span className="food-time muted small">{entry.time}</span>
        <div className="food-entry-text">
          <strong>{entry.name}</strong>
          <span className="muted small">
            {[portionText(entry), entry.method === 'estimate' ? 'estimated by McFly' : null, entry.ref?.startsWith('off:') ? 'Open Food Facts' : entry.ref ? 'USDA' : null]
              .filter(Boolean)
              .join(' · ')}
          </span>
          {line && <span className="small">{line}</span>}
        </div>
        <div className="food-entry-actions">
          <button className="btn btn-quiet small" onClick={() => setEditing(!editing)} aria-expanded={editing}>
            {editing ? 'Close' : 'Edit'}
          </button>
          <button className="btn btn-quiet small" onClick={remove}>
            {confirming ? 'Delete it?' : 'Delete'}
          </button>
        </div>
      </div>
      {error && <p className="note-bad small">{error}</p>}
      {editing && <EntryEditor entry={entry} numbers={numbers} units={units} onDone={() => setEditing(false)} />}
    </li>
  );
}

/** Name, time, how many, and the amounts this person sees. Only what changed is sent. */
function EntryEditor({ entry, numbers, units, onDone }: { entry: FoodEntry; numbers: NutritionNumbers; units: Units; onDone: () => void }) {
  const keys = typedKeys(numbers);
  const [name, setName] = useState(entry.name);
  const [time, setTime] = useState(entry.time);
  const [quantity, setQuantity] = useState(String(entry.quantity));
  const [typed, setTyped] = useState<Record<string, string>>(() => Object.fromEntries(keys.map((k) => [k.key, fromAmount(k.key, entry.values[k.key], units)])));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function save(e: FormEvent) {
    e.preventDefault();
    const patch: Record<string, unknown> = {};
    if (name.trim() !== entry.name) patch.name = name;
    if (time !== entry.time) patch.time = time;
    const q = Number(quantity.replace(',', '.'));
    if (q !== entry.quantity) patch.quantity = q;
    const values: Record<string, number | null> = {};
    for (const k of keys) {
      if (typed[k.key] === fromAmount(k.key, entry.values[k.key], units)) continue;
      const v = toAmount(k.key, typed[k.key], units);
      if (v !== null && !Number.isFinite(v)) return setError(`${k.label} should be a number.`);
      values[k.key] = v;
    }
    // Typed amounts are for the new quantity; a quantity change alone scales everything on the server.
    if (Object.keys(values).length) patch.values = values;
    if (!Object.keys(patch).length) return onDone();
    setBusy(true);
    setError(null);
    try {
      await sendJson('PATCH', `/nutrition/log/${entry.id}`, patch);
      notifyDataChanged();
      onDone();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <form className="food-form food-editor" onSubmit={save}>
      <div className="food-fields">
        <label className="food-wide">
          <span className="muted small">Name</span>
          <input value={name} onChange={(e) => setName(e.target.value)} maxLength={100} required />
        </label>
        <label>
          <span className="muted small">Time</span>
          <input type="time" value={time} onChange={(e) => setTime(e.target.value)} required />
        </label>
        <label>
          <span className="muted small">How many {entry.portion ? `(${entry.portion})` : ''}</span>
          <input inputMode="decimal" value={quantity} onChange={(e) => setQuantity(e.target.value)} />
        </label>
        {keys.map((k) => (
          <label key={k.key}>
            <span className="muted small">
              {k.label} ({k.unit(units)})
            </span>
            <input inputMode="decimal" value={typed[k.key] ?? ''} placeholder="–" aria-label={`${k.label} in ${k.unit(units)}`} onChange={(e) => setTyped({ ...typed, [k.key]: e.target.value })} />
          </label>
        ))}
      </div>
      {keys.length > 0 && <p className="muted small">Amounts are for the whole entry. Changing only how many scales them all.</p>}
      {error && <p className="note-bad small">{error}</p>}
      <div className="btn-row">
        <button className="btn btn-primary" disabled={busy}>
          {busy ? 'Saving…' : 'Save'}
        </button>
        <button type="button" className="btn btn-quiet" onClick={onDone}>
          Cancel
        </button>
      </div>
    </form>
  );
}

// ---------- adding ----------

type Mode = 'search' | 'estimate' | 'quick';

function AddFood({ log, date, numbers, units }: { log: FoodLog; date: string; numbers: NutritionNumbers; units: Units }) {
  const modes: { id: Mode; label: string }[] = [
    { id: 'search', label: 'Search' },
    ...(log.can.estimate ? [{ id: 'estimate' as Mode, label: 'Photo or words' }] : []),
    ...(numbers !== 'none' ? [{ id: 'quick' as Mode, label: 'Quick add' }] : []),
  ];
  const [mode, setMode] = useState<Mode>('search');
  const current = modes.some((m) => m.id === mode) ? mode : 'search';
  // A time the person picked, or null for the default: now on today (worked out when they add, so a tab left open
  // since breakfast doesn't log lunch at breakfast time), midday on a past day.
  const [picked, setPicked] = useState<string | null>(null);
  const [, tick] = useState(0);
  useEffect(() => setPicked(null), [date]);
  useEffect(() => {
    const t = setInterval(() => tick((n) => n + 1), 30_000);
    return () => clearInterval(t);
  }, []);
  const defaultTime = () => (date === log.today ? nowTime() : '12:00');
  const when = () => ({ date, time: picked ?? defaultTime() });
  // McFly's note on what it assumed, kept while its estimate is reviewed (it isn't stored with the drafts).
  const [note, setNote] = useState('');
  return (
    <section className="card food-add">
      <header className="food-add-head">
        <h2>Add food or drink</h2>
        {!log.drafts.length && (
          <label className="food-when">
            <span className="muted small">{relativeDay(date, log.today)} at</span>
            <input type="time" value={picked ?? defaultTime()} onChange={(e) => setPicked(e.target.value || null)} aria-label="Time" />
          </label>
        )}
      </header>
      {log.drafts.length > 0 ? (
        <EstimateReview key={log.drafts.map((d) => d.id).join()} drafts={log.drafts} batch={log.draftBatch ?? ''} note={note} units={units} numbers={numbers} />
      ) : (
        <>
          {numbers !== 'none' && <WaterButtons when={when} units={units} />}
          {modes.length > 1 && (
            <div className="seg food-modes" role="tablist" aria-label="How to add">
              {modes.map((m) => (
                <button key={m.id} role="tab" aria-selected={current === m.id} className={current === m.id ? 'on' : ''} onClick={() => setMode(m.id)}>
                  {m.label}
                </button>
              ))}
            </div>
          )}
          {current === 'search' && <SearchFood when={when} units={units} usda={log.can.usda} />}
          {current === 'estimate' && <EstimateFood when={when} onNote={setNote} />}
          {current === 'quick' && <QuickAdd when={when} numbers={numbers} units={units} />}
        </>
      )}
    </section>
  );
}

/** The date and time to log at, worked out when the person adds. */
type When = () => { date: string; time: string };

/** Water in one tap: a glass or a bottle, in the person's units. Any other amount goes through Quick add. */
const WATER: Record<Units, { label: string; portion: string; ml: number }[]> = {
  metric: [
    { label: 'Glass, 250 mL', portion: '1 glass (250 mL)', ml: 250 },
    { label: 'Bottle, 500 mL', portion: '1 bottle (500 mL)', ml: 500 },
  ],
  imperial: [
    { label: 'Glass, 8 fl oz', portion: '1 glass (8 fl oz)', ml: 8 * FL_OZ_ML },
    { label: 'Bottle, 16.9 fl oz', portion: '1 bottle (16.9 fl oz)', ml: 500 },
  ],
};

function WaterButtons({ when, units }: { when: When; units: Units }) {
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!done) return;
    const t = setTimeout(() => setDone(null), 4000);
    return () => clearTimeout(t);
  }, [done]);
  async function add(w: (typeof WATER)[Units][number]) {
    setBusy(true);
    setError(null);
    try {
      await sendJson('POST', '/nutrition/log', { method: 'quick', name: 'Water', portion: w.portion, values: { water_ml: w.ml }, ...when() });
      setDone(`Added ${w.portion.replace(/^1 /, 'a ')}.`);
      notifyDataChanged();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="food-water">
      <span className="muted small">Water</span>
      <div className="btn-row">
        {WATER[units].map((w) => (
          <button key={w.label} type="button" className="chip-btn" disabled={busy} onClick={() => add(w)}>
            + {w.label}
          </button>
        ))}
      </div>
      {done && (
        <span className="small food-added" role="status">
          {done}
        </span>
      )}
      {error && <span className="note-bad small">{error}</span>}
    </div>
  );
}

function SearchFood({ when, units, usda }: { when: When; units: Units; usda: boolean }) {
  const [query, setQuery] = useState('');
  const [found, setFound] = useState<(FoodSearch & { barcode: boolean }) | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [added, setAdded] = useState<string | null>(null);
  async function search(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setAdded(null);
    // Digits are looked up as a barcode (the server decides the same way).
    const barcode = /^[\d\s-]{8,}$/.test(query.trim());
    try {
      const r = await sendJson<FoodSearch>('POST', '/nutrition/foods/search', { query });
      setFound({ ...r, barcode });
      setOpen(r.results.length === 1 ? r.results[0].ref : null);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="food-search">
      <form className="food-search-form" onSubmit={search} role="search">
        <input
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search foods, or type a barcode"
          aria-label="Search foods, or type a barcode"
          maxLength={100}
          enterKeyHint="search"
        />
        <button className="btn btn-primary" disabled={busy || query.trim().length < 2}>
          {busy ? 'Searching…' : 'Search'}
        </button>
      </form>
      {error && <p className="note-bad small">{error}</p>}
      {added && <p className="small food-added">Added {added}.</p>}
      {found && (
        <>
          {found.notes.map((n) => (
            <p key={n} className="muted small">
              {n}
            </p>
          ))}
          {found.results.length === 0 ? (
            <p className="muted">
              {found.barcode
                ? `That barcode isn’t in ${usda ? 'USDA FoodData Central or ' : ''}Open Food Facts. Quick add from the label instead.`
                : 'Nothing found. Try fewer or other words.'}
            </p>
          ) : (
            <ul className="food-results">
              {found.results.map((r) => (
                <ResultRow
                  key={r.ref}
                  food={r}
                  open={open === r.ref}
                  onToggle={() => setOpen(open === r.ref ? null : r.ref)}
                  when={when}
                  units={units}
                  method={found.barcode ? 'barcode' : 'search'}
                  onAdded={(name) => {
                    setAdded(name);
                    setOpen(null);
                  }}
                />
              ))}
            </ul>
          )}
        </>
      )}
      <p className="muted small food-credit">
        Foods from {usda ? 'USDA FoodData Central and ' : ''}Open Food Facts. healthOS's server sends them your search, never your name.
      </p>
    </div>
  );
}

function ResultRow({
  food,
  open,
  onToggle,
  when,
  units,
  method,
  onAdded,
}: {
  food: FoodResult;
  open: boolean;
  onToggle: () => void;
  when: When;
  units: Units;
  method: 'search' | 'barcode';
  onAdded: (name: string) => void;
}) {
  const [portion, setPortion] = useState(0);
  const [quantity, setQuantity] = useState('1');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const q = Number(quantity.replace(',', '.'));
  const preview = Number.isFinite(q) && q > 0 ? amounts(scaled(food.portions[portion].values, q), units) : '';
  async function add() {
    setBusy(true);
    setError(null);
    try {
      await sendJson('POST', '/nutrition/log', { method, ref: food.ref, portionIndex: portion, quantity: q, ...when() });
      notifyDataChanged();
      onAdded(food.name);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <li className={`food-result ${open ? 'is-open' : ''}`}>
      <button className="food-result-head" onClick={onToggle} aria-expanded={open}>
        <span>
          <strong>{food.name}</strong>
          <span className="muted small">{[food.brand, food.source === 'usda' ? 'USDA' : 'Open Food Facts'].filter(Boolean).join(' · ')}</span>
        </span>
        <Icon name="chevron-right" size={14} />
      </button>
      {open && (
        <div className="food-pick">
          <div className="food-fields">
            <label className="food-wide">
              <span className="muted small">Portion</span>
              <select value={portion} onChange={(e) => setPortion(Number(e.target.value))}>
                {food.portions.map((p, i) => (
                  <option key={p.label} value={i}>
                    {p.label}
                  </option>
                ))}
              </select>
            </label>
            <label>
              <span className="muted small">How many</span>
              <input inputMode="decimal" value={quantity} onChange={(e) => setQuantity(e.target.value)} />
            </label>
          </div>
          {preview && <p className="small">{preview}</p>}
          {error && <p className="note-bad small">{error}</p>}
          <button className="btn btn-primary" disabled={busy || !(q > 0)} onClick={add}>
            {busy ? 'Adding…' : 'Add'}
          </button>
        </div>
      )}
    </li>
  );
}

/** Shrinks and re-encodes a photo on this device: a smaller upload, fewer tokens, and no location or camera data. */
async function shrinkPhoto(file: File): Promise<{ data: string; preview: string }> {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    const scale = Math.min(1, PHOTO_EDGE / Math.max(img.naturalWidth, img.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(img.naturalWidth * scale);
    canvas.height = Math.round(img.naturalHeight * scale);
    canvas.getContext('2d')!.drawImage(img, 0, 0, canvas.width, canvas.height);
    const preview = canvas.toDataURL('image/jpeg', 0.85);
    return { data: preview.slice(preview.indexOf(',') + 1), preview };
  } finally {
    URL.revokeObjectURL(url);
  }
}

function EstimateFood({ when, onNote }: { when: When; onNote: (note: string) => void }) {
  const [description, setDescription] = useState('');
  const [photo, setPhoto] = useState<{ data: string; preview: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  async function choose(file: File | undefined) {
    if (!file) return;
    setError(null);
    try {
      setPhoto(await shrinkPhoto(file));
    } catch {
      setError("That photo couldn't be opened here. Try a JPEG or PNG, or describe it instead.");
    }
  }
  async function estimate(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      const r = await sendJson<FoodEstimate>('POST', '/nutrition/estimate', {
        description,
        image: photo ? { mediaType: 'image/jpeg', data: photo.data } : null,
        ...when(),
      });
      if (!r.drafts.length) setNote(r.note || "McFly didn't find food or drink to estimate.");
      else {
        onNote(r.note);
        setDescription('');
        setPhoto(null);
      }
      notifyDataChanged();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <form className="food-form food-estimate" onSubmit={estimate}>
      <textarea
        value={description}
        onChange={(e) => setDescription(e.target.value)}
        maxLength={1000}
        rows={3}
        placeholder="What did you have? For example: pasta with pesto, cooked in olive oil, about half a plate."
        aria-label="What did you have?"
      />
      <input ref={fileInput} type="file" accept="image/*" capture="environment" hidden onChange={(e) => void choose(e.target.files?.[0])} />
      {photo ? (
        <div className="food-photo">
          <img src={photo.preview} alt="Your photo, as it will be sent" />
          <button type="button" className="btn btn-quiet small" onClick={() => setPhoto(null)}>
            Remove photo
          </button>
        </div>
      ) : (
        <button type="button" className="btn" onClick={() => fileInput.current?.click()}>
          Add a photo
        </button>
      )}
      <p className="muted small">
        The photo and words go to Anthropic for this one estimate, and healthOS doesn't keep them. It counts as one McFly question. Estimates are rough, often a third off on
        calories, so you check them before anything is saved. A few words about oil, sauces or portion size help most.
      </p>
      {note && <p className="muted">{note}</p>}
      {error && <p className="note-bad small">{error}</p>}
      <button className="btn btn-primary" disabled={busy || (!description.trim() && !photo)}>
        {busy ? 'Estimating…' : 'Estimate'}
      </button>
    </form>
  );
}

/** McFly's draft: rename, change how many, or drop items, then save what's left. Nothing counts until then. */
function EstimateReview({ drafts, batch, note, units, numbers }: { drafts: FoodEntry[]; batch: string; note: string; units: Units; numbers: NutritionNumbers }) {
  const [kept, setKept] = useState(() => drafts.map((d) => ({ id: d.id, name: d.name, quantity: String(d.quantity) })));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const byId = new Map(drafts.map((d) => [d.id, d]));
  const update = (id: string, patch: Partial<{ name: string; quantity: string }>) => setKept(kept.map((k) => (k.id === id ? { ...k, ...patch } : k)));
  async function save() {
    setBusy(true);
    setError(null);
    try {
      for (const k of kept) {
        const d = byId.get(k.id)!;
        const patch: Record<string, unknown> = {};
        if (k.name.trim() !== d.name) patch.name = k.name;
        const q = Number(k.quantity.replace(',', '.'));
        if (q !== d.quantity) patch.quantity = q;
        if (Object.keys(patch).length) await sendJson('PATCH', `/nutrition/log/${k.id}`, patch);
      }
      await sendJson('POST', '/nutrition/log/save', { batch, ids: kept.map((k) => k.id) });
      notifyDataChanged();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function discard() {
    setBusy(true);
    try {
      await sendJson('POST', '/nutrition/log/discard', { batch });
      notifyDataChanged();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  const first = drafts[0];
  return (
    <div className="food-review">
      <p className="small">
        <strong>McFly's estimate</strong>
        <span className="muted"> for {first.time}. Check it, then save. Nothing counts until you do.</span>
      </p>
      {note && <p className="food-note small">{note}</p>}
      <ul className="food-results">
        {kept.map((k) => {
          const d = byId.get(k.id)!;
          const q = Number(k.quantity.replace(',', '.'));
          const line = numbers !== 'none' && q > 0 ? amounts(scaled(d.values, q / d.quantity), units) : '';
          return (
            <li key={k.id} className="food-draft">
              <div className="food-fields">
                <label className="food-wide">
                  <span className="muted small">{d.portion || 'Item'}</span>
                  <input value={k.name} onChange={(e) => update(k.id, { name: e.target.value })} maxLength={100} aria-label="Name" />
                </label>
                <label>
                  <span className="muted small">How many</span>
                  <input inputMode="decimal" value={k.quantity} onChange={(e) => update(k.id, { quantity: e.target.value })} />
                </label>
                <button type="button" className="btn btn-quiet small food-drop" onClick={() => setKept(kept.filter((x) => x.id !== k.id))} aria-label={`Leave out ${k.name}`}>
                  Leave out
                </button>
              </div>
              {line && <p className="small">{line}</p>}
            </li>
          );
        })}
      </ul>
      {error && <p className="note-bad small">{error}</p>}
      <div className="btn-row">
        <button className="btn btn-primary" disabled={busy || !kept.length} onClick={save}>
          {busy ? 'Saving…' : kept.length === 1 ? 'Save 1 item' : `Save ${kept.length} items`}
        </button>
        <button className="btn btn-quiet" disabled={busy} onClick={discard}>
          Discard
        </button>
      </div>
      <p className="muted small">You can fix any amount after saving, with Edit.</p>
    </div>
  );
}

function QuickAdd({ when, numbers, units }: { when: When; numbers: NutritionNumbers; units: Units }) {
  const keys = typedKeys(numbers);
  const [name, setName] = useState('');
  const [typed, setTyped] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [added, setAdded] = useState<string | null>(null);
  async function add(e: FormEvent) {
    e.preventDefault();
    const values: Record<string, number> = {};
    for (const k of keys) {
      const v = toAmount(k.key, typed[k.key] ?? '', units);
      if (v === null) continue;
      if (!Number.isFinite(v) || v < 0) return setError(`${k.label} should be a number.`);
      values[k.key] = v;
    }
    if (!Object.keys(values).length) return setError('Enter at least one amount.');
    setBusy(true);
    setError(null);
    try {
      const entry = await sendJson<FoodEntry>('POST', '/nutrition/log', { method: 'quick', name, values, ...when() });
      setAdded(entry.name);
      setName('');
      setTyped({});
      notifyDataChanged();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <form className="food-form" onSubmit={add}>
      <div className="food-fields">
        <label className="food-wide">
          <span className="muted small">Name (optional)</span>
          <input value={name} onChange={(e) => setName(e.target.value)} maxLength={100} placeholder="Quick add" aria-label="Name (optional)" />
        </label>
        {keys.map((k) => (
          <label key={k.key}>
            <span className="muted small">
              {k.label} ({k.unit(units)})
            </span>
            <input inputMode="decimal" value={typed[k.key] ?? ''} aria-label={`${k.label} in ${k.unit(units)}`} onChange={(e) => setTyped({ ...typed, [k.key]: e.target.value })} />
          </label>
        ))}
      </div>
      {error && <p className="note-bad small">{error}</p>}
      {added && <p className="small food-added">Added {added}.</p>}
      <button className="btn btn-primary" disabled={busy}>
        {busy ? 'Adding…' : 'Add'}
      </button>
    </form>
  );
}
