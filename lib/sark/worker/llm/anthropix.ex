defmodule Sark.Worker.LLM.Anthropix do
  @moduledoc """
  Anthropic API impl of `Sark.Worker.LLM` via the `anthropix` library.

  API key sourced from the `ANTHROPIC_API_KEY` env var unless an
  explicit `:client` is passed in opts.

  Caching: we attach `cache_control: {type: ephemeral}` to the system
  prompt and to the last tool definition. Tool list and system prompt
  are stable across turns within a single worker run, so subsequent
  turns hit the cache. (5m TTL — workers that run on long cadences
  won't carry cache hits across runs; that's fine.)

  Streaming: every call uses SSE streaming under the hood. Workers
  don't display turn-by-turn text, so we don't expose intermediate
  events — events are folded into a final raw-shaped response map and
  passed through the same decoder as the non-streaming path. Reason
  for streaming-always: removes the ~10min non-streaming request
  ceiling (matters once a worker starts using extended thinking or
  emits long final outputs).
  """

  @behaviour Sark.Worker.LLM

  alias Sark.Worker.LLM.Response

  @cache_control %{type: "ephemeral"}

  # Retry: 5xx + 429 + transport errors. Bounded attempts, exponential
  # backoff. Mid-stream failures restart from scratch (idempotent — the
  # request is read-only on the user side; resampling is fine).
  @max_attempts 3
  @base_backoff_ms 1_000

  @impl true
  def chat(opts) do
    client = Map.get_lazy(opts, :client, &default_client/0)

    payload =
      %{
        model: Map.fetch!(opts, :model),
        messages: Enum.map(Map.fetch!(opts, :messages), &encode_message/1),
        max_tokens: Map.get(opts, :max_tokens, 4096),
        stream: true
      }
      |> maybe_put(:system, encode_system(Map.get(opts, :system)))
      |> maybe_put(:tools, encode_tools(Map.get(opts, :tools, [])))
      |> Map.to_list()

    do_chat(client, payload, 1)
  end

  defp do_chat(client, payload, attempt) do
    case attempt_chat(client, payload) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        if attempt < @max_attempts and retryable?(reason) do
          ms = backoff_ms(attempt)
          require Logger

          Logger.warning(
            "anthropix retry #{attempt}/#{@max_attempts - 1} in #{ms}ms — #{inspect(reason)}"
          )

          Process.sleep(ms)
          do_chat(client, payload, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  defp attempt_chat(client, payload) do
    case Anthropix.chat(client, payload) do
      {:ok, stream} ->
        try do
          {:ok, stream |> accumulate_stream() |> decode()}
        rescue
          e -> {:error, e}
        catch
          :exit, reason -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def retryable?(%Anthropix.APIError{status: status}) when is_integer(status),
    do: status >= 500 or status == 429

  def retryable?(%{__exception__: true} = e) do
    case e do
      %{reason: :timeout} -> true
      %{reason: :closed} -> true
      %{reason: :econnrefused} -> true
      %{reason: :nxdomain} -> true
      _ -> match?("Mint." <> _, inspect(e.__struct__))
    end
  end

  def retryable?(_), do: false

  defp backoff_ms(attempt), do: (@base_backoff_ms * :math.pow(2, attempt - 1)) |> trunc()

  # ── streaming accumulator ───────────────────────────────────────────
  #
  # Folds SSE events into a raw-shaped map identical to a non-streaming
  # response body, then `decode/1` runs unchanged.
  #
  # Block indexing: Anthropic emits content_block_start / _delta / _stop
  # keyed by `index`. We track blocks in a map and finalize on stop —
  # tool_use blocks accumulate `partial_json` deltas into a string and
  # JSON-decode at finalization.

  @doc false
  def accumulate_stream(stream) do
    initial = %{
      blocks: %{},
      block_order: [],
      partial_json: %{},
      stop_reason: nil,
      usage_start: %{},
      usage_delta: %{}
    }

    state = Enum.reduce(stream, initial, &handle_event/2)

    blocks =
      state.block_order
      |> Enum.reverse()
      |> Enum.map(fn idx ->
        block = Map.fetch!(state.blocks, idx)
        finalize_block(block, Map.get(state.partial_json, idx))
      end)

    %{
      "stop_reason" => state.stop_reason,
      "content" => blocks,
      "usage" => merge_usage(state.usage_start, state.usage_delta)
    }
  end

  defp handle_event(%{"type" => "message_start", "message" => msg}, state) do
    %{state | usage_start: Map.get(msg, "usage") || %{}}
  end

  defp handle_event(
         %{"type" => "content_block_start", "index" => i, "content_block" => block},
         state
       ) do
    %{
      state
      | blocks: Map.put(state.blocks, i, block),
        block_order: [i | state.block_order]
    }
  end

  defp handle_event(
         %{
           "type" => "content_block_delta",
           "index" => i,
           "delta" => %{"type" => "text_delta", "text" => t}
         },
         state
       ) do
    update_in(state, [:blocks, i, "text"], fn cur -> (cur || "") <> t end)
  end

  defp handle_event(
         %{
           "type" => "content_block_delta",
           "index" => i,
           "delta" => %{"type" => "input_json_delta", "partial_json" => chunk}
         },
         state
       ) do
    %{state | partial_json: Map.update(state.partial_json, i, chunk, &(&1 <> chunk))}
  end

  defp handle_event(%{"type" => "content_block_stop"}, state), do: state

  defp handle_event(
         %{"type" => "message_delta", "delta" => delta} = ev,
         state
       ) do
    state = %{state | stop_reason: Map.get(delta, "stop_reason") || state.stop_reason}

    case Map.get(ev, "usage") do
      nil -> state
      u -> %{state | usage_delta: u}
    end
  end

  defp handle_event(%{"type" => "message_stop"}, state), do: state

  # ping, unknown — ignore
  defp handle_event(_, state), do: state

  defp finalize_block(%{"type" => "tool_use"} = block, partial_json) do
    input =
      case partial_json do
        nil ->
          Map.get(block, "input") || %{}

        "" ->
          Map.get(block, "input") || %{}

        json ->
          case Jason.decode(json) do
            {:ok, decoded} -> decoded
            {:error, _} -> %{"_raw" => json}
          end
      end

    Map.put(block, "input", input)
  end

  defp finalize_block(block, _), do: block

  # Anthropic returns input/cache fields at message_start, output_tokens
  # at message_delta. Merge into one map for the existing decode path.
  defp merge_usage(start_u, delta_u) do
    Map.merge(start_u, delta_u)
  end

  defp default_client do
    case Sark.Boot.load_config!() do
      %Sark.Config{anthropic_api_key: key} when is_binary(key) and key != "" ->
        Anthropix.init(key)

      _ ->
        raise "anthropic_api_key not set in config.yml (use a literal value or `${VAR}` for env interpolation)"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Wrap system prompt as a single cached text block. Anthropix accepts
  # either a string or a list of permissive maps; we use the list form so
  # we can attach cache_control. Empty/nil → omit so caching isn't
  # advertised on a vacant system prompt.
  defp encode_system(nil), do: nil
  defp encode_system(""), do: nil

  defp encode_system(text) when is_binary(text) do
    [%{type: "text", text: text, cache_control: @cache_control}]
  end

  defp encode_message(%{role: role, content: content}) when is_binary(content) do
    %{role: Atom.to_string(role), content: content}
  end

  defp encode_message(%{role: role, content: blocks}) when is_list(blocks) do
    %{role: Atom.to_string(role), content: Enum.map(blocks, &encode_block/1)}
  end

  defp encode_block(%{type: :text, text: t}), do: %{type: "text", text: t}

  defp encode_block(%{type: :tool_use, id: id, name: name, input: input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp encode_block(%{type: :tool_result, tool_use_id: id, content: content, is_error: err}) do
    base = %{type: "tool_result", tool_use_id: id, content: content}
    if err, do: Map.put(base, :is_error, true), else: base
  end

  defp encode_tools([]), do: []

  defp encode_tools(tools) do
    encoded =
      Enum.map(tools, fn t ->
        %{
          name: t.name,
          description: t.description,
          input_schema: t.input_schema
        }
      end)

    # Cache up through the entire tool list by tagging the last entry.
    {init, [last]} = Enum.split(encoded, length(encoded) - 1)
    init ++ [Map.put(last, :cache_control, @cache_control)]
  end

  @doc false
  def decode(raw) when is_map(raw) do
    %Response{
      stop_reason: decode_stop(Map.get(raw, "stop_reason")),
      content: Enum.map(Map.get(raw, "content", []), &decode_block/1),
      usage: decode_usage(Map.get(raw, "usage"))
    }
  end

  defp decode_stop("end_turn"), do: :end_turn
  defp decode_stop("tool_use"), do: :tool_use
  defp decode_stop("max_tokens"), do: :max_tokens
  defp decode_stop("stop_sequence"), do: :stop_sequence
  defp decode_stop(other), do: other

  defp decode_block(%{"type" => "text", "text" => t}), do: %{type: :text, text: t}

  defp decode_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{type: :tool_use, id: id, name: name, input: input}
  end

  defp decode_block(other), do: %{type: :unknown, raw: other}

  # Canonical usage shape for the runner / log. We sum the 5m + 1h cache
  # creation buckets into one column — the split is not interesting for
  # sark's daily/weekly worker cadences (cache hits ~always 0 across
  # runs anyway). Within-run hits show up as cache_read_tokens.
  defp decode_usage(nil), do: nil

  defp decode_usage(%{} = u) do
    create_5m = get_int(u, "cache_creation_input_tokens_5m", 0)
    create_1h = get_int(u, "cache_creation_input_tokens_1h", 0)
    create_flat = get_int(u, "cache_creation_input_tokens", 0)

    %{
      input_tokens: get_int(u, "input_tokens"),
      output_tokens: get_int(u, "output_tokens"),
      cache_read_tokens: get_int(u, "cache_read_input_tokens"),
      cache_creation_tokens: nil_if_zero(create_flat + create_5m + create_1h),
      service_tier: Map.get(u, "service_tier")
    }
  end

  defp get_int(map, key), do: Map.get(map, key)
  defp get_int(map, key, default), do: Map.get(map, key) || default

  defp nil_if_zero(0), do: nil
  defp nil_if_zero(n), do: n
end
