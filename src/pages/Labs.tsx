// Lab tests: blood panels and other lab results, each against the reference range printed by the lab. Results are
// typed in as printed, or read from a report by Claude and checked by the person before anything is saved. A status
// only says where a number sits against a range; nothing here is a diagnosis.
import { type FormEvent, Fragment, type ReactNode, useMemo, useRef, useState } from 'react';
import { BIOMARKERS, type LabDraft, type LabExtract, type LabMarker, type LabResult, type LabsData, markerUnits, matchBiomarker, unitKey } from '../../shared/labs.ts';
import type { Status } from '../../shared/types.ts';
import { TrendChart } from '../charts/Charts.tsx';
import { Icon } from '../components/Icon.tsx';
import { LabRangeBar, LabStatusChip, labNumber, rangeLabel } from '../components/LabRange.tsx';
import { REPORT_ACCEPT, prepareReport, readReport } from '../labsUpload.ts';
import { fmtDate, notifyDataChanged, sendJson, useApi } from '../lib.ts';
import { PageHead } from './Detail.tsx';

const longDate = (d: string) => fmtDate(d, { month: 'short', day: 'numeric', year: 'numeric' });

type Mode = 'add' | 'import' | null;

export function Labs({ status: _status, params: _params }: { status: Status; params: URLSearchParams }) {
  const { data, error, loading } = useApi<LabsData>('/labs');
  const [mode, setMode] = useState<Mode>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [notice, setNotice] = useState('');
  const today = data?.today ?? new Date().toLocaleDateString('en-CA');

  const start = (m: Mode) => {
    setNotice('');
    setMode(m);
  };
  const saved = (n: number) => {
    setMode(null);
    setNotice(`Added ${n} ${n === 1 ? 'result' : 'results'}.`);
    notifyDataChanged();
  };

  const tools = (
    <div className="btn-row">
      <button className="btn btn-primary" aria-pressed={mode === 'add'} onClick={() => start(mode === 'add' ? null : 'add')}>
        Add results
      </button>
      <button className="btn" aria-pressed={mode === 'import'} onClick={() => start(mode === 'import' ? null : 'import')}>
        <Icon name="upload" size={15} />
        Import a report
      </button>
    </div>
  );

  return (
    <div className={`page page-wide labs ${loading ? 'is-refreshing' : ''}`}>
      <PageHead title="Lab tests" sub="Blood tests and other lab results, each against the reference range printed by the lab." tools={tools} />
      {notice && (
        <p className="note-good" role="status">
          <Icon name="check" size={15} /> {notice}
        </p>
      )}
      {mode === 'add' && (
        <ResultsForm
          title="Add results"
          intro={<p className="muted small">Type each result as it's printed on your report, with the reference range printed beside it. Leave a row empty to skip it.</p>}
          initial={[{ id: 1, collected: today, lab: '', rows: [blankRow(1), blankRow(2), blankRow(3)] }]}
          source="manual"
          today={today}
          onSaved={saved}
          onCancel={() => setMode(null)}
        />
      )}
      {mode === 'import' && <ImportReport today={today} onSaved={saved} onCancel={() => setMode(null)} />}
      {error && !data ? (
        <div className="page-message">Couldn't load your lab results: {error.message}</div>
      ) : !data ? (
        <div className="page-message">Loading…</div>
      ) : data.count === 0 ? (
        mode === null && <NothingYet start={start} />
      ) : (
        <>
          {data.demo && (
            <p className="banner labs-demo">
              <Icon name="labs" size={16} /> These are demo results. Add your own and they take their place.
            </p>
          )}
          <LatestResults data={data} open={open} setOpen={setOpen} />
          <ByDate data={data} />
        </>
      )}
    </div>
  );
}

function NothingYet({ start }: { start: (m: Mode) => void }) {
  return (
    <section className="card labs-empty">
      <span className="labs-empty-icon" aria-hidden="true">
        <Icon name="labs" size={22} />
      </span>
      <h2>No lab results yet</h2>
      <p className="muted">
        Add results from a blood test or other lab report: type them in as printed, or import a PDF or photo of the report and check what's read before saving. Each result is
        shown against the reference range the lab printed, so you can see where it sits and how it changes between tests.
      </p>
      <p className="muted small">Only you see them: never the Family board or the admin screens.</p>
      <div className="btn-row">
        <button className="btn btn-primary" onClick={() => start('add')}>
          Add results
        </button>
        <button className="btn" onClick={() => start('import')}>
          <Icon name="upload" size={15} />
          Import a report
        </button>
      </div>
    </section>
  );
}

// ---------- latest results ----------

function LatestResults({ data, open, setOpen }: { data: LabsData; open: string | null; setOpen: (k: string | null) => void }) {
  // Each marker's latest result, grouped by the collection it came from: newest first, panels by name.
  const groups = useMemo(() => {
    const map = new Map<string, { collected: string; lab: string; panel: string; markers: LabMarker[] }>();
    for (const m of data.markers) {
      const l = m.latest;
      const k = `${l.collected}\u0000${l.lab}\u0000${l.panel}`;
      const g = map.get(k) ?? { collected: l.collected, lab: l.lab, panel: l.panel, markers: [] };
      g.markers.push(m);
      map.set(k, g);
    }
    return [...map.values()].sort((a, b) => b.collected.localeCompare(a.collected) || a.panel.localeCompare(b.panel));
  }, [data]);

  return (
    <section className="card labs-latest" aria-labelledby="labs-latest-title">
      <div className="labs-card-head">
        <h2 id="labs-latest-title">Latest results</h2>
        <p className="muted small">Each marker's most recent result, against the range printed with it. Select a marker to see its history.</p>
      </div>
      {groups.map((g) => (
        <div className="labs-group" key={`${g.collected}|${g.lab}|${g.panel}`}>
          <h3 className="labs-group-title">
            {g.panel || 'Results'}
            <span className="muted">
              {' '}
              · {longDate(g.collected)}
              {g.lab && ` · ${g.lab}`}
            </span>
          </h3>
          <table className="labs-table">
            <thead>
              <tr>
                <th scope="col">Marker</th>
                <th scope="col">Result</th>
                <th scope="col">Reference range</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {g.markers.map((m) => (
                <Fragment key={m.key}>
                  <tr className={open === m.key ? 'is-open' : undefined}>
                    <th scope="row">
                      <button
                        id={`labs-marker-${m.key}`}
                        className="labs-marker"
                        aria-expanded={open === m.key}
                        aria-controls={`labs-detail-${m.key}`}
                        onClick={() => setOpen(open === m.key ? null : m.key)}
                      >
                        <Icon name="chevron-right" size={14} />
                        <span>{m.name}</span>
                      </button>
                    </th>
                    <td className="labs-result">
                      <Result r={m.latest} />
                    </td>
                    <td className="labs-range">
                      <LabRangeBar result={m.latest} />
                      <span className="small muted">{rangeLabel(m.latest)}</span>
                    </td>
                    <td className="labs-status-cell">
                      <LabStatusChip result={m.latest} />
                    </td>
                  </tr>
                  {open === m.key && (
                    <tr className="labs-detail-row">
                      <td colSpan={4}>
                        <MarkerDetail m={m} />
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </section>
  );
}

function Result({ r }: { r: LabResult }) {
  return (
    <>
      <strong>{r.valueText}</strong>
      {r.unit && <span className="muted"> {r.unit}</span>}
    </>
  );
}

/** One marker's history: a chart when two or more results share a scale, and every result as printed. */
function MarkerDetail({ m }: { m: LabMarker }) {
  const [err, setErr] = useState('');
  const unit = m.latest.unit;
  const r = m.latest.range;
  const drawn = m.points.length >= 2;
  const word = r?.kind === 'typical' ? 'Typical' : 'Range';
  const refLines = r ? [...(r.low !== null ? [{ value: r.low, label: `${word} from ${labNumber(r.low)}` }] : []), ...(r.high !== null ? [{ value: r.high, label: `${word} to ${labNumber(r.high)}` }] : [])] : [];
  const converted = [...new Set(m.history.filter((h) => h.value !== null && unitKey(h.unit) !== unitKey(unit) && m.points.some((p) => p.id === h.id)).map((h) => h.unit))];
  const bounded = m.history.filter((h) => h.qualifier).length;

  async function remove(res: LabResult) {
    if (!confirm(`Delete the ${m.name} result from ${longDate(res.collected)} (${res.valueText}${res.unit ? ` ${res.unit}` : ''})? It can't be undone.`)) return;
    setErr('');
    try {
      await sendJson('DELETE', `/labs/${encodeURIComponent(res.id)}`);
      notifyDataChanged();
    } catch (e) {
      setErr((e as Error).message);
    }
  }

  return (
    <div className="labs-detail" id={`labs-detail-${m.key}`}>
      {drawn ? (
        <>
          <TrendChart
            points={m.points.map((p) => ({ date: p.date, value: p.value }))}
            format={(v) => `${labNumber(v)}${unit ? ` ${unit}` : ''}`}
            tickFormat={labNumber}
            median={false}
            gapDays={100_000}
            height={200}
            refLines={refLines}
            label={`${m.name} over time${unit ? `, in ${unit}` : ''}, with the latest result's range`}
          />
          <p className="muted small">
            {unit ? `In ${unit}` : 'As printed'}
            {converted.length ? `; results in ${converted.join(', ')} converted.` : '.'}
            {r && ` Lines mark the latest result's ${r.kind === 'typical' ? 'typical adult range' : 'printed range'}; earlier labs may have printed others.`}
            {bounded > 0 && ` Results printed with < or > are listed below but not drawn.`}
            {m.otherUnits > 0 && ` ${m.otherUnits === 1 ? 'One result is' : `${m.otherUnits} results are`} in a unit that can't be converted, so ${m.otherUnits === 1 ? "it's" : "they're"} listed but not drawn.`}
          </p>
        </>
      ) : (
        <p className="muted small">
          {m.history.length === 1 ? 'One result so far. A chart appears once there are two that can be compared.' : 'These results are not in one unit that can be compared, so they are listed rather than drawn.'}
        </p>
      )}
      <table className="labs-history">
        <caption className="sr-only">Every {m.name} result, newest first</caption>
        <thead>
          <tr>
            <th scope="col">Collected</th>
            <th scope="col">Result</th>
            <th scope="col">Reference range</th>
            <th scope="col">Status</th>
            <th scope="col">
              <span className="sr-only">Delete</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {[...m.history].reverse().map((h) => (
            <tr key={h.id}>
              <td>
                {longDate(h.collected)}
                {(h.lab || h.name !== m.name) && <span className="small muted labs-printed">{[h.name !== m.name && `as “${h.name}”`, h.lab].filter(Boolean).join(' · ')}</span>}
              </td>
              <td>
                <Result r={h} />
              </td>
              <td className="small">{rangeLabel(h)}</td>
              <td>
                <LabStatusChip result={h} />
              </td>
              <td className="labs-delete-cell">
                <button className="btn btn-quiet btn-danger labs-delete" onClick={() => remove(h)} aria-label={`Delete the ${m.name} result from ${longDate(h.collected)}`}>
                  Delete
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {err && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {err}
        </p>
      )}
    </div>
  );
}

// ---------- all results by date ----------

function ByDate({ data }: { data: LabsData }) {
  const days = useMemo(() => {
    const map = new Map<string, LabsData['panels']>();
    for (const p of data.panels) {
      const k = `${p.collected}\u0000${p.lab}`;
      map.set(k, [...(map.get(k) ?? []), p]);
    }
    return [...map.values()];
  }, [data]);
  return (
    <section className="card labs-bydate" aria-labelledby="labs-bydate-title">
      <div className="labs-card-head">
        <h2 id="labs-bydate-title">Every result, by date</h2>
        <p className="muted small">Each collection as it was printed.</p>
      </div>
      {days.map((panels) => {
        const first = panels[0];
        const n = panels.reduce((a, p) => a + p.results.length, 0);
        return (
          <details key={`${first.collected}|${first.lab}`} className="labs-day">
            <summary>
              <strong>{longDate(first.collected)}</strong>
              <span className="muted">
                {first.lab && ` · ${first.lab}`} · {n} {n === 1 ? 'result' : 'results'}
              </span>
            </summary>
            {panels.map((p) => (
              <div key={p.panel} className="labs-day-panel">
                {p.panel && <h3 className="labs-group-title">{p.panel}</h3>}
                <table className="labs-table">
                  <thead>
                    <tr>
                      <th scope="col">Marker</th>
                      <th scope="col">Result</th>
                      <th scope="col">Reference range</th>
                      <th scope="col">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {p.results.map((r) => (
                      <tr key={r.id}>
                        <th scope="row" className="labs-name">
                          {r.name}
                        </th>
                        <td className="labs-result">
                          <Result r={r} />
                        </td>
                        <td className="labs-range">
                          <LabRangeBar result={r} />
                          <span className="small muted">{rangeLabel(r)}</span>
                        </td>
                        <td className="labs-status-cell">
                          <LabStatusChip result={r} />
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ))}
          </details>
        );
      })}
    </section>
  );
}

// ---------- adding results ----------

type Row = { id: number; name: string; valueText: string; unit: string; refText: string; panel: string };
type Group = { id: number; collected: string; lab: string; rows: Row[] };

const blankRow = (id: number): Row => ({ id, name: '', valueText: '', unit: '', refText: '', panel: '' });
const isBlank = (r: Row) => !r.name.trim() && !r.valueText.trim() && !r.unit.trim() && !r.refText.trim();

/** The server names a field by its index ("results[3].unit: …"); this says which row the person filled in. */
const FIELD: Record<string, string> = { collected: 'the date', name: 'the marker', valueText: 'the result', unit: 'the unit', refText: 'the range', lab: 'the lab', panel: 'the panel', refLow: 'the range', refHigh: 'the range' };

/** One form for typing results in and for checking what was read from a report. */
function ResultsForm({
  title,
  intro,
  initial,
  source,
  today,
  onSaved,
  onCancel,
}: {
  title: string;
  intro: ReactNode;
  initial: Group[];
  source: 'manual' | 'report';
  today: string;
  onSaved: (n: number) => void;
  onCancel: () => void;
}) {
  const [groups, setGroups] = useState(initial);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const nextId = useRef(1000);
  const filled = groups.reduce((a, g) => a + g.rows.filter((r) => !isBlank(r)).length, 0);

  const setGroup = (gid: number, patch: Partial<Group>) => setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, ...patch } : g)));
  const setRow = (gid: number, rid: number, patch: Partial<Row>) =>
    setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, rows: g.rows.map((r) => (r.id === rid ? { ...r, ...patch } : r)) } : g)));
  const addRow = (gid: number) => setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, rows: [...g.rows, blankRow(nextId.current++)] } : g)));
  const removeRow = (gid: number, rid: number) => setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, rows: g.rows.filter((r) => r.id !== rid) } : g)));

  async function save(e: FormEvent) {
    e.preventDefault();
    setErr('');
    const sent: { label: string; row: Record<string, string> }[] = [];
    for (const g of groups) {
      const rows = g.rows.filter((r) => !isBlank(r));
      if (!rows.length) continue;
      const on = groups.length > 1 ? ` for ${g.collected ? longDate(g.collected) : 'the undated results'}` : '';
      if (!g.collected) return setErr(`Add the date the sample was collected${on}.`);
      if (g.collected > today) return setErr("The collection date can't be in the future.");
      for (const r of rows) {
        const n = g.rows.indexOf(r) + 1;
        if (!r.name.trim() || !r.valueText.trim()) return setErr(`Row ${n}${on} needs both a marker and a result.`);
        sent.push({
          label: `Row ${n}${on}`,
          row: { collected: g.collected, lab: g.lab, name: r.name, valueText: r.valueText, unit: r.unit, refText: r.refText, panel: r.panel },
        });
      }
    }
    if (!sent.length) return setErr('Add at least one result.');
    setBusy(true);
    try {
      const res = await sendJson<{ added: number }>('POST', '/labs', { results: sent.map((s) => s.row), source });
      onSaved(res.added);
    } catch (e) {
      const m = /^results\[(\d+)\]\.(\w+): (.*)$/.exec((e as Error).message);
      setErr(m && sent[Number(m[1])] ? `${sent[Number(m[1])].label}: ${FIELD[m[2]] ?? m[2]} ${m[3]}.` : (e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="card labs-form" onSubmit={save} aria-labelledby="labs-form-title" noValidate>
      <div className="card-title-row">
        <h2 id="labs-form-title">{title}</h2>
        <button type="button" className="btn btn-quiet" onClick={onCancel}>
          Cancel
        </button>
      </div>
      {intro}
      <datalist id="labs-marker-names">
        {BIOMARKERS.map((b) => (
          <option key={b.key} value={b.name} />
        ))}
      </datalist>
      {groups.map((g, gi) => (
        <fieldset key={g.id} className="labs-fieldset">
          <legend className={groups.length > 1 ? 'labs-legend' : 'sr-only'}>{groups.length > 1 ? `Collection ${gi + 1} of ${groups.length}` : 'Results'}</legend>
          {source === 'report' && !g.collected && (
            <p className="small labs-review-note">
              <Icon name="alert" size={14} /> The report didn't show when these were collected. Add the date before saving.
            </p>
          )}
          <div className="labs-shared">
            <label className="labs-field">
              <span>Collected on</span>
              <input type="date" required max={today} value={g.collected} onChange={(e) => setGroup(g.id, { collected: e.target.value })} />
            </label>
            <label className="labs-field">
              <span>Lab (optional)</span>
              <input value={g.lab} maxLength={80} placeholder="e.g. Quest" onChange={(e) => setGroup(g.id, { lab: e.target.value })} />
            </label>
          </div>
          <div className="labs-rows">
            {g.rows.map((r, ri) => (
              <RowFields key={r.id} row={r} n={ri + 1} gid={g.id} set={(p) => setRow(g.id, r.id, p)} remove={() => removeRow(g.id, r.id)} />
            ))}
          </div>
          <button type="button" className="btn" onClick={() => addRow(g.id)}>
            Add a row
          </button>
        </fieldset>
      ))}
      {err && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {err}
        </p>
      )}
      <div className="btn-row">
        <button type="submit" className="btn btn-primary" disabled={busy || !filled}>
          {busy ? 'Saving…' : filled ? `Save ${filled} ${filled === 1 ? 'result' : 'results'}` : 'Save'}
        </button>
        <button type="button" className="btn btn-quiet" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
      </div>
    </form>
  );
}

function RowFields({ row, n, gid, set, remove }: { row: Row; n: number; gid: number; set: (p: Partial<Row>) => void; remove: () => void }) {
  const key = row.name.trim() ? matchBiomarker(row.name) : null;
  const units = key ? markerUnits(key) : [];
  const unitList = `labs-units-${gid}-${row.id}`;
  const matched = key ? BIOMARKERS.find((b) => b.key === key)!.name : null;
  return (
    <div className="labs-row" role="group" aria-label={`Row ${n}`}>
      <label className="labs-field labs-field-name">
        <span>Marker</span>
        <input list="labs-marker-names" value={row.name} maxLength={120} placeholder="e.g. Vitamin D" onChange={(e) => set({ name: e.target.value })} />
        {row.name.trim() && (
          <small className="muted">{matched ? (matched === row.name.trim() ? 'In the catalog' : `Read as ${matched}`) : 'Kept as printed'}</small>
        )}
      </label>
      <label className="labs-field labs-field-value">
        <span>Result</span>
        <input value={row.valueText} maxLength={60} placeholder="e.g. 32 or <0.5" onChange={(e) => set({ valueText: e.target.value })} />
      </label>
      <label className="labs-field labs-field-unit">
        <span>Unit</span>
        <input list={units.length ? unitList : undefined} value={row.unit} maxLength={30} placeholder={units[0] ?? 'e.g. mg/dL'} onChange={(e) => set({ unit: e.target.value })} />
        {units.length > 0 && (
          <datalist id={unitList}>
            {units.map((u) => (
              <option key={u} value={u} />
            ))}
          </datalist>
        )}
      </label>
      <label className="labs-field labs-field-range">
        <span>Reference range</span>
        <input value={row.refText} maxLength={80} placeholder="e.g. 30-100 or <200" onChange={(e) => set({ refText: e.target.value })} />
      </label>
      <label className="labs-field labs-field-panel">
        <span>Panel (optional)</span>
        <input value={row.panel} maxLength={80} placeholder="e.g. Lipid panel" onChange={(e) => set({ panel: e.target.value })} />
      </label>
      <button type="button" className="btn btn-quiet labs-remove" onClick={remove} aria-label={`Remove row ${n}`}>
        Remove
      </button>
    </div>
  );
}

// ---------- importing a report ----------

/** The draft rows as form groups: one per collection date, a missing date left for the person to fill in. */
function groupsFromDrafts(rows: LabDraft[]): Group[] {
  const by = new Map<string, LabDraft[]>();
  for (const r of rows) by.set(r.collected ?? '', [...(by.get(r.collected ?? '') ?? []), r]);
  let id = 1;
  return [...by].map(([collected, rs]) => ({
    id: id++,
    collected,
    lab: rs.find((r) => r.lab)?.lab ?? '',
    rows: rs.map((r) => ({ id: id++, name: r.name, valueText: r.valueText, unit: r.unit ?? '', refText: r.refText ?? '', panel: r.panel ?? '' })),
  }));
}

function ImportReport({ today, onSaved, onCancel }: { today: string; onSaved: (n: number) => void; onCancel: () => void }) {
  const mcfly = useApi<{ configured: boolean; limit: number; usedToday: number }>('/mcfly');
  const [phase, setPhase] = useState<'choose' | 'preparing' | 'reading'>('choose');
  const [err, setErr] = useState('');
  const [read, setRead] = useState<LabExtract | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const configured = mcfly.data?.configured ?? true;
  const left = mcfly.data ? Math.max(0, mcfly.data.limit - mcfly.data.usedToday) : null;
  const busy = phase !== 'choose';

  async function pick(file: File) {
    setErr('');
    setPhase('preparing');
    try {
      const blob = await prepareReport(file);
      setPhase('reading');
      const r = await readReport(blob);
      mcfly.reload();
      if (r.rows.length) setRead(r);
      else setErr(r.note ?? 'No results could be read from that file.');
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setPhase('choose');
      if (input.current) input.current.value = '';
    }
  }

  if (read) {
    return (
      <ResultsForm
        title="Check what was read"
        intro={
          <div className="labs-review-intro">
            <p className="muted small">
              Claude read {read.rows.length} {read.rows.length === 1 ? 'result' : 'results'} from your report. Compare each row with the report and fix anything that's off, or remove it.
              Nothing is saved until you press Save.
            </p>
            {read.note && (
              <p className="small labs-review-note">
                <Icon name="alert" size={14} /> {read.note}
              </p>
            )}
          </div>
        }
        initial={groupsFromDrafts(read.rows)}
        source="report"
        today={today}
        onSaved={onSaved}
        onCancel={onCancel}
      />
    );
  }

  return (
    <section className="card labs-import" aria-labelledby="labs-import-title">
      <div className="card-title-row">
        <h2 id="labs-import-title">Import a report</h2>
        <button className="btn btn-quiet" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
      </div>
      <ul className="labs-import-notes">
        <li>Choose a PDF, or a photo or screenshot of your lab report, up to 4 MB. Photos are made smaller on this device first.</li>
        <li>
          It's sent to <strong>Claude, Anthropic's AI</strong>, to read the results. healthOS doesn't keep the file.
        </li>
        <li>
          Reading a report counts as one of your Ask McFly questions today{left !== null && ` (you have ${left} left)`}.
        </li>
        <li>You check every row before anything is saved.</li>
      </ul>
      {!configured && <p className="note-bad">Reading reports isn't set up on this server yet. You can still type results in.</p>}
      <div className="btn-row">
        <button className="btn btn-primary" disabled={busy || !configured || left === 0} onClick={() => input.current?.click()}>
          <Icon name="upload" size={15} />
          Choose a file
        </button>
      </div>
      <input ref={input} type="file" accept={REPORT_ACCEPT} hidden onChange={(e) => e.target.files?.[0] && pick(e.target.files[0])} />
      <p className="muted small labs-progress" aria-live="polite">
        {phase === 'preparing' ? 'Preparing your file…' : phase === 'reading' ? 'Claude is reading your report. This can take up to a minute…' : left === 0 ? "You've used today's Ask McFly questions. Try again tomorrow, or type the results in." : ''}
      </p>
      {err && (
        <p className="note-bad" role="alert">
          <Icon name="alert" size={15} /> {err}
        </p>
      )}
    </section>
  );
}
