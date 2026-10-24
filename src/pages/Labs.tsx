// Blood records (#/labs): blood panels and other lab results, each against the reference range printed by the lab,
// and the original reports, kept in the person's account (Lab documents). Results are typed in as printed, or read
// from a kept report by Claude, only when the person asks, and checked by them before anything is saved. A status
// only says where a number sits against a range; nothing here is a diagnosis.
import '../styles/records.css';
import { Fragment, type ReactNode, type RefObject, useEffect, useMemo, useRef, useState } from 'react';
import {
  BIOMARKERS,
  type LabDocument,
  type LabDocuments,
  type LabDraft,
  type LabExtract,
  type LabMarker,
  type LabReader,
  type LabResult,
  type LabsData,
  biomarker,
  draftGroups,
  isOther,
  markerKey,
  markerUnits,
  specimenOf,
  undrawnReasons,
  unitKey,
} from '../../shared/labs.ts';
import type { Status } from '../../shared/types.ts';
import { TrendChart } from '../charts/Charts.tsx';
import { Icon } from '../components/Icon.tsx';
import { LabRangeBar, LabStatusChip, labNumber, rangeLabel } from '../components/LabRange.tsx';
import { REPORT_ACCEPT, prepareReport, readDocument, reportName, uploadDocument } from '../labsUpload.ts';
import { fmtDate, notifyDataChanged, sendJson, useApi } from '../lib.ts';
import { PageIntro } from '../components/PageIntro.tsx';

const longDate = (d: string) => fmtDate(d, { month: 'short', day: 'numeric', year: 'numeric' });
// Upload and read times are moments (epoch ms), shown in this device's own time zone.
const uploadedDay = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
const readDay = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' });

/** The form open under the intro: typing results in, or checking what was read from a report. */
type Mode = 'add' | 'review' | null;

/** What closing the open form would lose: rows typed in, rows read from a report, or a read still going. */
type Pending = 'none' | 'typed' | 'draft' | 'reading';
const DISCARD: Record<'typed' | 'draft', string> = {
  typed: 'Discard the results you’ve typed? They haven’t been saved.',
  draft: 'Discard the results read from your report? They haven’t been saved. The report stays in Lab documents, but reading it again counts as a new read.',
};

const NOT_SET_UP = "Reading reports isn't set up on this server yet. You can still type results in.";
const TURNED_OFF = 'Reading reports uses Ask McFly, which is turned off right now. You can still type results in.';

const readButtonId = (id: string) => `labs-doc-read-${id}`;
const documentUrl = (id: string) => `/api/labs/documents/${encodeURIComponent(id)}`;

