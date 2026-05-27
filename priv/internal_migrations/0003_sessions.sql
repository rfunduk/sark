-- Per-plugin session store. Each row maps a sark-issued opaque session
-- token (`sk_session_<random>`) to the upstream refresh token + the
-- last-known identity envelope. AuthPlug looks up by `token`; refresh
-- machinery reads `upstream_refresh` to renew claims without bothering
-- the client.
CREATE TABLE _sessions (
  token              TEXT PRIMARY KEY,
  upstream_refresh   TEXT,                                  -- nullable if IdP didn't issue one
  claims_json        TEXT NOT NULL,
  created_at         TEXT NOT NULL,
  last_refreshed_at  TEXT NOT NULL,
  expires_at         TEXT NOT NULL                          -- ISO-8601; soft expiry, triggers JIT refresh
);

CREATE INDEX _sessions_expires_at_idx ON _sessions (expires_at);
