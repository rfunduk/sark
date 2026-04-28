defmodule Sark.Plugin.Loader do
  @moduledoc """
  Reads a plugin directory off disk into a `Sark.Plugin.Spec`.

  Plugin layout:

    * `migrations/` — required, forward-only SQL files (`NNNN_name.sql`)
    * `queries.yml` — optional, MCP tool definitions (+ optional `include:`,
      `allow_sql:` flags)
  """

  alias Sark.Plugin.Migrations
  alias Sark.Plugin.Query.YAML, as: QueriesYAML
  alias Sark.Plugin.Spec

  @spec load!(Path.t()) :: Spec.t()
  def load!(dir) do
    abs = Path.expand(dir)

    unless File.dir?(abs) do
      raise "plugin: not a directory: #{abs}"
    end

    name = Path.basename(abs)

    if name == "" or String.contains?(name, [".", "/"]) do
      raise "plugin #{abs}: invalid plugin name `#{name}` (basename must be a simple identifier)"
    end

    migrations = Migrations.discover!(abs)
    {queries, opts} = QueriesYAML.load(abs)

    %Spec{
      name: name,
      dir: abs,
      migrations: migrations,
      queries: queries,
      allow_sql: Map.get(opts, :allow_sql, false)
    }
  end
end
