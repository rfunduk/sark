defmodule Sark.Plugin.Loader do
  @moduledoc """
  Reads a plugin directory off disk into a `Sark.Plugin.Spec`.

  Plugin name comes from the caller (config map key in production), not
  the dir basename — that decouples the plugin's identity (used for tool
  routing, DB filename, pool registry, token scopes) from on-disk
  layout, so renaming a plugin's directory doesn't silently break
  tokens or URLs.

  Plugin layout:

    * `migrations/` — required, forward-only SQL files (`NNNN_name.sql`)
    * `queries.yml` — optional, MCP tool definitions (+ optional `include:`,
      `allow_sql:` flags)
  """

  alias Sark.Plugin.Migrations
  alias Sark.Plugin.Query.YAML, as: QueriesYAML
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Worker.YAML, as: WorkersYAML

  @name_re ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @spec load!(String.t(), Path.t()) :: Spec.t()
  def load!(name, dir) when is_binary(name) and is_binary(dir) do
    unless Regex.match?(@name_re, name) do
      raise "plugin: invalid plugin name `#{name}` — must match #{Regex.source(@name_re)}"
    end

    abs = Path.expand(dir)

    unless File.dir?(abs) do
      raise "plugin #{name}: not a directory: #{abs}"
    end

    migrations = Migrations.discover!(abs)
    {queries, opts} = QueriesYAML.load(abs)
    workers = WorkersYAML.load(abs)

    %Spec{
      name: name,
      dir: abs,
      migrations: migrations,
      queries: queries,
      workers: workers,
      allow_sql: Map.get(opts, :allow_sql, false),
      patchable: Map.get(opts, :patchable, %{})
    }
  end
end
