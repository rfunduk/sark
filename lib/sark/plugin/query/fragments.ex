defmodule Sark.Plugin.Query.Fragments do
  @moduledoc """
  Resolve `@name` fragment references against a `shared:` map.

  `shared:` blocks from `queries.yml` and any included files are merged
  into one map (dupe key across files raises). Each query entry is then
  walked top-to-bottom; any string starting with `@` is treated as a
  reference and replaced with the corresponding `shared` value.

  Two substitution shapes:

    * **Whole-value.** `field: "@name"` becomes `shared.name` literally.
    * **List-element splice.** Inside a list, `"@name"` whose value is a
      list is spliced (flattened by one level); a non-list value is
      inserted as a single element.

  Resolution is universal — applied to every value in the entry tree —
  so any field can reference fragments. Unknown names raise at parse
  time. Cycles (a → b → a) raise after a depth cap.
  """

  @max_depth 8

  @spec resolve(term, map) :: term
  def resolve(value, shared) when is_map(shared) do
    walk(value, shared, 0)
  end

  defp walk(_v, _shared, depth) when depth > @max_depth do
    raise ArgumentError, "shared: fragment cycle (max depth #{@max_depth})"
  end

  defp walk("@" <> name, shared, depth) do
    case Map.fetch(shared, name) do
      {:ok, v} -> walk(v, shared, depth + 1)
      :error -> raise ArgumentError, unknown_msg(name, shared)
    end
  end

  defp walk(list, shared, depth) when is_list(list) do
    Enum.flat_map(list, fn
      "@" <> name = ref ->
        case Map.fetch(shared, name) do
          {:ok, v} ->
            case walk(v, shared, depth + 1) do
              l when is_list(l) -> l
              other -> [other]
            end

          :error ->
            raise ArgumentError, unknown_msg(name, shared, ref)
        end

      other ->
        [walk(other, shared, depth)]
    end)
  end

  defp walk(map, shared, depth) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, walk(v, shared, depth)} end)
  end

  defp walk(scalar, _shared, _depth), do: scalar

  defp unknown_msg(name, shared, ref \\ nil) do
    defined = shared |> Map.keys() |> Enum.sort() |> Enum.map(&"@#{&1}") |> Enum.join(", ")
    suffix = if defined == "", do: "(no shared fragments defined)", else: "defined: #{defined}"
    label = ref || "@#{name}"
    "shared: unknown fragment `#{label}` — #{suffix}"
  end
end
