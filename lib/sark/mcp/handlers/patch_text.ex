defmodule Sark.MCP.Handlers.PatchText do
  @moduledoc """
  Generic optimistic-concurrency text patch tool.

  Tool: `<plugin>_patch_text(table, id, col, old, new)`.

  Reads `col` from the row with `id = :id` in `table`, asserts the
  current value equals `old`, then writes `new`. Whole thing runs in
  one write transaction.

  Token-saver vs. agents re-emitting full bodies. Identifier args
  (`table`, `col`) are validated against `^[A-Za-z_][A-Za-z0-9_]*$`
  before interpolation — bind vars can't carry identifiers in SQLite.
  Plugin author owns the schema; if the agent passes a bad name it
  surfaces as a structured error, not an injection.
  """

  require Phantom.Tool, as: Tool

  alias Exqlite.Result
  alias Sark.MCP.EventBus
  alias Sark.MCP.Telemetry
  alias Sark.Plugin.DB

  @ident_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @spec call(String.t(), map, term) :: {:reply, map, term}
  def call(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.patch_text", params, fn ->
      do_call(plugin, params, session)
    end)
  end

  defp do_call(plugin, params, session) do
    params = params || %{}

    with {:ok, table} <- ident(params, "table"),
         {:ok, col} <- ident(params, "col"),
         {:ok, id} <- fetch(params, "id"),
         {:ok, old} <- fetch_text(params, "old"),
         {:ok, new} <- fetch_text(params, "new"),
         {:ok, result} <- patch(plugin, table, col, id, old, new) do
      EventBus.broadcast_write(plugin, :patch_text, params, result)
      {:reply, Tool.text(result), session}
    else
      {:error, msg} when is_binary(msg) -> reply_error(msg, session)
    end
  end

  defp patch(plugin, table, col, id, old, new) do
    select_sql = "SELECT #{col} AS v FROM #{table} WHERE id = ?"
    update_sql = "UPDATE #{table} SET #{col} = ? WHERE id = ?"

    case DB.txn(plugin, fn conn ->
           with {:ok, %Result{rows: rows}} <- Exqlite.query(conn, select_sql, [id]),
                {:ok, current} <- one_value(rows),
                :ok <- assert_match(current, old),
                {:ok, _} <- Exqlite.query(conn, update_sql, [new, id]) do
             :ok
           else
             {:error, e} -> DBConnection.rollback(conn, e)
           end
         end) do
      {:ok, :ok} ->
        {:ok, %{ok: true, table: table, col: col, id: id}}

      {:error, %Exqlite.Error{message: msg}} ->
        if msg =~ "constraint failed" or msg =~ "constraint violation" do
          {:error, "constraint: #{msg}"}
        else
          {:error, "internal: #{msg}"}
        end

      {:error, {:not_found, _}} ->
        {:error, "constraint: row not found"}

      {:error, {:mismatch, current}} ->
        {:error, "constraint: old value mismatch — current=#{inspect(current)}"}

      {:error, other} ->
        {:error, "internal: #{inspect(other)}"}
    end
  end

  defp one_value([[v]]), do: {:ok, v}
  defp one_value([]), do: {:error, {:not_found, nil}}
  defp one_value(rows), do: {:error, {:internal, {:bad_row_shape, rows}}}

  defp assert_match(v, expected) when v == expected, do: :ok
  defp assert_match(current, _expected), do: {:error, {:mismatch, current}}

  defp ident(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) ->
        if Regex.match?(@ident_re, v) do
          {:ok, v}
        else
          {:error, "validation: #{key} must match identifier pattern (got #{inspect(v)})"}
        end

      _ ->
        {:error, "validation: #{key} is required (string)"}
    end
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "validation: #{key} is required"}
      v -> {:ok, v}
    end
  end

  defp fetch_text(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) -> {:ok, v}
      nil -> {:error, "validation: #{key} is required (string)"}
      _ -> {:error, "validation: #{key} must be a string"}
    end
  end

  defp reply_error(msg, session), do: {:reply, Tool.error(msg), session}
end
