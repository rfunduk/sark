defmodule Sark.MCP.Handlers.Pipelines do
  @moduledoc """
  Built-in observability tools for the per-plugin pipelines surface.

  Tools (all auto-registered on every plugin under the reserved
  `sark_pipelines_*` prefix):

    * `sark_pipelines_list` — declared pipelines + last-run summary
    * `sark_pipelines_log(pipeline, run_id?)` — full per-step log for
      one run; `run_id` omitted → most recent run for the named
      pipeline
    * `sark_pipelines_recent(pipeline?, limit?)` — recent runs across
      all pipelines (or filtered to one). Default limit 20.
    * `sark_pipelines_costs(pipeline?, since?)` — token rollup grouped
      by pipeline + model. The connected skill turns this into a $ cost
      using its own hardcoded price table; the tool returns raw
      counts.
    * `sark_pipelines_run_now(pipeline)` — fire-and-forget manual
      trigger. Mirrors `Sark.CLI.run_pipeline/1`. Returns the new
      `run_id` immediately; the run continues in the background, with
      terminal state landing in `_pipeline_log`.
    * `sark_pipelines_log_prune(pipeline?, older_than)` — delete old
      `_pipeline_log` rows. Cascades to `_pipeline_step_log` via
      explicit per-run delete (writer pool doesn't enable
      `PRAGMA foreign_keys`). Plugin author wires their own cleanup
      pipeline; no built-in schedule.

  Reads run on the plugin's read pool. The `run_now` tool delegates to
  the same `Sark.Pipeline.Lock`-mediated path the scheduler and
  `mix sark.pipeline` use, so concurrent fires drop with a friendly
  message instead of stacking duplicate runs.
  """

  require Phantom.Tool, as: Reply

  alias Sark.MCP.Registry
  alias Sark.MCP.Telemetry
  alias Sark.Plugin.DB
  alias Sark.Plugin.Pipeline
  alias Sark.Plugin.Spec

  @spec list(String.t(), map, term, keyword) :: {:reply, map, term}
  def list(plugin, params, session, opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_list", params, fn ->
      do_list(plugin, session, opts)
    end)
  end

  @spec log(String.t(), map, term, keyword) :: {:reply, map, term}
  def log(plugin, params, session, opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_log", params, fn ->
      do_log(plugin, params, session, opts)
    end)
  end

  @spec recent(String.t(), map, term, keyword) :: {:reply, map, term}
  def recent(plugin, params, session, opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_recent", params, fn ->
      do_recent(plugin, params, session, opts)
    end)
  end

  @spec costs(String.t(), map, term, keyword) :: {:reply, map, term}
  def costs(plugin, params, session, opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_costs", params, fn ->
      do_costs(plugin, params, session, opts)
    end)
  end

  @spec run_now(String.t(), map, term, keyword) :: {:reply, map, term}
  def run_now(plugin, params, session, _opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_run_now", params, fn ->
      do_run_now(plugin, params, session)
    end)
  end

  @spec prune(String.t(), map, term, keyword) :: {:reply, map, term}
  def prune(plugin, params, session, opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_log_prune", params, fn ->
      do_prune(plugin, params, session, opts)
    end)
  end

  @spec cancel(String.t(), map, term, keyword) :: {:reply, map, term}
  def cancel(plugin, params, session, _opts \\ []) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_cancel", params, fn ->
      do_cancel(plugin, params, session)
    end)
  end

  # ── list ──────────────────────────────────────────────────────────────────

  defp do_list(plugin, session, opts) do
    case Registry.get_spec(plugin) do
      :error ->
        reply_error("no such plugin: #{plugin}", session)

      {:ok, %Spec{pipelines: pipelines}} ->
        last_runs = last_runs_by_pipeline(plugin, opts)

        rows =
          Enum.map(pipelines, fn %Pipeline{} = p ->
            last = Map.get(last_runs, Atom.to_string(p.name))
            schedule_str = format_schedule(p.schedule)

            %{
              name: Atom.to_string(p.name),
              description: p.description,
              schedule: schedule_str,
              steps: length(p.steps),
              last_run: last
            }
          end)

        reply_json(rows, session)
    end
  end

  # Most recent run per pipeline. SQLite window-functions / row_number works
  # but a simple correlated subquery is more readable for a small set.
  defp last_runs_by_pipeline(plugin, opts) do
    sql = """
    SELECT pipeline, run_id, started_at, finished_at, status, error, triggered_by
    FROM _pipeline_log AS l
    WHERE started_at = (
      SELECT MAX(started_at) FROM _pipeline_log WHERE pipeline = l.pipeline
    )
    """

    case DB.read(plugin, sql, [], opts) do
      {:ok, _, rows} ->
        Enum.into(rows, %{}, fn row -> {row["pipeline"], row} end)

      _ ->
        %{}
    end
  end

  defp format_schedule(nil), do: nil

  defp format_schedule(%Crontab.CronExpression{} = expr) do
    # `composition: true` produces the standard 5-field form.
    case Crontab.CronExpression.Composer.compose(expr) do
      s when is_binary(s) -> s
      _ -> inspect(expr)
    end
  end

  # ── log ───────────────────────────────────────────────────────────────────

  defp do_log(plugin, params, session, opts) do
    case fetch_string(params, "pipeline") do
      {:error, msg} ->
        reply_error(msg, session)

      {:ok, pipeline_name} ->
        case resolve_run_id(plugin, pipeline_name, Map.get(params, "run_id"), opts) do
          {:ok, run_id} ->
            reply_json(build_log_doc(plugin, run_id, opts), session)

          {:error, msg} ->
            reply_error(msg, session)
        end
    end
  end

  defp resolve_run_id(plugin, pipeline_name, nil, opts) do
    case DB.read(
           plugin,
           "SELECT run_id FROM _pipeline_log WHERE pipeline = ? ORDER BY started_at DESC LIMIT 1",
           [pipeline_name],
           opts
         ) do
      {:ok, _, [%{"run_id" => id}]} -> {:ok, id}
      {:ok, _, []} -> {:error, "no runs found for pipeline `#{pipeline_name}`"}
      {:error, e} -> {:error, "internal: #{inspect(e)}"}
    end
  end

  defp resolve_run_id(_plugin, _pipeline_name, run_id, _opts) when is_binary(run_id),
    do: {:ok, run_id}

  defp build_log_doc(plugin, run_id, opts) do
    run_row =
      case DB.read(plugin, "SELECT * FROM _pipeline_log WHERE run_id = ?", [run_id], opts) do
        {:ok, _, [row]} -> row
        _ -> nil
      end

    step_rows =
      case DB.read(
             plugin,
             "SELECT * FROM _pipeline_step_log WHERE run_id = ? ORDER BY step_index",
             [run_id],
             opts
           ) do
        {:ok, _, rows} -> rows
        _ -> []
      end

    %{run: run_row, steps: step_rows}
  end

  # ── recent ────────────────────────────────────────────────────────────────

  defp do_recent(plugin, params, session, opts) do
    limit = parse_limit(Map.get(params, "limit"), 20)
    pipeline = Map.get(params, "pipeline")

    {sql, binds} =
      case pipeline do
        nil ->
          {"""
           SELECT run_id, pipeline, started_at, finished_at, status, error, triggered_by
           FROM _pipeline_log
           ORDER BY started_at DESC
           LIMIT ?
           """, [limit]}

        name when is_binary(name) ->
          {"""
           SELECT run_id, pipeline, started_at, finished_at, status, error, triggered_by
           FROM _pipeline_log
           WHERE pipeline = ?
           ORDER BY started_at DESC
           LIMIT ?
           """, [name, limit]}
      end

    case DB.read(plugin, sql, binds, opts) do
      {:ok, _, rows} -> reply_json(rows, session)
      {:error, e} -> reply_error("internal: #{inspect(e)}", session)
    end
  end

  defp parse_limit(nil, default), do: default
  defp parse_limit(n, _) when is_integer(n) and n > 0, do: n

  defp parse_limit(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_limit(_, default), do: default

  # ── costs ─────────────────────────────────────────────────────────────────

  # Returns token rollups grouped by (pipeline, model). The connected skill
  # turns these into dollar amounts using a price table it maintains.
  defp do_costs(plugin, params, session, opts) do
    pipeline_filter = Map.get(params, "pipeline")
    since = Map.get(params, "since")

    {extra_where, extra_binds} =
      Enum.reduce(
        [
          {pipeline_filter, "l.pipeline = ?"},
          {since, "l.started_at >= ?"}
        ],
        {"", []},
        fn
          {nil, _}, acc -> acc
          {v, clause}, {w, b} -> {w <> " AND " <> clause, b ++ [v]}
        end
      )

    sql = """
    SELECT l.pipeline,
           s.model,
           COUNT(*)                         AS run_count,
           SUM(COALESCE(s.input_tokens, 0))          AS input_tokens,
           SUM(COALESCE(s.output_tokens, 0))         AS output_tokens,
           SUM(COALESCE(s.cache_read_tokens, 0))     AS cache_read_tokens,
           SUM(COALESCE(s.cache_creation_tokens, 0)) AS cache_creation_tokens
    FROM _pipeline_step_log AS s
    JOIN _pipeline_log AS l ON l.run_id = s.run_id
    WHERE s.step_type = 'llm'
      AND s.model IS NOT NULL
      #{extra_where}
    GROUP BY l.pipeline, s.model
    ORDER BY l.pipeline, s.model
    """

    case DB.read(plugin, sql, extra_binds, opts) do
      {:ok, _, rows} -> reply_json(rows, session)
      {:error, e} -> reply_error("internal: #{inspect(e)}", session)
    end
  end

  # ── run_now ───────────────────────────────────────────────────────────────

  defp do_run_now(plugin, params, session) do
    case fetch_string(params, "pipeline") do
      {:error, msg} ->
        reply_error(msg, session)

      {:ok, pipeline_name} ->
        target = "#{plugin}.#{pipeline_name}"

        try do
          case Sark.CLI.run_pipeline(target) do
            {:triggered, _target, run_id} ->
              reply_json(%{ok: true, run_id: run_id}, session)

            {:busy, _target, existing} ->
              reply_error(
                "busy: pipeline `#{pipeline_name}` already running as #{existing}",
                session
              )
          end
        rescue
          e in ArgumentError ->
            reply_error("validation: #{Exception.message(e)}", session)
        end
    end
  end

  # ── cancel ────────────────────────────────────────────────────────────────

  # Best-effort cancel. Looks up an in-flight run for the named pipeline
  # via Sark.Pipeline.Lock and sets a cancel flag in Sark.Pipeline.Cancel.
  # The runner peeks the flag between steps and bails before the next
  # one. Current step finishes naturally.
  defp do_cancel(plugin, params, session) do
    case fetch_string(params, "pipeline") do
      {:error, msg} ->
        reply_error(msg, session)

      {:ok, pipeline_name} ->
        case resolve_cancel_run_id(plugin, pipeline_name, Map.get(params, "run_id")) do
          {:ok, run_id} ->
            :ok = Sark.Pipeline.Cancel.request(run_id)
            reply_json(%{ok: true, run_id: run_id}, session)

          {:error, msg} ->
            reply_error(msg, session)
        end
    end
  end

  defp resolve_cancel_run_id(plugin, pipeline_name, nil) do
    pipeline_atom = String.to_atom(pipeline_name)

    case Enum.find(Sark.Pipeline.Lock.in_flight(), fn {p, n, _} ->
           p == plugin and n == pipeline_atom
         end) do
      {_, _, run_id} -> {:ok, run_id}
      nil -> {:error, "no in-flight run for pipeline `#{pipeline_name}`"}
    end
  end

  defp resolve_cancel_run_id(_plugin, _pipeline_name, run_id) when is_binary(run_id),
    do: {:ok, run_id}

  # ── prune ─────────────────────────────────────────────────────────────────

  # Deletes `_pipeline_log` rows whose `finished_at` is older than
  # `older_than` (duration like "30d"). Cascades to `_pipeline_step_log`
  # via an explicit per-run DELETE — the writer pool isn't opened with
  # `PRAGMA foreign_keys = ON`, so we don't rely on FK cascade.
  defp do_prune(plugin, params, session, opts) do
    with {:ok, older_than} <- fetch_string(params, "older_than"),
         {:ok, seconds} <- parse_duration(older_than) do
      pipeline_filter =
        case Map.get(params, "pipeline") do
          v when is_binary(v) and v != "" -> v
          _ -> nil
        end

      cutoff =
        DateTime.utc_now()
        |> DateTime.add(-seconds, :second)
        |> DateTime.to_iso8601()

      case run_prune(plugin, pipeline_filter, cutoff, opts) do
        {:ok, deleted} -> reply_json(%{deleted: deleted}, session)
        {:error, msg} -> reply_error(msg, session)
      end
    else
      {:error, msg} -> reply_error(msg, session)
    end
  end

  # When called from a transactional pipeline, `opts[:conn]` holds the
  # writer conn — skip the nested DB.txn (would deadlock on a 1-conn
  # writer pool) and run statements directly on the caller's conn.
  defp run_prune(plugin, pipeline_filter, cutoff, opts) do
    {count_sql, step_sql, log_sql, binds} = prune_sql(pipeline_filter, cutoff)

    case Keyword.get(opts, :conn) do
      nil ->
        DB.txn(plugin, fn conn ->
          prune_exec(conn, count_sql, step_sql, log_sql, binds)
        end)
        |> case do
          {:ok, n} -> {:ok, n}
          {:error, e} -> {:error, "internal: #{inspect(e)}"}
        end

      conn ->
        try do
          {:ok, prune_exec(conn, count_sql, step_sql, log_sql, binds)}
        rescue
          e -> {:error, "internal: #{Exception.message(e)}"}
        end
    end
  end

  defp prune_sql(nil, cutoff) do
    {
      "SELECT COUNT(*) AS n FROM _pipeline_log WHERE finished_at < ?",
      "DELETE FROM _pipeline_step_log WHERE run_id IN (SELECT run_id FROM _pipeline_log WHERE finished_at < ?)",
      "DELETE FROM _pipeline_log WHERE finished_at < ?",
      [cutoff]
    }
  end

  defp prune_sql(name, cutoff) do
    {
      "SELECT COUNT(*) AS n FROM _pipeline_log WHERE pipeline = ? AND finished_at < ?",
      "DELETE FROM _pipeline_step_log WHERE run_id IN (SELECT run_id FROM _pipeline_log WHERE pipeline = ? AND finished_at < ?)",
      "DELETE FROM _pipeline_log WHERE pipeline = ? AND finished_at < ?",
      [name, cutoff]
    }
  end

  defp prune_exec(conn, count_sql, step_sql, log_sql, binds) do
    {:ok, %{rows: [[n]]}} = Exqlite.query(conn, count_sql, binds)
    {:ok, _} = Exqlite.query(conn, step_sql, binds)
    {:ok, _} = Exqlite.query(conn, log_sql, binds)
    n
  end

  # Duration string → seconds. Supports s/m/h/d/w/y suffixes. `y` is
  # 365d (not calendar-correct — fine for log retention).
  @doc false
  def parse_duration(s) when is_binary(s) do
    case Regex.run(~r/^\s*(\d+)\s*([smhdwy])\s*$/i, s) do
      [_, n, unit] ->
        n = String.to_integer(n)

        secs =
          case String.downcase(unit) do
            "s" -> n
            "m" -> n * 60
            "h" -> n * 3600
            "d" -> n * 86_400
            "w" -> n * 604_800
            "y" -> n * 31_536_000
          end

        {:ok, secs}

      _ ->
        {:error,
         "validation: `older_than` must look like '30d' / '6h' / '90m' (got #{inspect(s)})"}
    end
  end

  def parse_duration(other),
    do: {:error, "validation: `older_than` must be a duration string, got #{inspect(other)}"}

  @doc false
  def reserved_names do
    ~w(
      sark_pipelines_list
      sark_pipelines_log
      sark_pipelines_recent
      sark_pipelines_costs
      sark_pipelines_run_now
      sark_pipelines_cancel
      sark_pipelines_log_prune
    )a
  end

  @doc false
  def tool_specs do
    [
      %{
        name: "sark_pipelines_cancel",
        description:
          "Best-effort cancel of an in-flight pipeline run. The runner peeks between steps; the current step finishes naturally before the run halts. `run_id` optional — defaults to the in-flight run for `pipeline`. Returns `{ok: true, run_id}`.",
        input_schema: %{
          type: "object",
          required: ["pipeline"],
          properties: %{
            "pipeline" => %{type: "string", description: "Pipeline name."},
            "run_id" => %{
              type: "string",
              description: "Run id. Omit for the in-flight run."
            }
          }
        }
      },
      %{
        name: "sark_pipelines_log_prune",
        description:
          "Delete old `_pipeline_log` rows (and their step rows) for this plugin. `older_than` is a duration like '30d' / '6h' / '90m' / '1y'. `pipeline` optional → all pipelines in this plugin. Returns `{deleted: N}`. Cascades to `_pipeline_step_log` via explicit per-run delete.",
        input_schema: %{
          type: "object",
          required: ["older_than"],
          properties: %{
            "pipeline" => %{
              type: "string",
              description: "Filter to one pipeline. Omit for all pipelines."
            },
            "older_than" => %{
              type: "string",
              description: "Duration string ('30d', '6h', '90m', '1y')."
            }
          }
        }
      },
      %{
        name: "sark_pipelines_list",
        description:
          "List declared pipelines for this plugin and a summary of each pipeline's most recent run.",
        input_schema: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "sark_pipelines_log",
        description:
          "Full per-step log for a single pipeline run. Pass `pipeline` (required) and optional `run_id` (defaults to the latest run for that pipeline).",
        input_schema: %{
          type: "object",
          required: ["pipeline"],
          properties: %{
            "pipeline" => %{type: "string", description: "Pipeline name."},
            "run_id" => %{
              type: "string",
              description: "Run id. Omit for the most recent run."
            }
          }
        }
      },
      %{
        name: "sark_pipelines_recent",
        description:
          "Recent pipeline runs across all pipelines (or filtered to one). Returns up to `limit` rows (default 20), newest first.",
        input_schema: %{
          type: "object",
          properties: %{
            "pipeline" => %{type: "string", description: "Filter to one pipeline."},
            "limit" => %{type: "integer", description: "Max rows. Default 20."}
          },
          required: []
        }
      },
      %{
        name: "sark_pipelines_costs",
        description:
          "Token rollup for `llm:` steps grouped by pipeline + model. The skill multiplies by its hardcoded price table to produce dollar amounts.",
        input_schema: %{
          type: "object",
          properties: %{
            "pipeline" => %{type: "string", description: "Filter to one pipeline."},
            "since" => %{
              type: "string",
              description: "ISO8601 lower bound on started_at."
            }
          },
          required: []
        }
      },
      %{
        name: "sark_pipelines_run_now",
        description:
          "Trigger a manual fire of a pipeline. Returns the new run_id immediately — the run continues in the background, with terminal state recorded in `_pipeline_log`. Returns `busy:` if a run is already in flight.",
        input_schema: %{
          type: "object",
          required: ["pipeline"],
          properties: %{
            "pipeline" => %{type: "string", description: "Pipeline name."}
          }
        }
      }
    ]
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "validation: `#{key}` is required (string)"}
    end
  end

  defp reply_json(value, session), do: {:reply, Reply.text(Jason.encode!(value)), session}
  defp reply_error(msg, session), do: {:reply, Reply.error(msg), session}
end
