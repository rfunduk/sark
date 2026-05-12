defmodule Sark.Plugin.Query.YAML do
  @moduledoc """
  Read a plugin's `queries.yml` from disk.

  Format:

      allow_sql: false       # optional — opt into sark_catalog + sark_sql tools
      patchable:             # optional — allow-list for the built-in
        notes: [body]        #   `sark_patch` tool. Default {} (locked
        tasks: [body, title] #   down). Map of table → list of columns,
                             #   both validated as identifiers.
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
  `opts` is a map of plugin-wide flags (`%{allow_sql: bool, patchable:
  map}`). Returns `{[], default_opts()}` if `queries.yml` is absent.
  """

  alias Sark.Plugin.Query
  alias Sark.Plugin.Query.Fragments

  @type opts :: %{allow_sql: boolean(), patchable: %{optional(String.t()) => [String.t()]}}

  @ident_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

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

  defp default_opts, do: %{allow_sql: false, patchable: %{}}

  defp parse_root!(doc, plugin_dir, root_path) do
    {base, base_shared} = file_contents!(doc, root_path)
    {extra, extra_shared} = load_includes!(Map.get(doc, "include", []), plugin_dir, root_path)

    shared = merge_shared_no_dupes!([{base_shared, root_path} | extra_shared])

    queries =
      (base ++ extra)
      |> merge_no_dupes!()
      |> Enum.sort_by(fn {name, _, _} -> name end)
      |> Enum.map(fn {name, entry, source} ->
        resolved =
          try do
            Fragments.resolve(entry, shared)
          rescue
            e in ArgumentError ->
              reraise ArgumentError,
                      "queries.yml: #{name} (in #{source}): #{Exception.message(e)}",
                      __STACKTRACE__
          end

        Query.parse!(name, resolved)
      end)

    opts = %{
      allow_sql: parse_allow_sql!(Map.get(doc, "allow_sql", false), root_path),
      patchable: parse_patchable!(Map.get(doc, "patchable", %{}), root_path)
    }

    {queries, opts}
  end

  defp parse_allow_sql!(v, _path) when is_boolean(v), do: v

  defp parse_allow_sql!(other, path) do
    raise "queries.yml at #{path}: allow_sql must be boolean, got #{inspect(other)}"
  end

  defp parse_patchable!(nil, _path), do: %{}

  defp parse_patchable!(map, path) when is_map(map) do
    Enum.into(map, %{}, fn {table, cols} ->
      unless is_binary(table) and Regex.match?(@ident_re, table) do
        raise "queries.yml at #{path}: patchable table name must match identifier pattern, got #{inspect(table)}"
      end

      unless is_list(cols) do
        raise "queries.yml at #{path}: patchable.#{table} must be a list of column names, got #{inspect(cols)}"
      end

      Enum.each(cols, fn col ->
        unless is_binary(col) and Regex.match?(@ident_re, col) do
          raise "queries.yml at #{path}: patchable.#{table} entry must match identifier pattern, got #{inspect(col)}"
        end
      end)

      {table, cols}
    end)
  end

  defp parse_patchable!(other, path) do
    raise "queries.yml at #{path}: patchable must be a map of table → list of columns, got #{inspect(other)}"
  end

  defp file_contents!(doc, source) do
    {entries_from_doc!(doc, source), shared_from_doc!(doc, source)}
  end

  defp entries_from_doc!(doc, source) do
    queries = Map.get(doc, "queries", %{})

    unless is_map(queries) do
      raise "queries.yml at #{source}: queries must be a map, got #{inspect(queries)}"
    end

    Enum.map(queries, fn {name, entry} -> {name, entry, source} end)
  end

  defp shared_from_doc!(doc, source) do
    case Map.get(doc, "shared") do
      nil ->
        %{}

      map when is_map(map) ->
        map

      other ->
        raise "queries.yml at #{source}: shared must be a map, got #{inspect(other)}"
    end
  end

  defp merge_shared_no_dupes!(per_file) do
    Enum.reduce(per_file, %{}, fn {map, source}, acc ->
      Enum.reduce(map, acc, fn {name, value}, acc2 ->
        case Map.fetch(acc2, name) do
          :error ->
            Map.put(acc2, name, value)

          {:ok, _} ->
            raise "queries.yml: duplicate shared fragment `@#{name}` " <>
                    "(redefined in #{source})"
        end
      end)
    end)
  end

  defp load_includes!(patterns, _plugin_dir, root_path) when not is_list(patterns) do
    raise "queries.yml at #{root_path}: include must be a list, got #{inspect(patterns)}"
  end

  defp load_includes!([], _plugin_dir, _root_path), do: {[], []}

  defp load_includes!(patterns, plugin_dir, root_path) do
    Enum.reduce(patterns, {[], []}, fn pattern, {entries_acc, shared_acc} ->
      unless is_binary(pattern) do
        raise "queries.yml at #{root_path}: include entries must be strings, got #{inspect(pattern)}"
      end

      paths = expand_pattern!(pattern, plugin_dir, root_path)

      Enum.reduce(paths, {entries_acc, shared_acc}, fn path, {ea, sa} ->
        {entries, shared} = load_include_file!(path)
        {ea ++ entries, sa ++ [{shared, path}]}
      end)
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
        {[], %{}}

      {:ok, doc} when is_map(doc) ->
        {entries_from_doc!(doc, path), shared_from_doc!(doc, path)}

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
