defmodule Sark.MCP.Handlers.Query do
  @moduledoc """
  Runtime dispatcher for canned-query MCP tools.

  Each generated `Sark.MCP.Generated.<Plugin>.<plugin>_<query>/2` function
  delegates here with the plugin name + query name baked in.

  Reads run on the read pool. Writes run inside a transaction on the
  write pool, and on success broadcast a write event via
  `Sark.MCP.EventBus`. Errors split into three classes:
  validation / constraint / internal.
  """

  require Phantom.Tool, as: Tool

  alias Exqlite.Result
  alias Sark.MCP.EventBus
  alias Sark.MCP.Registry
  alias Sark.MCP.Telemetry
  alias Sark.Plugin.DB
  alias Sark.Plugin.Query
  alias Sark.Render

  @spec call(String.t(), atom, map, term) :: {:reply, map, term}
  def call(plugin, query_name, raw_params, session) do
    Telemetry.with_logging("#{plugin}.#{query_name}", raw_params, fn ->
      do_call(plugin, query_name, raw_params, session)
    end)
  end

  defp do_call(plugin, query_name, raw_params, session) do
    raw_params = raw_params || %{}

    with {:ok, %Query{} = q} <- Registry.get(plugin, query_name),
         {:ok, bound} <- Query.validate_and_bind(q, raw_params),
         {:ok, cols, value} <- execute(plugin, q, bound, raw_params) do
      reply_text(Render.render(value, q.format, q.returns, cols), session)
    else
      :error ->
        reply_error("query not found: #{plugin}.#{query_name}", session)

      {:error, {:validation, errs}} ->
        reply_error("validation: " <> format_errs(errs), session)

      {:error, {:constraint, msg}} ->
        reply_error("constraint: #{msg}", session)

      {:error, {:internal, reason}} ->
        reply_error("internal: #{inspect(reason)}", session)

      {:error, :scalar_no_rows} ->
        reply_error("constraint: expected at least 1 row for scalar return", session)
    end
  end

  defp execute(plugin, %Query{write: false} = q, bound, _raw_params) do
    case DB.read(plugin, q.compiled_sql, bound) do
      {:ok, cols, rows} ->
        case coerce(rows, q.returns) do
          {:ok, value} -> {:ok, cols, value}
          err -> err
        end

      {:error, e} ->
        classify(e)
    end
  end

  defp execute(plugin, %Query{write: true} = q, bound, raw_params) do
    # `command:` lets exqlite report changes count via Result.num_rows,
    # but suppresses columns — only safe for non-row-returning shapes.
    opts =
      if q.returns in [:none, :count] do
        case detect_command(q.compiled_sql) do
          nil -> []
          cmd -> [command: cmd]
        end
      else
        []
      end

    txn_result =
      DB.txn(plugin, fn conn ->
        case Exqlite.query(conn, q.compiled_sql, bound, opts) do
          {:ok, %Result{} = r} -> {:ok, r}
          {:error, e} -> DBConnection.rollback(conn, e)
        end
      end)

    case txn_result do
      {:ok, {:ok, %Result{} = r}} ->
        case coerce_result(r, q.returns) do
          {:ok, value} ->
            EventBus.broadcast_write(plugin, q.name, raw_params, value)
            {:ok, DB.columns(r), value}

          err ->
            err
        end

      {:error, e} ->
        classify(e)
    end
  end

  defp coerce(rows, :results), do: {:ok, rows}

  defp coerce([row | _], :scalar) when is_map(row) and map_size(row) > 0 do
    {:ok, row |> Map.values() |> hd()}
  end

  defp coerce([], :scalar), do: {:error, :scalar_no_rows}

  defp coerce(rows, :count), do: {:ok, length(rows)}

  defp coerce(_rows, :none), do: {:ok, nil}

  defp coerce_result(%Result{} = r, :count), do: {:ok, r.num_rows || 0}
  defp coerce_result(%Result{}, :none), do: {:ok, nil}

  defp coerce_result(%Result{} = r, returns) do
    coerce(DB.rows_to_maps(r), returns)
  end

  defp detect_command(sql) do
    cond do
      String.contains?(sql, "INSERT") -> :insert
      String.contains?(sql, "UPDATE") -> :update
      String.contains?(sql, "DELETE") -> :delete
      true -> nil
    end
  end

  defp classify(%Exqlite.Error{message: msg}) do
    if msg =~ "constraint failed" or msg =~ "constraint violation" do
      {:error, {:constraint, msg}}
    else
      {:error, {:internal, msg}}
    end
  end

  defp classify(other), do: {:error, {:internal, other}}

  defp reply_text(str, session), do: {:reply, Tool.text(str), session}
  defp reply_error(msg, session), do: {:reply, Tool.error(msg), session}

  defp format_errs(errs) do
    Enum.map_join(errs, "; ", fn %{param: p, reason: r} -> "#{p} #{r}" end)
  end
end
