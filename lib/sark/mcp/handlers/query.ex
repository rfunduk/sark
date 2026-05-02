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
         {:ok, coerced} <- Query.coerce_params(q, raw_params),
         {:ok, cols, value} <- execute(plugin, q, coerced, raw_params) do
      reply_text(Render.render(value, q.format, q.returns, cols), session)
    else
      :error ->
        reply_error("query not found: #{plugin}.#{query_name}", session)

      {:error, {:validation, errs}} ->
        reply_error("validation: " <> format_errs(errs), session)

      {:error, {:rejected, msg}} ->
        reply_error("rejected: #{msg}", session)

      {:error, {:constraint, msg}} ->
        reply_error("constraint: #{msg}", session)

      {:error, {:internal, reason}} ->
        reply_error("internal: #{inspect(reason)}", session)

      {:error, :scalar_no_rows} ->
        reply_error("constraint: expected at least 1 row for scalar return", session)
    end
  end

  # Reject pre-flight: each entry is a SELECT that returns ≥1 row when
  # its precondition fails. First non-empty short-circuits with
  # `{:rejected, msg}`. For reads we run on the read pool (query_only
  # backstop blocks accidental writes). For writes we run inside the
  # write txn (BEGIN IMMEDIATE) so the reject SELECT and main statement
  # share one exclusive write lock — no TOCTOU window for uniqueness /
  # state preconditions against other writers.
  defp check_rejects(%Query{reject: []}, _coerced, _runner), do: :ok

  defp check_rejects(%Query{reject: rejects, params: params}, coerced, runner) do
    Enum.reduce_while(rejects, :ok, fn r, _acc ->
      binds = Enum.map(r.param_order, fn name -> Map.fetch!(coerced, name) end)

      case runner.(r.compiled_sql, binds) do
        {:ok, []} ->
          {:cont, :ok}

        {:ok, [_ | _]} ->
          {:halt, {:error, {:rejected, render_message(r.message, coerced, params)}}}

        {:error, e} ->
          {:halt, classify(e)}
      end
    end)
  end

  # Interpolate `{name}` tokens in the reject message template. Booleans
  # are coerced to 1/0 for SQLite binding by the time they reach here, so
  # we look up the param's declared type to render true/false rather than
  # the raw int. Unknown placeholders (no such param) render literally as
  # `{name}` — `to_existing_atom` keeps stray template tokens from leaking
  # atoms into the VM.
  defp render_message(template, coerced, params) do
    type_by_name = Map.new(params, &{&1.name, &1.type})

    Regex.replace(~r/\{(\w+)\}/, template, fn whole, name ->
      try do
        key = String.to_existing_atom(name)
        render_val(Map.get(coerced, key, :__missing__), Map.get(type_by_name, key))
      rescue
        ArgumentError -> whole
      end
    end)
  end

  defp render_val(:__missing__, _), do: nil |> to_string()
  defp render_val(1, :boolean), do: "true"
  defp render_val(0, :boolean), do: "false"
  defp render_val(nil, _), do: ""
  defp render_val(v, _) when is_binary(v), do: v
  defp render_val(v, _), do: inspect(v)

  defp bind(stmts, coerced) do
    Enum.map(stmts, fn s ->
      Enum.map(s.param_order, fn name -> Map.fetch!(coerced, name) end)
    end)
  end

  defp execute(plugin, %Query{write: false} = q, coerced, _raw_params) do
    runner = fn sql, binds ->
      case DB.read(plugin, sql, binds) do
        {:ok, _cols, rows} -> {:ok, rows}
        {:error, _} = e -> e
      end
    end

    with :ok <- check_rejects(q, coerced, runner),
         binds = bind(q.statements, coerced),
         {:ok, cols, rows} <- run_reads(plugin, q.statements, binds),
         {:ok, value} <- coerce(rows, q.returns) do
      {:ok, cols, value}
    else
      {:error, {:rejected, _}} = rej ->
        rej

      {:error, :scalar_no_rows} = e ->
        e

      {:error, e} ->
        classify(e)
    end
  end

  defp execute(plugin, %Query{write: true} = q, coerced, raw_params) do
    txn_result =
      DB.txn(
        plugin,
        fn conn ->
          runner = fn sql, binds ->
            case Exqlite.query(conn, sql, binds) do
              {:ok, %Result{rows: nil}} -> {:ok, []}
              {:ok, %Result{rows: rows}} -> {:ok, rows}
              {:error, _} = e -> e
            end
          end

          case check_rejects(q, coerced, runner) do
            :ok ->
              binds = bind(q.statements, coerced)

              case run_writes(conn, q, binds) do
                {:ok, %Result{} = r} -> {:ok, r}
                {:error, e} -> DBConnection.rollback(conn, e)
              end

            {:error, reason} ->
              DBConnection.rollback(conn, reason)
          end
        end,
        mode: :immediate
      )

    case txn_result do
      {:ok, {:ok, %Result{} = r}} ->
        case coerce_result(r, q.returns) do
          {:ok, value} ->
            EventBus.broadcast_write(plugin, q.name, raw_params, value)
            {:ok, DB.columns(r), value}

          err ->
            err
        end

      {:error, {:rejected, _}} = rej ->
        rej

      {:error, {:validation, _}} = v ->
        v

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
