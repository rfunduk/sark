defmodule Sark.Plugin.YAML do
  @moduledoc """
  Read a plugin's `plugin.yml` (the single soft-convention entry doc)
  off disk into tools, pipelines, and plugin-wide opts.

  Entry shape:

      allow_sql: false       # optional, plugin-wide bool. Entry doc ONLY.
      include:               # optional, entry doc ONLY. Paths or globs,
        - tools/*.yml        #   plugin-dir-relative. Each is a YAML map
        - pipelines/*.yml    #   with any of tools:/pipelines:/shared:/patchable:.
      patchable:             # optional. table → [columns], mergeable.
        notes: [body]
      shared:                # optional, mergeable across files.
        frag: ...
      tools:                 # optional, mergeable across files.
        <name>: { ... }
      pipelines:             # optional, mergeable across files.
        <name>: { ... }

  All `tools:` / `pipelines:` / `shared:` / `patchable:` blocks across
  `plugin.yml` and every included file are merged into one map each; a
  duplicate key (tool, pipeline, fragment, or patchable table) raises,
  naming both source files.

  `allow_sql` and `include` are entry-only — present in an included
  file they raise (loud, not silently dropped). Includes are leaves:
  no recursive include.

  Returns `{tools, pipelines, opts}`. Absent `plugin.yml` →
  `{[], [], %{allow_sql: false, patchable: %{}}}` (a migrations-only
  plugin).
  """

  alias Sark.Plugin.Embed
  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Tool
  alias Sark.Plugin.Tool.Fragments

  @entry "plugin.yml"
  @ident_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @entry_only_keys ~w(allow_sql include db)

  @type opts :: %{
          allow_sql: boolean(),
          patchable: %{optional(String.t()) => [String.t()]},
          embed: %{optional(String.t()) => Embed.t()},
          db: %{optional(atom()) => integer()}
        }

  @spec load(Path.t()) :: {[Tool.t()], [Pipeline.t()], opts()}
  def load(plugin_dir) do
    path = Path.join(plugin_dir, @entry)

    case YamlElixir.read_from_file(path) do
      {:ok, nil} ->
        empty()

      {:ok, doc} when is_map(doc) ->
        parse_root!(doc, plugin_dir, path)

      {:ok, other} ->
        raise "plugin.yml: top-level must be a map, got #{inspect(other)}"

      {:error, %YamlElixir.FileNotFoundError{}} ->
        empty()

      {:error, reason} ->
        raise "plugin.yml at #{path}: cannot parse (#{inspect(reason)})"
    end
  end

  defp empty, do: {[], [], %{allow_sql: false, patchable: %{}, embed: %{}, db: %{}}}

  defp parse_root!(doc, plugin_dir, root_path) do
    docs = [{doc, root_path} | include_docs!(Map.get(doc, "include", []), plugin_dir, root_path)]

    shared =
      docs
      |> Enum.map(fn {d, src} -> {section_map!(d, "shared", src), src} end)
      |> merge_no_dupes!("shared fragment")

    tools =
      docs
      |> Enum.flat_map(fn {d, src} -> tagged(d, "tools", src) end)
      |> merge_no_dupes_entries!("tool")
      |> Enum.sort_by(fn {name, _, _} -> name end)
      |> Enum.map(fn {name, entry, source} ->
        Tool.parse!(name, resolve!(entry, shared, name, source))
      end)

    pipelines =
      docs
      |> Enum.flat_map(fn {d, src} -> tagged(d, "pipelines", src) end)
      |> merge_no_dupes_entries!("pipeline")
      |> Enum.sort_by(fn {name, _, _} -> name end)
      |> Enum.map(fn {name, entry, source} ->
        Pipeline.parse!(name, resolve!(entry, shared, name, source))
      end)

    patchable =
      docs
      |> Enum.map(fn {d, src} -> {parse_patchable!(Map.get(d, "patchable", %{}), src), src} end)
      |> merge_no_dupes!("patchable table")

    embed =
      docs
      |> Enum.map(fn {d, src} -> {parse_embed!(Map.get(d, "embed", %{}), src), src} end)
      |> merge_no_dupes!("embed table")

    opts = %{
      allow_sql: parse_allow_sql!(Map.get(doc, "allow_sql", false), root_path),
      patchable: patchable,
      embed: embed,
      db: parse_db!(Map.get(doc, "db", %{}), root_path)
    }

    {tools, pipelines, opts}
  end

  @db_keys ~w(readers cache_size mmap_size)

  defp parse_db!(nil, _root_path), do: %{}
  defp parse_db!(map, _root_path) when map == %{}, do: %{}

  defp parse_db!(map, root_path) when is_map(map) do
    bad_keys = Map.keys(map) -- @db_keys

    if bad_keys != [] do
      raise "plugin.yml at #{root_path}: db.#{Enum.join(bad_keys, ", db.")} " <>
              "unknown — valid keys: #{Enum.join(@db_keys, ", ")}"
    end

    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, validate_db_key!(k, v, root_path), v)
    end)
  end

  defp parse_db!(other, root_path) do
    raise "plugin.yml at #{root_path}: db must be a map, got #{inspect(other)}"
  end

  defp validate_db_key!("readers", v, _root_path) when is_integer(v) and v > 0, do: :readers
  defp validate_db_key!("cache_size", v, _root_path) when is_integer(v), do: :cache_size

  defp validate_db_key!("mmap_size", v, _root_path) when is_integer(v) and v >= 0,
    do: :mmap_size

  defp validate_db_key!(k, v, root_path) do
    raise "plugin.yml at #{root_path}: db.#{k} invalid value #{inspect(v)}"
  end

  # --- include expansion -----------------------------------------------------

  defp include_docs!(patterns, _plugin_dir, root_path) when not is_list(patterns) do
    raise "plugin.yml at #{root_path}: include must be a list, got #{inspect(patterns)}"
  end

  defp include_docs!([], _plugin_dir, _root_path), do: []

  defp include_docs!(patterns, plugin_dir, root_path) do
    Enum.flat_map(patterns, fn pattern ->
      unless is_binary(pattern) do
        raise "plugin.yml at #{root_path}: include entries must be strings, got #{inspect(pattern)}"
      end

      pattern
      |> expand_pattern!(plugin_dir, root_path)
      |> Enum.map(&load_include_doc!/1)
    end)
  end

  defp expand_pattern!(pattern, plugin_dir, root_path) do
    full = Path.join(plugin_dir, pattern)

    if glob?(pattern) do
      full |> Path.wildcard() |> Enum.sort()
    else
      unless File.regular?(full) do
        raise "plugin.yml at #{root_path}: include `#{pattern}` does not exist (resolved to #{full})"
      end

      [full]
    end
  end

  defp glob?(pattern), do: String.contains?(pattern, ["*", "?", "["])

  defp load_include_doc!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, nil} ->
        {%{}, path}

      {:ok, doc} when is_map(doc) ->
        reject_entry_only_keys!(doc, path)
        {doc, path}

      {:ok, other} ->
        raise "include #{path}: top-level must be a map, got #{inspect(other)}"

      {:error, reason} ->
        raise "include #{path}: cannot parse (#{inspect(reason)})"
    end
  end

  defp reject_entry_only_keys!(doc, path) do
    case Enum.filter(@entry_only_keys, &Map.has_key?(doc, &1)) do
      [] ->
        :ok

      bad ->
        raise "include #{path}: #{Enum.join(bad, ", ")} " <>
                "#{if length(bad) == 1, do: "is", else: "are"} entry-only — " <>
                "only valid in plugin.yml, not an included file"
    end
  end

  # --- section collection + merge --------------------------------------------

  defp resolve!(entry, shared, name, source) do
    Fragments.resolve(entry, shared)
  rescue
    e in ArgumentError ->
      reraise ArgumentError,
              "plugin.yml: #{name} (in #{source}): #{Exception.message(e)}",
              __STACKTRACE__
  end

  defp tagged(doc, key, source) do
    doc
    |> section_map!(key, source)
    |> Enum.map(fn {name, entry} -> {name, entry, source} end)
  end

  defp section_map!(doc, key, source) do
    case Map.get(doc, key, %{}) do
      map when is_map(map) -> map
      other -> raise "#{source}: `#{key}` must be a map, got #{inspect(other)}"
    end
  end

  defp merge_no_dupes_entries!(entries, kind) do
    entries
    |> Enum.reduce(%{}, fn {name, entry, source}, acc ->
      case Map.get(acc, name) do
        nil ->
          Map.put(acc, name, {entry, source})

        {_e, existing_source} ->
          raise "plugin.yml: duplicate #{kind} `#{name}` (in #{existing_source} and #{source})"
      end
    end)
    |> Enum.map(fn {name, {entry, source}} -> {name, entry, source} end)
  end

  defp merge_no_dupes!(per_file, kind) do
    Enum.reduce(per_file, %{}, fn {map, source}, acc ->
      Enum.reduce(map, acc, fn {name, value}, acc2 ->
        case Map.fetch(acc2, name) do
          :error ->
            Map.put(acc2, name, value)

          {:ok, _} ->
            raise "plugin.yml: duplicate #{kind} `#{name}` (redefined in #{source})"
        end
      end)
    end)
  end

  # --- plugin-wide opts (entry doc only) -------------------------------------

  defp parse_allow_sql!(v, _path) when is_boolean(v), do: v

  defp parse_allow_sql!(other, path) do
    raise "plugin.yml at #{path}: allow_sql must be boolean, got #{inspect(other)}"
  end

  defp parse_patchable!(nil, _path), do: %{}

  defp parse_patchable!(map, path) when is_map(map) do
    Enum.into(map, %{}, fn {table, cols} ->
      unless is_binary(table) and Regex.match?(@ident_re, table) do
        raise "plugin.yml at #{path}: patchable table name must match identifier pattern, got #{inspect(table)}"
      end

      unless is_list(cols) do
        raise "plugin.yml at #{path}: patchable.#{table} must be a list of column names, got #{inspect(cols)}"
      end

      Enum.each(cols, fn col ->
        unless is_binary(col) and Regex.match?(@ident_re, col) do
          raise "plugin.yml at #{path}: patchable.#{table} entry must match identifier pattern, got #{inspect(col)}"
        end
      end)

      {table, cols}
    end)
  end

  defp parse_patchable!(other, path) do
    raise "plugin.yml at #{path}: patchable must be a map of table → list of columns, got #{inspect(other)}"
  end

  defp parse_embed!(nil, _source), do: %{}

  defp parse_embed!(map, source) when is_map(map) do
    Map.new(map, fn {table, raw} -> {table, Embed.parse!(table, raw, source)} end)
  end

  defp parse_embed!(other, source) do
    raise "#{source}: embed must be a map of table → spec, got #{inspect(other)}"
  end
end
