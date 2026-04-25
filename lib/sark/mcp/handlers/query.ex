defmodule Sark.MCP.Handlers.Query do
  @moduledoc """
  Runtime dispatcher for canned-query MCP tools.

  Each generated `Sark.MCP.Generated.<Plugin>.<plugin>_<query>/2` function
  delegates here with the plugin name + query name baked in.
  """

  require Phantom.Tool, as: Tool

  alias Sark.MCP.Registry
  alias Sark.Plugin.DB
  alias Sark.Plugin.Query
  alias Sark.Render

  @spec call(String.t(), atom, map, term) :: {:reply, map, term}
  def call(plugin, query_name, raw_params, session) do
    raw_params = raw_params || %{}

    with {:ok, %Query{} = q} <- Registry.get(plugin, query_name),
         :ok <- ensure_read(q),
         {:ok, bound} <- Query.validate_and_bind(q, raw_params),
         {:ok, value} <- execute(plugin, q, bound) do
      reply_text(Render.render(value, q.format, q.returns), session)
    else
      :error ->
        reply_error("query not found: #{plugin}.#{query_name}", session)

      {:error, {:validation, errs}} ->
        reply_error("validation: " <> format_errs(errs), session)

      {:error, :write_deferred} ->
        reply_error("write tools land in M4", session)

      {:error, {:execute, reason}} ->
        reply_error("sql error: #{inspect(reason)}", session)

      {:error, :one_row_zero} ->
        reply_error("expected exactly 1 row, got 0", session)

      {:error, :one_row_many} ->
        reply_error("expected exactly 1 row, got more than 1", session)

      {:error, :scalar_no_rows} ->
        reply_error("expected at least 1 row for scalar return", session)
    end
  end

  defp ensure_read(%Query{write: true}), do: {:error, :write_deferred}
  defp ensure_read(%Query{}), do: :ok

  defp execute(plugin, %Query{compiled_sql: sql} = q, bound) do
    case DB.read(plugin, sql, bound) do
      {:ok, rows} -> coerce(rows, q.returns)
      {:error, e} -> {:error, {:execute, e}}
    end
  end

  defp coerce(rows, :rows), do: {:ok, rows}

  defp coerce([row], :one_row), do: {:ok, row}
  defp coerce([], :one_row), do: {:error, :one_row_zero}
  defp coerce(rows, :one_row) when length(rows) > 1, do: {:error, :one_row_many}

  defp coerce([row], :maybe_row), do: {:ok, row}
  defp coerce([], :maybe_row), do: {:ok, nil}
  defp coerce(rows, :maybe_row) when length(rows) > 1, do: {:error, :one_row_many}

  defp coerce([row | _], :scalar) when is_map(row) and map_size(row) > 0 do
    {:ok, row |> Map.values() |> hd()}
  end

  defp coerce([], :scalar), do: {:error, :scalar_no_rows}

  defp coerce(rows, :count), do: {:ok, length(rows)}

  defp coerce(_rows, :none), do: {:ok, nil}

  defp reply_text(str, session), do: {:reply, Tool.text(str), session}
  defp reply_error(msg, session), do: {:reply, Tool.error(msg), session}

  defp format_errs(errs) do
    Enum.map_join(errs, "; ", fn %{param: p, reason: r} -> "#{p} #{r}" end)
  end
end
