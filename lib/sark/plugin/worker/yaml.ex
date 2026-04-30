defmodule Sark.Plugin.Worker.YAML do
  @moduledoc """
  Read a plugin's `workers.yml` from disk.

  Mirrors `Sark.Plugin.Query.YAML`'s shape:

      include:                   # optional — list of file paths or globs,
        - workers/*.yml          #   relative to plugin dir.
      workers:
        <name>:
          description: ...
          model: claude-haiku-4-5
          tools: [list_active, show]
          max_turns: 4
          when: |                # optional. Empty result → skip run entirely.
            SELECT 1 WHERE EXISTS (...)
          load: |                # optional. Rows feed mustache rendering of `prompt:`.
            SELECT count(*) AS pending FROM ...
          system: |              # required. NO mustache — sent verbatim, cached.
            ...
          prompt: |              # required. Mustache-rendered against `load:` rows.
            {{pending}} pending. ...

  All `workers:` blocks across `workers.yml` and any included files are
  merged into a single map. Duplicate names raise. Returns `[]` if
  `workers.yml` is absent.
  """

  alias Sark.Plugin.Worker

  @spec load(Path.t()) :: [Worker.t()]
  def load(plugin_dir) do
    path = Path.join(plugin_dir, "workers.yml")

    case YamlElixir.read_from_file(path) do
      {:ok, nil} ->
        []

      {:ok, doc} when is_map(doc) ->
        parse_root!(doc, plugin_dir, path)

      {:ok, other} ->
        raise "workers.yml: top-level must be a map, got #{inspect(other)}"

      {:error, %YamlElixir.FileNotFoundError{}} ->
        []

      {:error, reason} ->
        raise "workers.yml at #{path}: cannot parse (#{inspect(reason)})"
    end
  end

  defp parse_root!(doc, plugin_dir, root_path) do
    base = entries_from_doc!(doc, root_path)
    extra = load_includes!(Map.get(doc, "include", []), plugin_dir, root_path)

    (base ++ extra)
    |> merge_no_dupes!()
    |> Enum.sort_by(fn {name, _, _} -> name end)
    |> Enum.map(fn {name, entry, _source} -> Worker.parse!(name, entry) end)
  end

  defp entries_from_doc!(doc, source) do
    workers = Map.get(doc, "workers", %{})

    unless is_map(workers) do
      raise "workers.yml at #{source}: workers must be a map, got #{inspect(workers)}"
    end

    Enum.map(workers, fn {name, entry} -> {name, entry, source} end)
  end

  defp load_includes!(patterns, _plugin_dir, root_path) when not is_list(patterns) do
    raise "workers.yml at #{root_path}: include must be a list, got #{inspect(patterns)}"
  end

  defp load_includes!([], _plugin_dir, _root_path), do: []

  defp load_includes!(patterns, plugin_dir, root_path) do
    Enum.flat_map(patterns, fn pattern ->
      unless is_binary(pattern) do
        raise "workers.yml at #{root_path}: include entries must be strings, got #{inspect(pattern)}"
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
        raise "workers.yml at #{root_path}: include `#{pattern}` does not exist (resolved to #{full})"
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
          raise "workers.yml: duplicate worker `#{name}` (in #{existing_source} and #{source})"
      end
    end)
    |> Enum.map(fn {name, {entry, source}} -> {name, entry, source} end)
  end
end
