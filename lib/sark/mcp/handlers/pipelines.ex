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

  @spec list(String.t(), map, term) :: {:reply, map, term}
  def list(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_list", params, fn ->
      do_list(plugin, session)
    end)
  end

  @spec log(String.t(), map, term) :: {:reply, map, term}
  def log(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_log", params, fn ->
      do_log(plugin, params, session)
    end)
  end

  @spec recent(String.t(), map, term) :: {:reply, map, term}
  def recent(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_recent", params, fn ->
      do_recent(plugin, params, session)
    end)
  end

  @spec costs(String.t(), map, term) :: {:reply, map, term}
  def costs(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_costs", params, fn ->
      do_costs(plugin, params, session)
    end)
  end

  @spec run_now(String.t(), map, term) :: {:reply, map, term}
  def run_now(plugin, params, session) do
    Telemetry.with_logging("#{plugin}.sark_pipelines_run_now", params, fn ->
      do_run_now(plugin, params, session)
    end)
  end

  # ── list ──────────────────────────────────────────────────────────────────

  defp do_list(plugin, session) do
    case Registry.get_spec(plugin) do
      :error ->
        reply_error("no such plugin: #{plugin}", session)

      {:ok, %Spec{pipelines: pipelines}} ->
        last_runs = last_runs_by_pipeline(plugin)

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
  defp last_runs_by_pipeline(plugin) do
    sql = """
    SELECT pipeline, run_id, started_at, finished_at, status, error, triggered_by
    FROM _pipeline_log AS l
    WHERE started_at = (
      SELECT MAX(started_at) FROM _pipeline_log WHERE pipeline = l.pipeline
    )
    """

    case DB.read(plugin, sql, []) do
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

  defp do_log(plugin, params, session) do
    case fetch_string(params, "pipeline") do
      {:error, msg} ->
        reply_error(msg, session)

      {:ok, pipeline_name} ->
        case resolve_run_id(plugin, pipeline_name, Map.get(params, "run_id")) do
          {:ok, run_id} ->
            reply_json(build_log_doc(plugin, run_id), session)

          {:error, msg} ->
            reply_error(msg, session)
        end
    end
  end

  defp resolve_run_id(plugin, pipeline_name, nil) do
    case DB.read(
           plugin,
           "SELECT run_id FROM _pipeline_log WHERE pipeline = ? ORDER BY started_at DESC LIMIT 1",
           [pipeline_name]
         ) do
      {:ok, _, [%{"run_id" => id}]} -> {:ok, id}
      {:ok, _, []} -> {:error, "no runs found for pipeline `#{pipeline_name}`"}
      {:error, e} -> {:error, "internal: #{inspect(e)}"}
    end
  end

  defp resolve_run_id(_plugin, _pipeline_name, run_id) when is_binary(run_id),
    do: {:ok, run_id}

  defp build_log_doc(plugin, run_id) do
    run_row =
      case DB.read(plugin, "SELECT * FROM _pipeline_log WHERE run_id = ?", [run_id]) do
        {:ok, _, [row]} -> row
        _ -> nil
      end

    step_rows =
      case DB.read(
             plugin,
             "SELECT * FROM _pipeline_step_log WHERE run_id = ? ORDER BY step_index",
             [run_id]
           ) do
        {:ok, _, rows} -> rows
        _ -> []
      end

    %{run: run_row, steps: step_rows}
  end

  # ── recent ────────────────────────────────────────────────────────────────

  defp do_recent(plugin, params, session) do
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

    case DB.read(plugin, sql, binds) do
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
  defp do_costs(plugin, params, session) do
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

    case DB.read(plugin, sql, extra_binds) do
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

  @doc false
  def reserved_names do
    ~w(
      sark_pipelines_list
      sark_pipelines_log
      sark_pipelines_recent
      sark_pipelines_costs
      sark_pipelines_run_now
    )a
  end

  @doc false
  def tool_specs do
    [
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
