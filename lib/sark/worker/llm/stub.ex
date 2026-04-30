defmodule Sark.Worker.LLM.Stub do
  @moduledoc """
  Deterministic LLM stub for tests.

  Drive a worker loop without hitting Anthropic by pre-loading a script
  of turns. Each call to `chat/1` pops the next turn from the script
  and returns it as a canonical `Response`.

  Usage:

      script = [
        %{text: "thinking", tool_uses: [%{id: "1", name: "list", input: %{}}]},
        %{text: "done", tool_uses: [], stop_reason: :end_turn}
      ]

      {:ok, _} = Sark.Worker.LLM.Stub.start_link(script)

      Sark.Worker.LLM.Stub.chat(%{model: "x", messages: []})

  Also records every `chat/1` call so tests can assert on what the
  runner sent (messages, tools, system prompt). Inspect via
  `recorded_calls/0`.
  """

  use Agent

  @behaviour Sark.Worker.LLM

  alias Sark.Worker.LLM.Response

  @type turn :: %{
          optional(:text) => String.t(),
          optional(:tool_uses) => [%{id: String.t(), name: String.t(), input: map}],
          optional(:stop_reason) => Response.stop_reason()
        }

  @spec start_link([turn]) :: Agent.on_start()
  def start_link(script) when is_list(script) do
    Agent.start_link(fn -> %{script: script, calls: []} end, name: __MODULE__)
  end

  @spec stop() :: :ok
  def stop do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    :ok
  end

  @spec recorded_calls() :: [map]
  def recorded_calls do
    Agent.get(__MODULE__, fn %{calls: calls} -> Enum.reverse(calls) end)
  end

  @impl true
  def chat(opts) do
    case Agent.get_and_update(__MODULE__, fn state ->
           record = %{calls: [opts | state.calls]}

           case state.script do
             [] -> {:no_script, Map.merge(state, record)}
             [turn | rest] -> {{:turn, turn}, %{state | script: rest, calls: record.calls}}
           end
         end) do
      :no_script ->
        {:error, :stub_script_exhausted}

      {:turn, turn} ->
        {:ok, response_from(turn)}
    end
  end

  defp response_from(turn) do
    text = Map.get(turn, :text, "")
    tool_uses = Map.get(turn, :tool_uses, [])

    text_block = if text == "", do: [], else: [%{type: :text, text: text}]

    tool_blocks =
      Enum.map(tool_uses, fn tu ->
        %{type: :tool_use, id: tu.id, name: tu.name, input: tu.input}
      end)

    stop = Map.get(turn, :stop_reason, default_stop(tool_uses))

    %Response{
      stop_reason: stop,
      content: text_block ++ tool_blocks,
      usage: Map.get(turn, :usage)
    }
  end

  defp default_stop([]), do: :end_turn
  defp default_stop(_), do: :tool_use
end
