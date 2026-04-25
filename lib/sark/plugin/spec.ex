defmodule Sark.Plugin.Spec do
  @moduledoc """
  In-memory representation of a plugin loaded from disk.

  Plugin name is the basename of `dir` (e.g. `/srv/sark-plugins/jean` → `"jean"`).
  Used to derive the per-plugin SQLite filename (`{data_dir}/{name}.db`) and
  the registered DB pool names.
  """

  @enforce_keys [:name, :dir, :schema_sql, :metadata]
  defstruct [:name, :dir, :schema_sql, :metadata]

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          schema_sql: String.t(),
          metadata: map()
        }
end
