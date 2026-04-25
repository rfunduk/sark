defmodule Sark.Plugin.Loader do
  @moduledoc """
  Reads a plugin directory off disk into a `Sark.Plugin.Spec`.

  Loads L0 (`schema.sql` + `metadata.yml`) and L1 (`queries.yml`, optional).
  L2+ (`workers.yml`, `feeds.yml`) are still ignored.
  """

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

    schema_sql = read_required!(abs, "schema.sql")
    metadata = read_metadata!(abs)
    queries = QueriesYAML.load(abs)

    %Spec{
      name: name,
      dir: abs,
      schema_sql: schema_sql,
      metadata: metadata,
      queries: queries
    }
  end

  defp read_required!(dir, file) do
    path = Path.join(dir, file)

    case File.read(path) do
      {:ok, body} -> body
      {:error, :enoent} -> raise "plugin #{dir}: missing required file `#{file}`"
      {:error, reason} -> raise "plugin #{dir}: cannot read `#{file}` (#{inspect(reason)})"
    end
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
        raise "plugin #{dir}: missing required file `metadata.yml`"

      {:error, reason} ->
        raise "plugin #{dir}: cannot parse metadata.yml (#{inspect(reason)})"
    end
  end
end
