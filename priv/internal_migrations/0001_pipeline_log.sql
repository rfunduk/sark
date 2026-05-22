CREATE TABLE _pipeline_log (
  run_id       TEXT    PRIMARY KEY,
  pipeline     TEXT    NOT NULL,
  started_at   TEXT    NOT NULL,
  finished_at  TEXT    NOT NULL,
  status       TEXT    NOT NULL,
  error        TEXT,
  triggered_by TEXT    NOT NULL
);

CREATE INDEX _pipeline_log_started_at ON _pipeline_log(started_at);
CREATE INDEX _pipeline_log_pipeline ON _pipeline_log(pipeline);

CREATE TABLE _pipeline_step_log (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id                TEXT    NOT NULL,
  step_index            INTEGER NOT NULL,
  step_type             TEXT    NOT NULL,
  started_at            TEXT    NOT NULL,
  finished_at           TEXT    NOT NULL,
  status                TEXT    NOT NULL,
  error                 TEXT,
  exit_code             INTEGER,
  stdout_bytes          INTEGER,
  stderr_tail           TEXT,
  tool_name             TEXT,
  row_count             INTEGER,
  model                 TEXT,
  turns                 INTEGER,
  stop_reason           TEXT,
  input_tokens          INTEGER,
  output_tokens         INTEGER,
  cache_read_tokens     INTEGER,
  cache_creation_tokens INTEGER,
  service_tier          TEXT,
  final_output          TEXT,
  FOREIGN KEY (run_id) REFERENCES _pipeline_log(run_id) ON DELETE CASCADE
);

CREATE INDEX _pipeline_step_log_run_id ON _pipeline_step_log(run_id);
