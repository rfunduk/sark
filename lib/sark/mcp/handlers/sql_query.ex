defmodule Sark.MCP.Handlers.SqlQuery do
  @moduledoc """
  Per-plugin raw SELECT escape hatch. Runs arbitrary SQL against the
  plugin's reader pool — `query_only=ON` enforces read-only at the
  SQLite layer, but a leading-keyword check rejects obvious writes
  with a friendlier error.
  """

  require Phantom.Tool, as: Tool

  alias Sark.MCP.Telemetry
  alias Sark.Plugin.DB

  @leading_re ~r/^\s*(?:--[^\n]*\n|\/\*.*?\*\/|\s)*+(\w+)/ms

  @spec call(String.t(), map, term) :: {:reply, map, term}
  def call(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.sark_sql", params, fn ->
      do_call(plugin, params, session)
    end)
  end

  defp do_call(plugin, params, session) do
    sql = params && Map.get(params, "sql")

    cond do
      not is_binary(sql) or sql == "" ->
        reply_error("validation: sql is required", session)

      not allowed_keyword?(sql) ->
        reply_error("validation: only SELECT/WITH/PRAGMA queries are permitted", session)

      true ->
        case DB.read(plugin, sql, []) do
          {:ok, _cols, []} ->
            {:reply, Tool.text("(no rows)"), session}

          {:ok, cols, rows} ->
            {:reply, Tool.text(format_rows(cols, rows)), session}

          {:error, %Exqlite.Error{message: msg}} ->
            if msg =~ "constraint failed" or msg =~ "constraint violation" do
              reply_error("constraint: #{msg}", session)
            else
              reply_error("internal: #{msg}", session)
            end

          {:error, reason} ->
            reply_error("internal: #{inspect(reason)}", session)
        end
    end
  end

  defp allowed_keyword?(sql) do
    case Regex.run(@leading_re, sql) do
      [_, kw] -> String.upcase(kw) in ["SELECT", "WITH", "PRAGMA"]
      _ -> false
    end
  end

  defp format_rows(cols, rows) do
    header = "| " <> Enum.join(cols, " | ") <> " |"
    sep = "| " <> Enum.map_join(cols, " | ", fn _ -> "---" end) <> " |"

    body =
      Enum.map_join(rows, "\n", fn row ->
        "| " <> Enum.map_join(cols, " | ", &cell(Map.get(row, &1))) <> " |"
      end)

    Enum.join([header, sep, body], "\n")
  end

  defp cell(nil), do: ""
  defp cell(v) when is_binary(v), do: v
  defp cell(v) when is_map(v) or is_list(v), do: Jason.encode!(v)
  defp cell(v), do: inspect(v)

  defp reply_error(msg, session), do: {:reply, Tool.error(msg), session}
end
