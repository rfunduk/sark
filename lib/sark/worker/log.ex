defmodule Sark.Worker.Log do
  @moduledoc """
  Persist a single worker run to the plugin's `_worker_log` table.

  Called by `Sark.Worker.Runner` on every terminal state — `:end_turn`,
  `:max_tokens`, `:stop_sequence`, `:max_turns_exceeded`, `:error`. A
  run that the `when:` gate skipped does **not** reach here (no run
  happened, nothing to log).

  Token columns sum across every chat call in the run; nil usage from
  any provider (e.g. the test stub) bubbles through as NULL.
  """

  alias Sark.Plugin.DB

  @type entry :: %{
          worker_name: String.t(),
          provider: String.t() | nil,
          model: String.t() | nil,
          started_at: String.t(),
          ended_at: String.t(),
          turns: non_neg_integer | nil,
          stop_reason: String.t(),
          input_tokens: non_neg_integer | nil,
          output_tokens: non_neg_integer | nil,
          cache_read_tokens: non_neg_integer | nil,
          cache_creation_tokens: non_neg_integer | nil,
          service_tier: String.t() | nil,
          error: String.t() | nil,
          final_output: String.t() | nil
        }

  @insert_sql ~s|
    INSERT INTO _worker_log
      (worker_name, provider, model, started_at, ended_at, turns, stop_reason,
       input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
       service_tier, error, final_output)
    VALUES
      (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  |

  @spec record(String.t(), entry) :: {:ok, integer} | {:error, term}
  def record(plugin, %{} = e) when is_binary(plugin) do
    binds = [
      e.worker_name,
      e.provider,
      e.model,
      e.started_at,
      e.ended_at,
      e.turns,
      e.stop_reason,
      e.input_tokens,
      e.output_tokens,
      e.cache_read_tokens,
      e.cache_creation_tokens,
      e.service_tier,
      e.error,
      e.final_output
    ]

    case DB.write(plugin, @insert_sql, binds) do
      {:ok, _result} -> {:ok, :inserted}
      {:error, _} = err -> err
    end
  end

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
