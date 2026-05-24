-- Sark-managed work queue for the RAG/embed surface. Lives in the
-- plugin DB so per-table AFTER INSERT/UPDATE/DELETE triggers can
-- enqueue rows inside the same write transaction as the data write
-- (atomic durability; no ATTACH needed).
--
-- The queue is shared across all embed-configured tables in the
-- plugin; `table_name` distinguishes them. Drain happens out-of-band
-- via a sark-internal GenServer (not user-facing).

CREATE TABLE _embed_queue (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name   TEXT    NOT NULL,
  row_pk       TEXT    NOT NULL,
  op           TEXT    NOT NULL,                          -- 'INSERT' | 'UPDATE' | 'DELETE'
  enqueued_at  TEXT    NOT NULL,
  status       TEXT    NOT NULL DEFAULT 'pending',        -- 'pending' | 'failed'
  attempts     INTEGER NOT NULL DEFAULT 0,
  last_error   TEXT
);

CREATE INDEX _embed_queue_status_id ON _embed_queue(status, id);
