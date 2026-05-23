defmodule Sark.EmbedderTest do
  use ExUnit.Case, async: true

  alias Sark.Embedder.Config

  describe "Config.parse/1" do
    test "nil returns nil (embedder optional)" do
      assert Config.parse(nil) == nil
    end

    test "parses minimal embedder block" do
      raw = %{
        "provider" => "ollama",
        "model" => "nomic-embed-text",
        "dim" => 768
      }

      assert %Config{
               provider: "ollama",
               model: "nomic-embed-text",
               dim: 768,
               defaults: %{chunk: %{size: 1024, overlap: 128}}
             } = Config.parse(raw)
    end

    test "parses custom chunk defaults" do
      raw = %{
        "provider" => "ollama",
        "model" => "nomic-embed-text",
        "dim" => 768,
        "defaults" => %{"chunk" => %{"size" => 512, "overlap" => 64}}
      }

      assert %Config{defaults: %{chunk: %{size: 512, overlap: 64}}} = Config.parse(raw)
    end

    test "rejects missing provider" do
      raw = %{"model" => "m", "dim" => 768}

      assert_raise RuntimeError, ~r/embedder\.provider must be non-empty string/, fn ->
        Config.parse(raw)
      end
    end

    test "rejects non-positive dim" do
      raw = %{"provider" => "ollama", "model" => "m", "dim" => 0}

      assert_raise RuntimeError, ~r/embedder\.dim must be positive integer/, fn ->
        Config.parse(raw)
      end
    end

    test "rejects overlap >= size" do
      raw = %{
        "provider" => "ollama",
        "model" => "m",
        "dim" => 768,
        "defaults" => %{"chunk" => %{"size" => 128, "overlap" => 128}}
      }

      assert_raise RuntimeError, ~r/overlap must be < size/, fn ->
        Config.parse(raw)
      end
    end

    test "rejects non-map embedder" do
      assert_raise RuntimeError, ~r/embedder must be a map/, fn ->
        Config.parse("ollama")
      end
    end
  end

  describe "adapter_for!/1" do
    test "ollama → Sark.Embedder.Ollama" do
      assert Sark.Embedder.adapter_for!("ollama") == Sark.Embedder.Ollama
    end

    test "unknown provider raises" do
      assert_raise RuntimeError, ~r/not supported yet/, fn ->
        Sark.Embedder.adapter_for!("voyage")
      end
    end
  end
end
