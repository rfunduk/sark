defmodule Sark.Plugin.Embed do
  @moduledoc """
  Per-table embed declaration in `plugin.yml`.

      embed:
        nodes:
          fields: [summary, body]            # required
          pk: id                             # optional, default "id"
          chunk: { size: 1024, overlap: 128 } # optional
          where: "status != 'archived'"      # optional

  Plugin author declares *what* to embed (which tables, which columns,
  optional row filter); the operator's `embedder:` config in
  `config.yml` decides *how* (provider, model, dim, chunk defaults).

  `embed:` is mergeable across `include:` files with the same parity
  as `tools:` / `pipelines:` / `shared:`. Duplicate table key across
  files raises — one table, one embed config.
  """

  @enforce_keys [:table, :fields]
  defstruct [:table, :fields, :where, pk: "id", chunk: nil]

  @type chunk :: %{size: pos_integer(), overlap: non_neg_integer()}
  @type t :: %__MODULE__{
          table: String.t(),
          fields: [String.t(), ...],
          pk: String.t(),
          chunk: chunk() | nil,
          where: String.t() | nil
        }

  @ident_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Parse one `embed.<table>` block into a `%Sark.Plugin.Embed{}`.
  `table` is the table name (top-level key), `raw` is the spec map.
  """
  @spec parse!(String.t(), map() | nil, String.t()) :: t()
  def parse!(table, raw, source) do
    unless is_binary(table) and Regex.match?(@ident_re, table) do
      raise "#{source}: embed table name `#{inspect(table)}` invalid — must match identifier pattern"
    end

    unless is_map(raw) do
      raise "#{source}: embed.#{table} must be a map, got #{inspect(raw)}"
    end

    fields = parse_fields!(table, Map.get(raw, "fields"), source)
    pk = parse_pk!(table, Map.get(raw, "pk", "id"), source)
    chunk = parse_chunk!(table, Map.get(raw, "chunk"), source)
    where = parse_where!(table, Map.get(raw, "where"), source)

    reject_unknown_keys!(table, raw, source)

    %__MODULE__{table: table, fields: fields, pk: pk, chunk: chunk, where: where}
  end

  defp parse_fields!(table, nil, source) do
    raise "#{source}: embed.#{table}.fields is required (list of column names)"
  end

  defp parse_fields!(table, fields, source) when is_list(fields) do
    if fields == [] do
      raise "#{source}: embed.#{table}.fields must be non-empty"
    end

    Enum.each(fields, fn f ->
      unless is_binary(f) and Regex.match?(@ident_re, f) do
        raise "#{source}: embed.#{table}.fields entry `#{inspect(f)}` invalid — must match identifier pattern"
      end
    end)

    case fields -- Enum.uniq(fields) do
      [] -> fields
      [dup | _] -> raise "#{source}: embed.#{table}.fields has duplicate column `#{dup}`"
    end
  end

  defp parse_fields!(table, other, source) do
    raise "#{source}: embed.#{table}.fields must be a list, got #{inspect(other)}"
  end

  defp parse_pk!(table, pk, source) do
    unless is_binary(pk) and Regex.match?(@ident_re, pk) do
      raise "#{source}: embed.#{table}.pk `#{inspect(pk)}` invalid — must match identifier pattern"
    end

    pk
  end

  defp parse_chunk!(_table, nil, _source), do: nil

  defp parse_chunk!(table, %{} = chunk, source) do
    size = fetch_pos_integer!(table, chunk, "size", source)
    overlap = fetch_non_neg_integer!(table, chunk, "overlap", source)

    if overlap >= size do
      raise "#{source}: embed.#{table}.chunk.overlap must be < size (got #{overlap} >= #{size})"
    end

    %{size: size, overlap: overlap}
  end

  defp parse_chunk!(table, other, source) do
    raise "#{source}: embed.#{table}.chunk must be a map, got #{inspect(other)}"
  end

  defp parse_where!(_table, nil, _source), do: nil

  defp parse_where!(table, where, source) do
    unless is_binary(where) and where != "" do
      raise "#{source}: embed.#{table}.where must be a non-empty string, got #{inspect(where)}"
    end

    where
  end

  defp fetch_pos_integer!(table, map, key, source) do
    case Map.get(map, key) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise "#{source}: embed.#{table}.chunk.#{key} must be positive integer, got #{inspect(other)}"
    end
  end

  defp fetch_non_neg_integer!(table, map, key, source) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 ->
        n

      other ->
        raise "#{source}: embed.#{table}.chunk.#{key} must be non-negative integer, got #{inspect(other)}"
    end
  end

  @known_keys ~w(fields pk chunk where)

  defp reject_unknown_keys!(table, raw, source) do
    case Map.keys(raw) -- @known_keys do
      [] ->
        :ok

      extras ->
        raise "#{source}: embed.#{table} has unknown keys: #{Enum.join(extras, ", ")} " <>
                "(allowed: #{Enum.join(@known_keys, ", ")})"
    end
  end
end
