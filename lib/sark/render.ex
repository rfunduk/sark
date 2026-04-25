defmodule Sark.Render do
  @moduledoc """
  Render a query result as a string for an MCP tool response.

  The `value` shape depends on the query's `returns`:
    * `:rows` → list of string-keyed maps
    * `:one_row` → single string-keyed map (handler must enforce 1)
    * `:maybe_row` → single map or `nil`
    * `:scalar` → raw value
    * `:count` → integer
    * `:none` → `nil`

  Supported formats:
    * `:json` — `Jason.encode!/1` pretty
    * `:table` — markdown pipe table (rows only)
    * `:list` — markdown bullets per row
    * `{:template, tpl}` — `:bbmustache.render/3`
  """

  alias Sark.Plugin.Query

  @type returns :: Query.returns()
  @type format :: Query.format()

  @spec render(term, format, returns) :: String.t()
  def render(value, :json, _returns), do: Jason.encode!(value, pretty: true)

  def render(value, :table, returns), do: render_table(value, returns)
  def render(value, :list, returns), do: render_list(value, returns)
  def render(value, {:template, tpl}, returns), do: render_template(value, tpl, returns)

  defp render_table([], _returns), do: "(no rows)"

  defp render_table(rows, :rows) when is_list(rows) do
    cols = rows |> hd() |> Map.keys()
    header = "| " <> Enum.join(cols, " | ") <> " |"
    sep = "| " <> Enum.map_join(cols, " | ", fn _ -> "---" end) <> " |"

    body =
      Enum.map_join(rows, "\n", fn row ->
        "| " <> Enum.map_join(cols, " | ", &cell(Map.get(row, &1))) <> " |"
      end)

    Enum.join([header, sep, body], "\n")
  end

  defp render_table(row, returns) when returns in [:one_row, :maybe_row] do
    render_table(List.wrap(row), :rows)
  end

  defp render_table(value, _returns), do: render(value, :json, nil)

  defp render_list([], _returns), do: "(no rows)"
  defp render_list(nil, :maybe_row), do: "(no row)"

  defp render_list(rows, :rows) when is_list(rows) do
    Enum.map_join(rows, "\n\n", &row_block/1)
  end

  defp render_list(row, returns) when returns in [:one_row, :maybe_row] and is_map(row) do
    row_block(row, "")
  end

  defp render_list(value, _returns), do: render(value, :json, nil)

  defp row_block(row), do: row_block(row, "- ")

  defp row_block(row, prefix) when is_map(row) do
    pairs = Enum.sort(row)

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

  defp render_template(value, tpl, returns) do
    ctx = template_ctx(value, returns)
    :bbmustache.render(tpl, ctx, key_type: :binary)
  end

  defp template_ctx(rows, :rows) when is_list(rows), do: %{"rows" => rows}
  defp template_ctx(nil, :maybe_row), do: %{}
  defp template_ctx(row, r) when r in [:one_row, :maybe_row] and is_map(row), do: row
  defp template_ctx(v, _returns) when is_map(v), do: v
  defp template_ctx(v, _returns), do: %{"value" => v}

  defp cell(nil), do: ""
  defp cell(v) when is_binary(v), do: v
  defp cell(v), do: inspect(v)
end
