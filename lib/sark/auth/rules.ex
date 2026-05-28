defmodule Sark.Auth.Rules do
  @moduledoc """
  JWT-claim-driven plugin scope rules.

  Each rule has a `match` clause and a `plugins` allow-list (parsed by
  `Sark.Config.parse_allowed/3` into the same shape bearer tokens use).

  Evaluation is **additive**: every rule whose `match` passes contributes
  its `plugins` to a unioned scope. Zero matches → `:deny`. Order does
  not matter — no rule can shadow another. A broad rule and a narrow
  rule both firing produces the union, not whichever appeared first.

  Match operators:

    * `equals`  — strict equality on the path's resolved value
    * `in`      — path resolves to list, value member of list
    * `suffix`  — path resolves to string, ends with value
    * `exists`  — path resolves to a non-null value (any type)
  """

  alias Sark.Auth.JSONPath

  @type op :: :equals | :in | :suffix | :exists
  @type match :: %{path: [String.t()], op: op(), value: term()}
  @type plugins :: :all | %{String.t() => :all | [Regex.t()]}
  @type rule :: %{match: match() | nil, plugins: plugins()}
  @type t :: [rule()]

  @doc """
  Evaluate `claims` against `rules`. Returns the merged allow-list (in
  the same shape as `Sark.AuthRegistry` entry's `:allowed`), or `:deny`
  when no rule matches.

  `claims` may be a JSON-decoded map or `nil`. `nil` matches no rule
  unless an `exists: false`-style operator is added later (none today).
  """
  @spec eval(map() | nil, t()) :: plugins() | :deny
  def eval(claims, rules) when is_list(rules) do
    rules
    |> Enum.filter(&matches?(&1.match, claims))
    |> case do
      [] -> :deny
      hits -> Enum.reduce(hits, %{}, fn rule, acc -> union(acc, rule.plugins) end)
    end
  end

  # nil match clause = unconditional grant (default-allow rule).
  defp matches?(nil, _claims), do: true

  defp matches?(%{path: segs, op: op, value: value}, claims) do
    apply_op(op, JSONPath.get(claims, segs), value)
  end

  defp apply_op(:equals, actual, expected), do: actual == expected
  defp apply_op(:in, list, value) when is_list(list), do: value in list
  defp apply_op(:in, _, _), do: false

  defp apply_op(:suffix, str, suffix) when is_binary(str) and is_binary(suffix),
    do: String.ends_with?(str, suffix)

  defp apply_op(:suffix, _, _), do: false
  defp apply_op(:exists, nil, _), do: false
  defp apply_op(:exists, _, _), do: true

  @doc false
  # Union merge of two parsed `plugins` allow-lists. Mirrors the shape
  # produced by `Sark.Config.parse_allowed/3`. `:all` is absorbing at
  # both top level and plugin-key level.
  @spec union(plugins(), plugins()) :: plugins()
  def union(:all, _), do: :all
  def union(_, :all), do: :all

  def union(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _plugin, av, bv -> merge_patterns(av, bv) end)
  end

  defp merge_patterns(:all, _), do: :all
  defp merge_patterns(_, :all), do: :all
  defp merge_patterns(a, b) when is_list(a) and is_list(b), do: a ++ b
end
