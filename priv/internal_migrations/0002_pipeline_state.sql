CREATE TABLE _pipeline_state (
  pipeline   TEXT PRIMARY KEY,
  disabled   INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
