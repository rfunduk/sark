defmodule Sark.Auth.JSONPath do
  @moduledoc """
  Minimal claim-path traversal.

  Path syntax is bare dotted names: `email`, `realm_access.roles`.
  Each segment is a string key into the current map. Missing keys
  resolve to `nil`. List indexing is intentionally unsupported —
  rule operators (`in`, `contains`) handle list-shaped values.

  No JSONPath grammar. No `$.` prefix. No brackets. URL-keyed claims
  (Auth0 `https://app/roles`) collide with the dot separator and are
  not addressable; defer until first real demand.
  """

  @spec parse(String.t()) :: [String.t()]
  def parse(path) when is_binary(path) and path != "" do
    String.split(path, ".")
  end

  def parse(other),
    do: raise(ArgumentError, "path must be non-empty string, got #{inspect(other)}")

  @spec get(map() | nil, [String.t()]) :: term()
  def get(claims, segments) do
    Enum.reduce_while(segments, claims, fn
      _seg, nil -> {:halt, nil}
      seg, acc when is_map(acc) -> {:cont, Map.get(acc, seg)}
      _seg, _ -> {:halt, nil}
    end)
  end
end
