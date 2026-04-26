defmodule Sark.Plugin.Loader do
  @moduledoc """
  Reads a plugin directory off disk into a `Sark.Plugin.Spec`.

  Loads L0 (`migrations/`) and L1 (`queries.yml`, optional). `metadata.yml`
  is optional and surfaces in catalog output if present. L2+ (`workers.yml`,
  `feeds.yml`) are still ignored.
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
    metadata = read_metadata!(abs)
    queries = QueriesYAML.load(abs)

    %Spec{
      name: name,
      dir: abs,
      migrations: migrations,
      metadata: metadata,
      queries: queries
    }
  end

  defp read_metadata!(dir) do
    path = Path.join(dir, "metadata.yml")

    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) ->
        map

      {:ok, nil} ->
        %{}

      {:ok, other} ->
        raise "plugin #{dir}: metadata.yml must be a map, got #{inspect(other)}"

      {:error, %YamlElixir.FileNotFoundError{}} ->
        %{}

      {:error, reason} ->
        raise "plugin #{dir}: cannot parse metadata.yml (#{inspect(reason)})"
    end
  end
end
