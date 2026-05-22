defmodule Sark.Pipeline.State do
  @moduledoc """
  Per-pipeline scheduler state — currently just an `enabled / disabled`
  flag persisted in `_pipeline_state` on the plugin's sark DB.

  Semantics:

    * **No row** for a pipeline → enabled (scheduler fires normally).
    * **`disabled = 1`** → scheduler silently skips. Manual runs
      (`sark_pipelines_run_now`, `mix sark.pipeline`) still fire.
    * **`disabled = 0`** → enabled. Identical to no-row; this is the
      post-`enable` state of a previously-disabled pipeline.

  Disabled pipelines that get skipped at tick time write **nothing** —
  no `_pipeline_log` row. Same posture as `when:`-gated skips.

  Read path is uncached; the table is tiny and reads run on the sark
  read pool. Reads happen once per tick per scheduled pipeline.
  """

  alias Sark.Plugin.DB

  @doc """
  Returns `true` if the named pipeline is currently disabled on the
  given plugin. Defaults to `false` when no row exists or the read
  fails (fail-open: a sark-DB hiccup shouldn't silently disable
  scheduled work).
  """
  @spec disabled?(String.t(), atom | String.t()) :: boolean
  def disabled?(plugin, pipeline_name) when is_binary(plugin) do
    name = pipeline_string(pipeline_name)

    try do
      case DB.sark_read(
             plugin,
             "SELECT disabled FROM _pipeline_state WHERE pipeline = ?",
             [name]
           ) do
        {:ok, _, [%{"disabled" => 1}]} -> true
        _ -> false
      end
    catch
      :exit, _ -> false
    end
  end

  @doc """
  Mark a pipeline disabled. Upsert on `pipeline`.
  """
  @spec disable(String.t(), atom | String.t()) :: :ok | {:error, term}
  def disable(plugin, pipeline_name), do: set(plugin, pipeline_name, 1)

  @doc """
  Mark a pipeline enabled (clears any disabled flag).
  """
  @spec enable(String.t(), atom | String.t()) :: :ok | {:error, term}
  def enable(plugin, pipeline_name), do: set(plugin, pipeline_name, 0)

  defp set(plugin, pipeline_name, value) when value in [0, 1] do
    name = pipeline_string(pipeline_name)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    sql = """
    INSERT INTO _pipeline_state (pipeline, disabled, updated_at)
    VALUES (?, ?, ?)
    ON CONFLICT(pipeline) DO UPDATE SET disabled = excluded.disabled,
                                        updated_at = excluded.updated_at
    """

    case DB.sark_write(plugin, sql, [name, value, now]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp pipeline_string(name) when is_atom(name), do: Atom.to_string(name)
  defp pipeline_string(name) when is_binary(name), do: name
end
