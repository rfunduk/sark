defmodule Sark.Render do
  @moduledoc """
  Render a query result as a string for an MCP tool response.

  The `value` shape depends on the query's `returns`:
    * `:results` → list of string-keyed maps (0..N)
    * `:scalar` → raw value
    * `:count` → integer
    * `:none` → `nil`

  Supported formats:
    * `:json` — `Jason.encode!/1` pretty
    * `:table` — markdown pipe table (results only)
    * `:list` — markdown bullets per row
    * `{:template, tpl}` — `:bbmustache.render/3`; results bound to `{{#results}}…{{/results}}`
  """

  alias Sark.Plugin.Query

  @type returns :: Query.returns()
  @type format :: Query.format()

  @spec render(term, format, returns, [String.t()] | nil) :: String.t()
  def render(value, format, returns, cols \\ nil)

  def render(value, :json, _returns, _cols), do: Jason.encode!(value, pretty: true)

  def render(value, :table, returns, cols), do: render_table(value, returns, cols)
  def render(value, :list, returns, cols), do: render_list(value, returns, cols)

  def render(value, {:template, tpl}, returns, _cols),
    do: render_template(value, tpl, returns)

  defp render_table([], _returns, _cols), do: "(no results)"

  defp render_table(rows, :results, cols) when is_list(rows) do
    cols = cols_for(cols, rows)
    header = "| " <> Enum.join(cols, " | ") <> " |"
    sep = "| " <> Enum.map_join(cols, " | ", fn _ -> "---" end) <> " |"

    body =
      Enum.map_join(rows, "\n", fn row ->
        "| " <> Enum.map_join(cols, " | ", &cell(Map.get(row, &1))) <> " |"
      end)

    Enum.join([header, sep, body], "\n")
  end

  defp render_table(value, _returns, _cols), do: render(value, :json, nil)

  defp render_list([], _returns, _cols), do: "(no results)"

  defp render_list([row], :results, cols) when is_map(row) do
    row_block(row, "", cols_for(cols, [row]))
  end

  defp render_list(rows, :results, cols) when is_list(rows) do
    cols = cols_for(cols, rows)
    Enum.map_join(rows, "\n\n", &row_block(&1, "- ", cols))
  end

  defp render_list(value, _returns, _cols), do: render(value, :json, nil)

  defp row_block(row, prefix, cols) when is_map(row) do
    pairs = for k <- cols, do: {k, Map.get(row, k)}

    case pairs do
      [] ->
        "#{prefix}(empty)"

      [{k, v} | rest] ->
        first = "#{prefix}#{k}: #{cell(v)}"
        indent = String.duplicate(" ", String.length(prefix))
        rest_lines = Enum.map_join(rest, "\n", fn {k2, v2} -> "#{indent}#{k2}: #{cell(v2)}" end)

        case rest_lines do
          "" -> first
          _ -> first <> "\n" <> rest_lines
        end
    end
  end

  defp cols_for(cols, _rows) when is_list(cols) and cols != [], do: cols
  defp cols_for(_cols, [first | _]) when is_map(first), do: Map.keys(first)
  defp cols_for(_cols, _rows), do: []

  defp render_template(value, tpl, returns) do
    ctx = template_ctx(value, returns)
    :bbmustache.render(tpl, ctx, key_type: :binary)
  end

  defp template_ctx(results, :results) when is_list(results), do: %{"results" => results}
  defp template_ctx(v, _returns) when is_map(v), do: v
  defp template_ctx(v, _returns), do: %{"value" => v}

  defp cell(nil), do: ""
  defp cell(v) when is_binary(v), do: v
  defp cell(v), do: inspect(v)
end
