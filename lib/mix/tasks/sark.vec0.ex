defmodule Mix.Tasks.Sark.Vec0 do
  @shortdoc "Download the sqlite-vec (vec0) loadable for this host"

  @moduledoc """
  Download + install the `sqlite-vec` (`vec0`) loadable extension into
  `priv/sqlite_vec/` for the current OS/arch.

  Runs at image build time (per-arch native build leg) and once locally for
  development. The loadable is sha-verified and asserted to be a 64-bit build
  before it is written.

      mix sark.vec0          # install if missing
      mix sark.vec0 --force  # re-download even if present
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean])
    {:ok, _} = Application.ensure_all_started(:req)
    Sark.SqliteVec.install!(force: opts[:force] || false)
  end
end
