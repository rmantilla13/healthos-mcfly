// The Body overview's key biomarkers card: the latest lab results against each lab's own range. Up to six, the most
// recently collected first; the rest are a tap away on the Lab tests page. The status is in words beside each bar.
import type { LabsData } from '../../../shared/labs.ts';
import type { Summary } from '../../../shared/types.ts';
import { fmtDate, href, useApi } from '../../lib.ts';
import { CardHead } from '../../pages/Home.tsx';
import { LabRangeBar, statusLabel } from '../LabRange.tsx';

const SHOWN = 6;

export function BiomarkersCard({ s: _s, date: _date }: { s: Summary; date: string | null }) {
  const { data, error } = useApi<LabsData>('/labs');
  // Newest collection first; the catalog's order within a day (a stable sort keeps it).
  const markers = data ? [...data.markers].sort((a, b) => b.latest.collected.localeCompare(a.latest.collected)).slice(0, SHOWN) : [];
  const newest = markers[0]?.latest.collected;

  return (
    <article className="card metric labs-card">
      <CardHead title="Key biomarkers" to={href('labs')} />
      {!data ? (
        <p className="metric-empty">{error ? "Couldn't load your lab results." : 'Loading…'}</p>
      ) : !markers.length ? (
        <div className="metric-empty">
          <span>No lab results yet. Add a blood test to see each result against the lab's range.</span>
          <a href={href('labs')}>Add lab results</a>
        </div>
      ) : (
        <>
          <ul className="labs-card-list">
            {markers.map((m) => (
              <li key={m.key}>
                <span className="labs-card-name">{m.name}</span>
                <span className="labs-card-value">
                  {m.latest.valueText}
                  {m.latest.unit && <small> {m.latest.unit}</small>}
                </span>
                <LabRangeBar result={m.latest} compact />
                <span className={`labs-card-status is-${m.latest.status ?? 'none'}`}>{statusLabel(m.latest)}</span>
              </li>
            ))}
          </ul>
          <div className="metric-foot">
            <span>{data.demo ? 'Demo results' : `Latest ${fmtDate(newest!, { month: 'short', day: 'numeric', year: 'numeric' })}`}</span>
            <a href={href('labs')} className="labs-card-all">
              View all{data.markers.length > SHOWN ? ` ${data.markers.length}` : ''}
            </a>
          </div>
        </>
      )}
    </article>
  );
}
