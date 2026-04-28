defmodule Sark.Plugin.Query.YAML do
  @moduledoc """
  Read a plugin's `queries.yml` from disk.

  Format:

      allow_sql: false       # optional — opt into catalog + sql_query tools
      include:               # optional — list of file paths or globs,
        - queries/*.yml      #   relative to plugin dir. Each must be a
        - queries/extra.yml  #   YAML doc with the same top-level shape.
      queries:
        <name>:
          description: ...
          returns: results | scalar | count | none
          write: false
          params: { ... }
          format: list | json | table | { kind: template, template: "..." }
          sql: |
            SELECT ...

  All `queries:` blocks across `queries.yml` and any included files are
  merged into a single map. Duplicate names raise.

  Returns `{queries, opts}` — `queries` is a list of parsed `Query.t()`,
  `opts` is a map of plugin-wide flags (`%{allow_sql: bool}`). Returns
  `{[], %{allow_sql: false}}` if `queries.yml` is absent.
  """

  alias Sark.Plugin.Query

  @type opts :: %{allow_sql: boolean()}

  @spec load(Path.t()) :: {[Query.t()], opts()}
  def load(plugin_dir) do
    path = Path.join(plugin_dir, "queries.yml")

    case YamlElixir.read_from_file(path) do
      {:ok, nil} ->
        {[], default_opts()}

      {:ok, doc} when is_map(doc) ->
        parse_root!(doc, plugin_dir, path)

      {:ok, other} ->
        raise "queries.yml: top-level must be a map, got #{inspect(other)}"

      {:error, %YamlElixir.FileNotFoundError{}} ->
        {[], default_opts()}

      {:error, reason} ->
        raise "queries.yml at #{path}: cannot parse (#{inspect(reason)})"
    end
  end

  defp default_opts, do: %{allow_sql: false}

  defp parse_root!(doc, plugin_dir, root_path) do
    base = entries_from_doc!(doc, root_path)
    extra = load_includes!(Map.get(doc, "include", []), plugin_dir, root_path)

    queries =
      (base ++ extra)
      |> merge_no_dupes!()
      |> Enum.sort_by(fn {name, _, _} -> name end)
      |> Enum.map(fn {name, entry, _source} -> Query.parse!(name, entry) end)

    opts = %{allow_sql: parse_allow_sql!(Map.get(doc, "allow_sql", false), root_path)}

    {queries, opts}
  end

  defp parse_allow_sql!(v, _path) when is_boolean(v), do: v

  defp parse_allow_sql!(other, path) do
    raise "queries.yml at #{path}: allow_sql must be boolean, got #{inspect(other)}"
  end

  defp entries_from_doc!(doc, source) do
    queries = Map.get(doc, "queries", %{})

    unless is_map(queries) do
      raise "queries.yml at #{source}: queries must be a map, got #{inspect(queries)}"
    end

    Enum.map(queries, fn {name, entry} -> {name, entry, source} end)
  end

  defp load_includes!(patterns, _plugin_dir, root_path) when not is_list(patterns) do
    raise "queries.yml at #{root_path}: include must be a list, got #{inspect(patterns)}"
  end

  defp load_includes!([], _plugin_dir, _root_path), do: []

  defp load_includes!(patterns, plugin_dir, root_path) do
    Enum.flat_map(patterns, fn pattern ->
      unless is_binary(pattern) do
        raise "queries.yml at #{root_path}: include entries must be strings, got #{inspect(pattern)}"
      end

      paths = expand_pattern!(pattern, plugin_dir, root_path)
      Enum.flat_map(paths, &load_include_file!/1)
    end)
  end

  defp expand_pattern!(pattern, plugin_dir, root_path) do
    full = Path.join(plugin_dir, pattern)

    if glob?(pattern) do
      full |> Path.wildcard() |> Enum.sort()
    else
      unless File.regular?(full) do
        raise "queries.yml at #{root_path}: include `#{pattern}` does not exist (resolved to #{full})"
      end

      [full]
    end
  end

  defp glob?(pattern), do: String.contains?(pattern, ["*", "?", "["])

  defp load_include_file!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, nil} ->
        []

      {:ok, doc} when is_map(doc) ->
        entries_from_doc!(doc, path)

      {:ok, other} ->
        raise "include #{path}: top-level must be a map, got #{inspect(other)}"

      {:error, reason} ->
        raise "include #{path}: cannot parse (#{inspect(reason)})"
    end
  end

  defp merge_no_dupes!(entries) do
    Enum.reduce(entries, %{}, fn {name, entry, source}, acc ->
      case Map.get(acc, name) do
        nil ->
          Map.put(acc, name, {entry, source})

        {_existing_entry, existing_source} ->
          raise "queries.yml: duplicate query `#{name}` (in #{existing_source} and #{source})"
      end
    end)
    |> Enum.map(fn {name, {entry, source}} -> {name, entry, source} end)
  end
end
