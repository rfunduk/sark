defmodule Sark.Worker.LLM do
  @moduledoc """
  Generic LLM client behaviour used by the worker runner.

  Sark canonicalizes on Anthropic's message + tool-use shape because
  it's the more expressive surface (tool_use / tool_result blocks tied
  by id, multi-block content). Adapters for other providers (OpenAI,
  etc.) translate inbound calls into this shape and translate
  responses back out to the canonical `Response` struct.

  Implementations:

    * `Sark.Worker.LLM.Anthropix` — production impl, calls Anthropic API
    * `Sark.Worker.LLM.Stub` — test impl, replays a canned script of turns
  """

  alias Sark.Worker.LLM.Response

  @typedoc """
  Conversation message in canonical (Anthropic) shape.

  `:content` is a string for simple user/assistant turns or a list of
  blocks (text / tool_use / tool_result) for tool-use turns.
  """
  @type message :: %{
          role: :user | :assistant,
          content: String.t() | [block]
        }

  @type block ::
          %{type: :text, text: String.t()}
          | %{type: :tool_use, id: String.t(), name: String.t(), input: map}
          | %{type: :tool_result, tool_use_id: String.t(), content: String.t(), is_error: boolean}

  @type tool_schema :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map
        }

  @type chat_opts :: %{
          required(:model) => String.t(),
          required(:messages) => [message],
          optional(:system) => String.t(),
          optional(:tools) => [tool_schema],
          optional(:max_tokens) => pos_integer
        }

  @callback chat(chat_opts) :: {:ok, Response.t()} | {:error, term}
end

defmodule Sark.Worker.LLM.Response do
  @moduledoc """
  Canonical chat response.

  `:usage` is either `nil` (provider didn't surface usage) or a map
  with the fields the runner accumulates and the log table stores:

      %{
        input_tokens:           non_neg_integer | nil,
        output_tokens:          non_neg_integer | nil,
        cache_read_tokens:      non_neg_integer | nil,
        cache_creation_tokens:  non_neg_integer | nil,
        service_tier:           String.t() | nil
      }
  """

  @enforce_keys [:stop_reason, :content]
  defstruct [:stop_reason, :content, usage: nil]

  @type stop_reason :: :end_turn | :tool_use | :max_tokens | :stop_sequence | term

  @type usage :: %{
          input_tokens: non_neg_integer | nil,
          output_tokens: non_neg_integer | nil,
          cache_read_tokens: non_neg_integer | nil,
          cache_creation_tokens: non_neg_integer | nil,
          service_tier: String.t() | nil
        }

  @type t :: %__MODULE__{
          stop_reason: stop_reason,
          content: [Sark.Worker.LLM.block()],
          usage: usage | nil
        }

  @doc "Extract just the tool_use blocks from a response."
  @spec tool_uses(t) :: [map]
  def tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &match?(%{type: :tool_use}, &1))
  end

  @doc "Extract concatenated text from a response, ignoring tool_use blocks."
  @spec text(t) :: String.t()
  def text(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("\n", & &1.text)
  end
end
