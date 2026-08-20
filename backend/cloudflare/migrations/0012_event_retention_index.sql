-- Normalized earthquake facts become eligible for deletion at the daily
-- relay sweep's 89-day cutoff; a delayed or failed cleanup can postpone their
-- removal. The canonical events table already indexes last_updated_utc; give
-- the revision table the matching index so the sweep avoids a full scan.
CREATE INDEX IF NOT EXISTS idx_revisions_recorded_at
  ON event_revisions(recorded_at_utc);
