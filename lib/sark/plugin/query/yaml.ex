defmodule Sark.Plugin.Query.YAML do
  @moduledoc """
  Read a plugin's `queries.yml` from disk.

  Format:

      version: 1
      queries:
        <name>:
          description: ...
          returns: results | scalar | count | none
          write: false
          params: { ... }
          format: list | json | table | { kind: template, template: "..." }
          sql: |
            SELECT ...

  Returns `[]` if the file is absent (queries.yml is optional).
  """

  alias Sark.Plugin.Query

  @spec load(Path.t()) :: [Query.t()]
  def load(plugin_dir) do
    path = Path.join(plugin_dir, "queries.yml")

    case YamlElixir.read_from_file(path) do
      {:ok, nil} ->
        []

      {:ok, doc} when is_map(doc) ->
        parse_doc!(doc, path)

      {:ok, other} ->
        raise "queries.yml: top-level must be a map, got #{inspect(other)}"

      {:error, %YamlElixir.FileNotFoundError{}} ->
        []

      {:error, reason} ->
        raise "queries.yml at #{path}: cannot parse (#{inspect(reason)})"
    end
  end

  defp parse_doc!(doc, path) do
    case Map.get(doc, "version") do
      1 -> :ok
      v -> raise "queries.yml at #{path}: version must be 1, got #{inspect(v)}"
    end

    queries = Map.get(doc, "queries", %{})

    unless is_map(queries) do
      raise "queries.yml at #{path}: queries must be a map, got #{inspect(queries)}"
    end

    queries
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {name, entry} -> Query.parse!(name, entry) end)
  end
end
