defmodule Sark.MCP.Telemetry do
  @moduledoc """
  Per-tool-call logging wrapper. Wraps a handler body, logs entry +
  outcome + duration. Outcome is read off the `{:reply, content, session}`
  shape — a content map with `isError: true` is logged at `:warning`,
  everything else at `:info`.

  Caller pattern:

      def call(plugin, query, params, session) do
        Telemetry.with_logging("\#{plugin}.\#{query}", params, fn ->
          do_call(plugin, query, params, session)
        end)
      end
  """

  require Logger

  @spec with_logging(String.t(), map | nil, (-> tuple)) :: tuple
  def with_logging(label, params, fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    Logger.info("→ #{label} params=#{format_params(params)}")

    reply = fun.()
    ms = System.monotonic_time(:millisecond) - start

    case reply do
      {:reply, %{isError: true, content: content}, _session} ->
        Logger.warning("← #{label} error #{ms}ms — #{first_text(content)}")

      _ ->
        Logger.info("← #{label} ok #{ms}ms")
    end

    reply
  end

  defp format_params(nil), do: "{}"
  defp format_params(p) when is_map(p) and map_size(p) == 0, do: "{}"
  defp format_params(p), do: inspect(p)

  defp first_text([%{text: t} | _]), do: t
  defp first_text(_), do: "(no message)"
end
