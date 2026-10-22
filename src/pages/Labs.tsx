// Lab tests: blood panels and other lab results, against each lab's own reference ranges.
// Placeholder from the shared scaffold; the lab tests builder fills it in.
import type { Status } from '../../shared/types.ts';

export function Labs({ status: _status, params: _params }: { status: Status; params: URLSearchParams }) {
  return (
    <div className="page page-wide">
      <header className="page-head">
        <div>
          <h1>Lab tests</h1>
          <p>Coming soon.</p>
        </div>
      </header>
    </div>
  );
}
