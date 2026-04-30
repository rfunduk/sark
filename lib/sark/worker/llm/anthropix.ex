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
  """

  @behaviour Sark.Worker.LLM

  alias Sark.Worker.LLM.Response

  @cache_control %{type: "ephemeral"}

  @impl true
  def chat(opts) do
    client = Map.get_lazy(opts, :client, &default_client/0)

    payload =
      %{
        model: Map.fetch!(opts, :model),
        messages: Enum.map(Map.fetch!(opts, :messages), &encode_message/1),
        max_tokens: Map.get(opts, :max_tokens, 4096)
      }
      |> maybe_put(:system, encode_system(Map.get(opts, :system)))
      |> maybe_put(:tools, encode_tools(Map.get(opts, :tools, [])))

    case Anthropix.chat(client, Map.to_list(payload)) do
      {:ok, raw} -> {:ok, decode(raw)}
      {:error, reason} -> {:error, reason}
    end
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

  defp decode(raw) when is_map(raw) do
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