export function Labs({ status: _status, params: _params }: { status: Status; params: URLSearchParams }) {
  const { data, error, loading } = useApi<LabsData>('/labs');
  const docs = useApi<LabDocuments>('/labs/documents');
  const reader = useApi<LabReader>('/labs/reader');
  const [mode, setMode] = useState<Mode>(null);
  const [pending, setPending] = useState<Pending>('none');
  const [review, setReview] = useState<{ doc: LabDocument; read: LabExtract } | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [notice, setNotice] = useState('');
  // Lab documents: an upload going (share sent, null while the file is prepared), what happened, the report whose
  // "Read the results?" is open, and the one being read.
  const [upload, setUpload] = useState<{ share: number | null } | null>(null);
  const [docNotice, setDocNotice] = useState('');
  const [docError, setDocError] = useState<{ id: string | null; message: string } | null>(null);
  const [offer, setOffer] = useState<string | null>(null);
  const [reading, setReading] = useState<string | null>(null);
  const today = data?.today ?? new Date().toLocaleDateString('en-CA');
  const addButton = useRef<HTMLButtonElement>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const noticeRef = useRef<HTMLParagraphElement>(null);
  const docNoticeRef = useRef<HTMLParagraphElement>(null);
  const offerRef = useRef<HTMLParagraphElement>(null);
  const focusNotice = useRef(false);
  const focusDocNotice = useRef(false);
  const focusOffer = useRef(false);

  // After a save, focus goes to the notice saying what was added, once the form it came from has gone.
  useEffect(() => {
    if (focusNotice.current && notice) noticeRef.current?.focus();
    focusNotice.current = false;
  }, [notice]);
  // After a delete, to the notice saying so (the row and its buttons are gone).
  useEffect(() => {
    if (focusDocNotice.current && docNotice) docNoticeRef.current?.focus();
    focusDocNotice.current = false;
  }, [docNotice]);
  // After an upload, to the offer to read it, once its row is listed (the button that opened the picker may be gone).
  useEffect(() => {
    if (focusOffer.current && offerRef.current) {
      offerRef.current.focus();
      focusOffer.current = false;
    }
  }, [offer, docs.data]);

  /** Open the add form or close it: never losing typed rows, a draft or a read without asking. */
  const start = (m: Mode) => {
    if (pending === 'reading') return;
    if ((pending === 'typed' || pending === 'draft') && !confirm(DISCARD[pending])) return;
    setNotice('');
    setPending('none');
    setReview(null);
    setMode(m);
  };
  const cancel = () => {
    const from = review?.doc.id;
    setPending('none');
    setMode(null);
    setReview(null);
    (from ? document.getElementById(readButtonId(from)) : addButton.current)?.focus();
  };
  const saved = (n: number) => {
    setPending('none');
    setMode(null);
    setReview(null);
    focusNotice.current = true;
    setNotice(`Added ${n} ${n === 1 ? 'result' : 'results'}.`);
    notifyDataChanged();
  };

  /** Keep a report: prepared on this device, then sent with its progress. Reading it is offered, never started. */
  async function keep(file: File) {
    setDocNotice('');
    setDocError(null);
    setOffer(null);
    setUpload({ share: null });
    try {
      const blob = await prepareReport(file);
      setUpload({ share: 0 });
      const { document: doc } = await uploadDocument(blob, reportName(file, blob), (share) => setUpload({ share }));
      docs.reload();
      setDocNotice(`Saved ${doc.name}.`);
      focusOffer.current = true;
      setOffer(doc.id);
    } catch (e) {
      setDocError({ id: null, message: (e as Error).message });
    } finally {
      setUpload(null);
      if (fileInput.current) fileInput.current.value = '';
    }
  }
  const chooseFile = () => fileInput.current?.click();

  /** Read a kept report's results into the "Check what was read" form, asking first before a form's rows are lost. */
  async function read(doc: LabDocument) {
    if (pending === 'reading') return;
    if ((pending === 'typed' || pending === 'draft') && !confirm(DISCARD[pending])) return;
    setNotice('');
    setDocNotice('');
    setDocError(null);
    setMode(null);
    setReview(null);
    setPending('reading');
    setReading(doc.id);
    try {
      const r = await readDocument(doc.id);
      if (r.rows.length) {
        setReview({ doc, read: r });
        setMode('review');
        setOffer(null);
        setPending('draft');
      } else {
        setDocError({ id: doc.id, message: r.note ?? 'No results could be read from that file.' });
        setPending('none');
      }
    } catch (e) {
      setDocError({ id: doc.id, message: (e as Error).message });
      setPending('none');
    } finally {
      setReading(null);
      reader.reload();
      docs.reload();
    }
  }

  async function remove(doc: LabDocument) {
    if (!confirm(`Delete ${doc.name}? It can't be undone.`)) return;
    setDocError(null);
    try {
      await sendJson('DELETE', `/labs/documents/${encodeURIComponent(doc.id)}`);
      if (offer === doc.id) setOffer(null);
      focusDocNotice.current = true;
      setDocNotice(`Deleted ${doc.name}.`);
      docs.reload();
    } catch (e) {
      setDocError({ id: doc.id, message: (e as Error).message });
    }
  }

  const closeOffer = (id: string) => {
    setOffer(null);
    document.getElementById(readButtonId(id))?.focus();
  };

  const tools = (
    <div className="btn-row">
      <button ref={addButton} className="btn btn-primary" aria-pressed={mode === 'add'} disabled={pending === 'reading'} onClick={() => start(mode === 'add' ? null : 'add')}>
        <Icon name="plus" size={15} />
        Add blood result
      </button>
      <button className="btn" disabled={upload !== null} onClick={chooseFile}>
        <Icon name="upload" size={15} />
        Upload report
      </button>
    </div>
  );

  return (
    <div className={`page page-wide labs records ${loading ? 'is-refreshing' : ''}`}>
      <PageIntro title="Your records, together." sub="Blood results and original reports, saved to your private account." actions={tools} />
      {/* Always there, so the change of text is announced. */}
      <div className="labs-notice" role="status">
        {notice && (
          <p className="note-good" tabIndex={-1} ref={noticeRef}>
            <Icon name="check" size={15} /> {notice}
          </p>
        )}
      </div>
      {mode === 'add' && (
        <ResultsForm
          title="Add blood results"
          intro={<p className="muted small">Type each result as it's printed on your report, with the reference range printed beside it. Leave a row empty to skip it.</p>}
          initial={[{ id: 1, collected: today, lab: '', dateDropped: false, rows: [blankRow(1), blankRow(2), blankRow(3)] }]}
          source="manual"
          today={today}
          onSaved={saved}
          onCancel={cancel}
          onPending={setPending}
        />
      )}
      {mode === 'review' && review && (
        <ResultsForm
          title="Check what was read"
          intro={
            <div className="labs-review-intro">
              <p className="muted small">
                Claude read {review.read.rows.length} {review.read.rows.length === 1 ? 'result' : 'results'} from <strong>{review.doc.name}</strong>. Compare each row with the
                report (
                <a href={documentUrl(review.doc.id)} target="_blank" rel="noopener noreferrer">
                  open it in a new tab
                </a>
                ) and fix anything that's off, or remove it. Nothing is saved until you press Save.
              </p>
              {review.read.note && (
                <p className="small labs-review-note">
                  <Icon name="alert" size={14} /> {review.read.note}
                </p>
              )}
            </div>
          }
          initial={groupsFromDrafts(review.read.rows)}
          source="report"
          today={today}
          onSaved={saved}
          onCancel={cancel}
        />
      )}

      <section className="card records-card" aria-labelledby="records-results-title">
        <div className="records-card-head">
          <h2 id="records-results-title">Blood results</h2>
          {data && <span className="badge badge-sage">{count(data.count, 'result')}</span>}
        </div>
        {error && !data ? (
          <p className="note-bad records-loading">Couldn't load your blood results: {error.message}</p>
        ) : !data ? (
          <p className="muted small records-loading">Loading…</p>
        ) : data.count === 0 ? (
          <Empty icon="vitals" title="Your results, over time" text="Add the value, unit and reference range exactly as printed by your laboratory.">
            {mode !== 'add' && (
              <button className="btn" onClick={() => start('add')} disabled={pending === 'reading'}>
                Add a blood result
              </button>
            )}
          </Empty>
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
      </section>

      <section className="card records-card" aria-labelledby="records-docs-title">
        <div className="records-card-head">
          <h2 id="records-docs-title">Lab documents</h2>
          {docs.data && <span className="badge badge-sage">{count(docs.data.documents.length, 'file')}</span>}
        </div>
        {/* Always there, so progress and what happened are announced. */}
        <div className="records-status" role="status">
          {upload && <p className="muted small">{upload.share === null ? 'Preparing your file…' : `Uploading… ${Math.round(upload.share * 100)}%`}</p>}
          {docNotice && (
            <p className="note-good" tabIndex={-1} ref={docNoticeRef}>
              <Icon name="check" size={15} /> {docNotice}
            </p>
          )}
        </div>
        {docError?.id === null && (
          <p className="note-bad records-error" role="alert">
            <Icon name="alert" size={15} /> {docError.message}
          </p>
        )}
        {!docs.data ? (
          <p className={docs.error ? 'note-bad records-loading' : 'muted small records-loading'}>{docs.error ? `Couldn't load your lab documents: ${docs.error.message}` : 'Loading…'}</p>
        ) : docs.data.documents.length === 0 ? (
          <Empty icon="file-text" title="A home for your health history" text="Upload a PDF or image. Only your account can access it.">
            <button className="btn" onClick={chooseFile} disabled={upload !== null}>
              Upload a report
            </button>
          </Empty>
        ) : (
          <ul className="records-docs">
            {docs.data.documents.map((doc) => (
              <DocumentRow
                key={doc.id}
                doc={doc}
                offered={offer === doc.id}
                onOffer={() => (offer === doc.id ? closeOffer(doc.id) : setOffer(doc.id))}
                error={docError?.id === doc.id ? docError.message : null}
                onDelete={() => remove(doc)}
              >
                {offer === doc.id && (
                  <ReadOffer
                    doc={doc}
                    reader={reader}
                    reading={reading === doc.id}
                    busy={pending === 'reading'}
                    onRead={() => read(doc)}
                    onClose={() => closeOffer(doc.id)}
                    titleRef={offerRef}
                  />
                )}
              </DocumentRow>
            ))}
          </ul>
        )}
      </section>

      <p className="records-foot">
        Reference flags compare your entry with the range you provide, or a labelled typical range when there's none. They are not a diagnosis. Values in units that can't be
        converted are kept separate.
      </p>
      <input ref={fileInput} type="file" accept={REPORT_ACCEPT} hidden onChange={(e) => e.target.files?.[0] && keep(e.target.files[0])} />
    </div>
  );
}

const count = (n: number, word: string) => `${n.toLocaleString()} ${word}${n === 1 ? '' : 's'}`;

/** A card's first-run state: an icon, a line of what goes here, and the way to add it. */
function Empty({ icon, title, text, children }: { icon: 'vitals' | 'file-text'; title: string; text: string; children?: ReactNode }) {
  return (
    <div className="records-empty">
      <Icon name={icon} size={22} strokeWidth={1.4} />
      <h3>{title}</h3>
      <p>{text}</p>
      {children}
    </div>
  );
}

// ---------- lab documents ----------

const TYPE_LABEL: Record<LabDocument['mime'], string> = { 'application/pdf': 'PDF', 'image/jpeg': 'JPEG', 'image/png': 'PNG', 'image/webp': 'WebP' };
const fileSize = (bytes: number) => (bytes < 1024 * 1024 ? `${Math.max(1, Math.round(bytes / 1024))} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`);

function DocumentRow({
  doc,
  offered,
  onOffer,
  onDelete,
  error,
  children,
}: {
  doc: LabDocument;
  offered: boolean;
  onOffer: () => void;
  onDelete: () => void;
  error: string | null;
  /** The offer to read it, when open. */
  children?: ReactNode;
}) {
  return (
    <li className="records-doc">
      <div className="records-doc-main">
        <span className="records-doc-icon" aria-hidden="true">
          <Icon name={doc.mime === 'application/pdf' ? 'file-text' : 'image'} size={17} />
        </span>
        <div className="records-doc-text">
          <p className="records-doc-name">{doc.name}</p>
          <p className="records-doc-meta">
            {TYPE_LABEL[doc.mime]} · {fileSize(doc.size)} · Uploaded {uploadedDay.format(doc.uploadedAt)}
            {doc.readAt !== null && <span className="records-doc-read"> · Results read {readDay.format(doc.readAt)}</span>}
          </p>
        </div>
        <div className="records-doc-actions">
          <a className="btn btn-quiet" href={documentUrl(doc.id)} target="_blank" rel="noopener noreferrer" aria-label={`Open ${doc.name} in a new tab`}>
            Open
          </a>
          <button
            id={readButtonId(doc.id)}
            className="btn btn-quiet"
            aria-expanded={offered}
            aria-controls={offered ? `labs-doc-offer-${doc.id}` : undefined}
            aria-label={`Read the results from ${doc.name}`}
            onClick={onOffer}
          >
            Read results
          </button>
          <button className="btn btn-quiet btn-danger" onClick={onDelete} aria-label={`Delete ${doc.name}`}>
            Delete
          </button>
        </div>
      </div>
      {children}
      {error && (
        <p className="note-bad records-error" role="alert">
          <Icon name="alert" size={15} /> {error}
        </p>
      )}
    </li>
  );
}

/** What reading a report means, said before anything is sent: where it goes, what it counts as, and that rows are checked. */
function ReadOffer({
  doc,
  reader,
  reading,
  busy,
  onRead,
  onClose,
  titleRef,
}: {
  doc: LabDocument;
  reader: { data?: LabReader; error?: Error };
  reading: boolean;
  busy: boolean;
  onRead: () => void;
  onClose: () => void;
  titleRef: RefObject<HTMLParagraphElement | null>;
}) {
  const r = reader.data;
  const own = r?.source === 'own';
  const unavailable = r?.source === null ? (r.reason === 'off' ? TURNED_OFF : NOT_SET_UP) : null;
  const left = r && r.source !== null ? Math.max(0, r.limit - r.usedToday) : null;
  // Until it's known what reading would use, the button waits; if that can't be found out, the server decides.
  const unknown = !r && !reader.error;
  return (
    <div className="records-offer" id={`labs-doc-offer-${doc.id}`} role="group" aria-labelledby={`labs-doc-offer-title-${doc.id}`}>
      <p className="records-offer-title" id={`labs-doc-offer-title-${doc.id}`} tabIndex={-1} ref={titleRef}>
        Read the results from this report?
      </p>
      {unavailable ? (
        <p className="records-offer-off">{unavailable}</p>
      ) : (
        <ul className="records-offer-notes">
          <li>
            It's sent to <strong>Claude, Anthropic's AI</strong>, to read the results. The original stays here in Lab documents.
          </li>
          <li>
            {own ? (
              "It runs on your own Claude key, so it doesn't use the shared daily questions."
            ) : (
              <>Reading a report counts as one of your Ask McFly questions today{left !== null && ` (you have ${left} left)`}.</>
            )}
          </li>
          <li>You check every row before anything is saved.</li>
        </ul>
      )}
      {left === 0 && (
        <p className="note-bad">
          {own ? "You've used your own Claude key the most it takes in a day. Try again tomorrow, or type the results in." : "You've used today's Ask McFly questions. Try again tomorrow, or type the results in."}
        </p>
      )}
      <div className="btn-row">
        {!unavailable && (
          <button className="btn btn-primary" disabled={busy || unknown || left === 0} onClick={onRead}>
            {reading ? 'Reading…' : 'Read results'}
          </button>
        )}
        <button className="btn btn-quiet" onClick={onClose} disabled={reading}>
          {unavailable ? 'Close' : 'Not now'}
        </button>
      </div>
      <p className="muted small" aria-live="polite">
        {reading ? 'Claude is reading your report. This can take up to a minute…' : ''}
      </p>
    </div>
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
    <div className="labs-latest" role="group" aria-labelledby="labs-latest-title">
      <div className="labs-card-head">
        <h3 id="labs-latest-title">Latest results</h3>
        <p className="muted small">Each marker's most recent result, against the range printed with it. Select a marker to see its history.</p>
      </div>
      {groups.map((g) => (
        <div className="labs-group" key={`${g.collected}|${g.lab}|${g.panel}`}>
          <h4 className="labs-group-title">
            {g.panel || 'Results'}
            <span className="muted">
              {' '}
              · {longDate(g.collected)}
              {g.lab && ` · ${g.lab}`}
            </span>
          </h4>
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
    </div>
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
  // Why any result isn't drawn: the reason that applies to each, never a guess at units.
  const reasons = undrawnReasons(m);

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
            {refLines.length > 0 && ` Lines mark the latest result's ${r?.kind === 'typical' ? 'typical adult range' : 'printed range'}; earlier labs may have printed others.`}
            {reasons.length > 0 && ` ${reasons.join(' ')} Every result is listed below.`}
          </p>
        </>
      ) : (
        <p className="muted small">
          {m.history.length === 1 ? 'One result so far. A chart appears once there are two that can be compared.' : `A chart needs two results that can be drawn on one scale. ${reasons.join(' ')} Every result is listed below.`}
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
    <div className="labs-bydate" role="group" aria-labelledby="labs-bydate-title">
      <div className="labs-card-head">
        <h3 id="labs-bydate-title">Every result, by date</h3>
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
                {p.panel && <h4 className="labs-group-title">{p.panel}</h4>}
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
    </div>
  );
}

// ---------- adding results ----------

type Row = { id: number; name: string; valueText: string; unit: string; refText: string; panel: string };
/** One collection's rows. dateDropped: a date was read from the report but couldn't be used, so it's left to fill in. */
type Group = { id: number; collected: string; lab: string; dateDropped: boolean; rows: Row[] };

const blankRow = (id: number): Row => ({ id, name: '', valueText: '', unit: '', refText: '', panel: '' });
const isBlank = (r: Row) => !r.name.trim() && !r.valueText.trim() && !r.unit.trim() && !r.refText.trim();

/** The server names a field by its index ("results[3].unit: …"); this says which row the person filled in. */
const FIELD: Record<string, string> = { collected: 'the date', name: 'the marker', valueText: 'the result', unit: 'the unit', refText: 'the range', lab: 'the lab', panel: 'the panel', refLow: 'the range', refHigh: 'the range' };

/**
 * One form for typing results in and for checking what was read from a report. Only the Save button saves:
 * Enter (or Go on a phone keyboard) in a field never sends rows that haven't been checked.
 */
function ResultsForm({
  title,
  intro,
  initial,
  source,
  today,
  onSaved,
  onCancel,
  onPending,
}: {
  title: string;
  intro: ReactNode;
  initial: Group[];
  source: 'manual' | 'report';
  today: string;
  onSaved: (n: number) => void;
  onCancel: () => void;
  /** Told whether any row has been typed in, so the page asks before throwing them away. */
  onPending?: (p: Pending) => void;
}) {
  const [groups, setGroups] = useState(initial);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const nextId = useRef(1000);
  const heading = useRef<HTMLHeadingElement>(null);
  const filled = groups.reduce((a, g) => a + g.rows.filter((r) => !isBlank(r)).length, 0);

  // Focus moves to the form as it opens, so it isn't left on a button that has gone.
  useEffect(() => heading.current?.focus(), []);
  useEffect(() => onPending?.(filled > 0 ? 'typed' : 'none'), [filled, onPending]);

  const setGroup = (gid: number, patch: Partial<Group>) => setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, ...patch } : g)));
  const setRow = (gid: number, rid: number, patch: Partial<Row>) =>
    setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, rows: g.rows.map((r) => (r.id === rid ? { ...r, ...patch } : r)) } : g)));
  const addRow = (gid: number) => setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, rows: [...g.rows, blankRow(nextId.current++)] } : g)));
  const removeRow = (gid: number, rid: number) => setGroups((gs) => gs.map((g) => (g.id === gid ? { ...g, rows: g.rows.filter((r) => r.id !== rid) } : g)));

  async function save() {
    setErr('');
    const sent: { label: string; row: Record<string, string> }[] = [];
    for (const g of groups) {
      const rows = g.rows.filter((r) => !isBlank(r));
      if (!rows.length) continue;
      // Two collections on one day are from different labs: say which.
      const sameDay = g.lab && groups.filter((o) => o.collected === g.collected).length > 1 ? ` from ${g.lab}` : '';
      const on = groups.length > 1 ? ` for ${g.collected ? longDate(g.collected) : 'the undated results'}${sameDay}` : '';
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
    <form className="card labs-form" onSubmit={(e) => e.preventDefault()} aria-labelledby="labs-form-title" noValidate>
      <div className="card-title-row">
        <h2 id="labs-form-title" tabIndex={-1} ref={heading}>
          {title}
        </h2>
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
              <Icon name="alert" size={14} />{' '}
              {g.dateDropped ? "The date read from the report doesn't look right. Check it and add it." : "The report didn't show when these were collected. Add the date before saving."}
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
        <button type="button" className="btn btn-primary" disabled={busy || !filled} onClick={save}>
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
  // Matched as the server will store it: a row on a urine or stool panel is never a blood marker.
  const found = row.name.trim() ? markerKey(row.name, row.panel) : null;
  const key = found && !isOther(found) ? found : null;
  const specimen = found && !key ? specimenOf(row.name, row.panel) : null;
  const units = key ? markerUnits(key) : [];
  const unitList = `labs-units-${gid}-${row.id}`;
  const matched = key ? biomarker(key)!.name : null;
  return (
    <div className="labs-row" role="group" aria-label={`Row ${n}`}>
      <label className="labs-field labs-field-name">
        <span>Marker</span>
        <input list="labs-marker-names" value={row.name} maxLength={120} placeholder="e.g. Vitamin D" onChange={(e) => set({ name: e.target.value })} />
        {row.name.trim() && (
          <small className="muted">
            {matched ? (matched === row.name.trim() ? 'In the catalog' : `Read as ${matched}`) : specimen ? `Kept as printed, as a ${specimen} result` : 'Kept as printed'}
          </small>
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

// ---------- reading a report ----------

/** The draft rows as form groups: one per collection date and lab, a missing date left for the person to fill in. */
function groupsFromDrafts(rows: LabDraft[]): Group[] {
  let id = 1;
  return draftGroups(rows).map((g) => ({
    id: id++,
    collected: g.collected,
    lab: g.lab,
    dateDropped: g.dateDropped,
    rows: g.rows.map((r) => ({ id: id++, name: r.name, valueText: r.valueText, unit: r.unit ?? '', refText: r.refText ?? '', panel: r.panel ?? '' })),
  }));
}
