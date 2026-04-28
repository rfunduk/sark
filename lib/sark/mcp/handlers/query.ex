defmodule Sark.MCP.Handlers.Query do
  @moduledoc """
  Runtime dispatcher for canned-query MCP tools.

  A query may have one or more SQL statements (`sql:` accepts a string
  or a list of strings). All statements run in order, sharing the
  declared params; the response is the last statement's result.

  Reads run on the read pool. Writes run inside one transaction on the
  write pool, broadcasting a single write event after success. Errors
  split into validation / constraint / internal classes.
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
         {:ok, binds} <- Query.validate_and_bind(q, raw_params),
         {:ok, cols, value} <- execute(plugin, q, binds, raw_params) do
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

  defp execute(plugin, %Query{write: false} = q, binds, _raw_params) do
    case run_reads(plugin, q.statements, binds) do
      {:ok, cols, rows} ->
        case coerce(rows, q.returns) do
          {:ok, value} -> {:ok, cols, value}
          err -> err
        end

      {:error, e} ->
        classify(e)
    end
  end

  defp execute(plugin, %Query{write: true} = q, binds, raw_params) do
    txn_result =
      DB.txn(plugin, fn conn ->
        case run_writes(conn, q, binds) do
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

  # Run all read statements on the read pool. Earlier statements are
  # executed for side effects (rare for reads — PRAGMAs, temp views,
  # etc.); the last statement's rows are what gets returned.
  defp run_reads(plugin, statements, binds) do
    Enum.zip(statements, binds)
    |> Enum.reduce_while({:ok, [], []}, fn {stmt, bind}, _acc ->
      case DB.read(plugin, stmt.compiled_sql, bind) do
        {:ok, cols, rows} -> {:cont, {:ok, cols, rows}}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  # Iterate write statements inside the caller's transaction. Last
  # statement gets the `command:` opt for `:none`/`:count` returns
  # (lets exqlite report num_rows without materializing rows).
  defp run_writes(conn, %Query{statements: statements, returns: returns}, binds) do
    last_idx = length(statements) - 1

    Enum.zip(statements, binds)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil}, fn {{stmt, bind}, idx}, _acc ->
      opts =
        if idx == last_idx and returns in [:none, :count] do
          case detect_command(stmt.compiled_sql) do
            nil -> []
            cmd -> [command: cmd]
          end
        else
          []
        end

      case Exqlite.query(conn, stmt.compiled_sql, bind, opts) do
        {:ok, %Result{} = r} -> {:cont, {:ok, r}}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
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
