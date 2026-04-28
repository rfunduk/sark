defmodule Sark.Plugin.Spec do
  @moduledoc """
  In-memory representation of a plugin loaded from disk.

  Plugin name is the basename of `dir` (e.g. `/srv/sark-plugins/jean` → `"jean"`).
  Used to derive the per-plugin SQLite filename (`{data_dir}/{name}.db`) and
  the registered DB pool names.

  `allow_sql` opts the plugin into the `catalog` + `sql_query` tools (live
  schema introspection + arbitrary read-only SELECT/WITH/PRAGMA). Default
  false — most plugins should expose a curated set of canned queries only.
  """

  @enforce_keys [:name, :dir, :migrations]
  defstruct [:name, :dir, :migrations, allow_sql: false, queries: []]

  @type migration :: %{version: pos_integer, path: String.t(), sql: String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          migrations: [migration],
          allow_sql: boolean(),
          queries: [Sark.Plugin.Query.t()]
        }
end
