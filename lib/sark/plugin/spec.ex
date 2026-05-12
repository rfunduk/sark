defmodule Sark.Plugin.Spec do
  @moduledoc """
  In-memory representation of a plugin loaded from disk.

  Plugin name is the basename of `dir` (e.g. `/srv/sark-plugins/jean` → `"jean"`).
  Used to derive the per-plugin SQLite filename (`{data_dir}/{name}.db`) and
  the registered DB pool names.

  `allow_sql` opts the plugin into the `sark_catalog` + `sark_sql` tools
  (live schema introspection + arbitrary read-only SELECT/WITH/PRAGMA).
  Default false — most plugins should expose a curated set of canned
  queries only.

  `patchable` is the allow-list of `{table, column}` paths the built-in
  `sark_patch` tool may touch. Map of table name → list of column names,
  both as strings. Default `%{}` — `sark_patch` rejects every call until
  the plugin author opts specific fields in. The tool is still registered
  so the agent sees a descriptive "no patchable fields configured" error
  rather than "tool not found".
  """

  @enforce_keys [:name, :dir, :migrations]
  defstruct [
    :name,
    :dir,
    :migrations,
    allow_sql: false,
    patchable: %{},
    queries: [],
    workers: []
  ]

  @type migration :: %{version: pos_integer, path: String.t(), sql: String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          migrations: [migration],
          allow_sql: boolean(),
          patchable: %{optional(String.t()) => [String.t()]},
          queries: [Sark.Plugin.Query.t()],
          workers: [Sark.Plugin.Worker.t()]
        }
end
