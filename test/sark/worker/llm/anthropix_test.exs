defmodule Sark.Worker.LLM.AnthropixTest do
  use ExUnit.Case, async: true

  alias Anthropix.APIError
  alias Sark.Worker.LLM.Anthropix
  alias Sark.Worker.LLM.Response

  describe "stream accumulation → decode" do
    test "text-only response folds deltas into one text block" do
      events = [
        %{
          "type" => "message_start",
          "message" => %{
            "usage" => %{
              "input_tokens" => 10,
              "cache_read_input_tokens" => 0,
              "cache_creation_input_tokens" => 0
            }
          }
        },
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => ""}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "hello "}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "world"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 5}
        },
        %{"type" => "message_stop"}
      ]

      resp = events |> Anthropix.accumulate_stream() |> Anthropix.decode()

      assert %Response{
               stop_reason: :end_turn,
               content: [%{type: :text, text: "hello world"}],
               usage: %{
                 input_tokens: 10,
                 output_tokens: 5
               }
             } = resp
    end

    test "tool_use response reassembles partial_json deltas" do
      events = [
        %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 20}}},
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "list_tasks",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"status\":"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "\"open\"}"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{"output_tokens" => 8}
        },
        %{"type" => "message_stop"}
      ]

      resp = events |> Anthropix.accumulate_stream() |> Anthropix.decode()

      assert %Response{
               stop_reason: :tool_use,
               content: [
                 %{
                   type: :tool_use,
                   id: "toolu_1",
                   name: "list_tasks",
                   input: %{"status" => "open"}
                 }
               ]
             } = resp
    end

    test "mixed text + tool_use blocks preserved in order" do
      events = [
        %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 1}}},
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => ""}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "thinking"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "noop",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{}"}
        },
        %{"type" => "content_block_stop", "index" => 1},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{"output_tokens" => 3}
        },
        %{"type" => "message_stop"}
      ]

      resp = events |> Anthropix.accumulate_stream() |> Anthropix.decode()

      assert [
               %{type: :text, text: "thinking"},
               %{type: :tool_use, id: "t1", name: "noop", input: %{}}
             ] = resp.content

      assert resp.stop_reason == :tool_use
    end

    test "usage merges message_start input + message_delta output + cache fields" do
      events = [
        %{
          "type" => "message_start",
          "message" => %{
            "usage" => %{
              "input_tokens" => 100,
              "cache_read_input_tokens" => 50,
              "cache_creation_input_tokens" => 25,
              "service_tier" => "standard"
            }
          }
        },
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => ""}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 7}
        },
        %{"type" => "message_stop"}
      ]

      resp = events |> Anthropix.accumulate_stream() |> Anthropix.decode()

      assert resp.usage == %{
               input_tokens: 100,
               output_tokens: 7,
               cache_read_tokens: 50,
               cache_creation_tokens: 25,
               service_tier: "standard"
             }
    end

    test "retryable? on 5xx and 429" do
      assert Anthropix.retryable?(struct(APIError, %{status: 500, message: "x"}))
      assert Anthropix.retryable?(struct(APIError, %{status: 503, message: "x"}))
      assert Anthropix.retryable?(struct(APIError, %{status: 529, message: "x"}))
      assert Anthropix.retryable?(struct(APIError, %{status: 429, message: "x"}))
      refute Anthropix.retryable?(struct(APIError, %{status: 400, message: "x"}))
      refute Anthropix.retryable?(struct(APIError, %{status: 401, message: "x"}))
      refute Anthropix.retryable?(struct(APIError, %{status: 422, message: "x"}))
    end

    test "retryable? on transport errors" do
      assert Anthropix.retryable?(%RuntimeError{message: "x"} |> Map.put(:reason, :timeout))
      refute Anthropix.retryable?(%ArgumentError{message: "bad input"})
      refute Anthropix.retryable?(:something)
      refute Anthropix.retryable?(nil)
    end

    test "ignores ping and unknown events" do
      events = [
        %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 1}}},
        %{"type" => "ping"},
        %{"type" => "something_new"},
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => ""}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "ok"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 1}
        },
        %{"type" => "message_stop"}
      ]

      resp = events |> Anthropix.accumulate_stream() |> Anthropix.decode()
      assert [%{type: :text, text: "ok"}] = resp.content
    end
  end
end
