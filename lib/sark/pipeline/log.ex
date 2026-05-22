defmodule Sark.Pipeline.Log do
  @moduledoc """
  Per-plugin persistence of pipeline runs.

  Writes target the plugin's sark DB (`<plugin>.sark.db`) — independent
  of the plugin data DB, so a transactional pipeline run that rolls
  back its data writes still leaves the log row standing with terminal
  status. Two tables (versioned in `priv/internal_migrations/`):

    * `_pipeline_log` — one row per terminal run
        (run_id PK, pipeline, started_at, finished_at, status, error,
         triggered_by)
    * `_pipeline_step_log` — one row per step actually executed
        (run_id FK, step_index, step_type, started_at, finished_at,
         status, error, exit_code, stdout_bytes, stderr_tail,
         model, turns, stop_reason, input_tokens, output_tokens,
         cache_read_tokens, cache_creation_tokens, service_tier,
         final_output)

  Plugins do not own these tables — they are sark's read surface for
  the observability tools.

  Skipped runs (gated out by `when:`) do not insert rows.
  """

  alias Sark.Plugin.DB

  @type triggered_by :: :schedule | :manual

  @type step_kind :: :shell | :load | :tool | :llm
  @type status :: :success | :failed | :cancelled

  # ── pipeline log (per-run header) ────────────────────────────────────────

  @insert_run_sql ~s|
    INSERT INTO _pipeline_log
      (run_id, pipeline, started_at, finished_at, status, error, triggered_by)
    VALUES
      (?, ?, ?, ?, ?, ?, ?)
  |

  @update_run_sql ~s|
    UPDATE _pipeline_log
       SET finished_at = ?, status = ?, error = ?
     WHERE run_id = ?
  |

  @doc """
  Insert the run row at the **start** of a run, with status `:running`
  and `finished_at` = `started_at` (replaced when the run terminates).

  Inserting up front lets per-step rows reference `run_id` via FK and
  also exposes in-flight runs to observability tools.
  """
  @spec start_run(String.t(), map) :: :ok | {:error, term}
  def start_run(plugin, %{} = entry) when is_binary(plugin) do
    binds = [
      entry.run_id,
      Atom.to_string(entry.pipeline),
      entry.started_at,
      entry.started_at,
      "running",
      nil,
      Atom.to_string(entry.triggered_by)
    ]

    case DB.sark_write(plugin, @insert_run_sql, binds) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Update the terminal state of an in-flight run row.
  `status` is one of `:success` / `:failed` / `:cancelled`.
  """
  @spec finish_run(String.t(), String.t(), atom, String.t(), String.t() | nil) ::
          :ok | {:error, term}
  def finish_run(plugin, run_id, status, finished_at, error)
      when is_binary(plugin) and is_binary(run_id) and is_atom(status) and is_binary(finished_at) do
    binds = [finished_at, Atom.to_string(status), error, run_id]

    case DB.sark_write(plugin, @update_run_sql, binds) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ── step log (per-step row) ──────────────────────────────────────────────

  @insert_step_sql ~s|
    INSERT INTO _pipeline_step_log
      (run_id, step_index, step_type, started_at, finished_at, status, error,
       exit_code, stdout_bytes, stderr_tail,
       tool_name, row_count,
       model, turns, stop_reason,
       input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
       service_tier, final_output)
    VALUES
      (?, ?, ?, ?, ?, ?, ?,
       ?, ?, ?,
       ?, ?,
       ?, ?, ?,
       ?, ?, ?, ?,
       ?, ?)
  |

  @spec record_step(String.t(), map) :: :ok | {:error, term}
  def record_step(plugin, %{} = e) when is_binary(plugin) do
    binds = [
      e.run_id,
      e.step_index,
      Atom.to_string(e.step_type),
      e.started_at,
      e.finished_at,
      Atom.to_string(e.status),
      e[:error],
      e[:exit_code],
      e[:stdout_bytes],
      e[:stderr_tail],
      e[:tool_name],
      e[:row_count],
      e[:model],
      e[:turns],
      e[:stop_reason],
      e[:input_tokens],
      e[:output_tokens],
      e[:cache_read_tokens],
      e[:cache_creation_tokens],
      e[:service_tier],
      e[:final_output]
    ]

    case DB.sark_write(plugin, @insert_step_sql, binds) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ── usage accumulation (for llm steps) ───────────────────────────────────

  @doc """
  Sum two usage maps. Both are the canonical shape returned by the LLM
  adapter (`input_tokens`, `output_tokens`, `cache_read_tokens`,
  `cache_creation_tokens`, `service_tier`). nil + nil → nil; nil + n →
  n. `service_tier` takes the latest non-nil value.
  """
  @spec accumulate_usage(map | nil, map | nil) :: map | nil
  def accumulate_usage(nil, nil), do: nil
  def accumulate_usage(nil, b) when is_map(b), do: b
  def accumulate_usage(a, nil) when is_map(a), do: a

  def accumulate_usage(a, b) when is_map(a) and is_map(b) do
    %{
      input_tokens: add(a[:input_tokens], b[:input_tokens]),
      output_tokens: add(a[:output_tokens], b[:output_tokens]),
      cache_read_tokens: add(a[:cache_read_tokens], b[:cache_read_tokens]),
      cache_creation_tokens: add(a[:cache_creation_tokens], b[:cache_creation_tokens]),
      service_tier: b[:service_tier] || a[:service_tier]
    }
  end

  defp add(nil, nil), do: nil
  defp add(nil, n), do: n
  defp add(n, nil), do: n
  defp add(a, b), do: a + b
end
