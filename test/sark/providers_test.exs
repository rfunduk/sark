defmodule Sark.ProvidersTest do
  use ExUnit.Case, async: true

  alias Sark.Providers

  test "parse/1 nil yields empty providers" do
    assert %Providers{entries: %{}} = Providers.parse(nil)
  end

  test "parse/1 empty map yields empty providers" do
    assert %Providers{entries: %{}} = Providers.parse(%{})
  end

  test "parse/1 preserves provider settings as maps" do
    raw = %{
      "anthropic" => %{"api_key" => "sk-x"},
      "ollama" => %{"url" => "http://localhost:11434"}
    }

    %Providers{entries: entries} = Providers.parse(raw)

    assert entries["anthropic"] == %{"api_key" => "sk-x"}
    assert entries["ollama"] == %{"url" => "http://localhost:11434"}
  end

  test "parse/1 treats null provider value as empty settings (bumblebee-style)" do
    %Providers{entries: entries} = Providers.parse(%{"bumblebee" => nil})
    assert entries["bumblebee"] == %{}
  end

  test "parse/1 raises on non-map provider value" do
    assert_raise RuntimeError, ~r/providers\.anthropic must be a map/, fn ->
      Providers.parse(%{"anthropic" => "sk-x"})
    end
  end

  test "parse/1 raises on non-map top level" do
    assert_raise RuntimeError, ~r/providers must be a map/, fn ->
      Providers.parse([1, 2, 3])
    end
  end

  test "fetch!/2 returns settings or raises" do
    p = Providers.parse(%{"anthropic" => %{"api_key" => "k"}})
    assert Providers.fetch!(p, "anthropic") == %{"api_key" => "k"}

    assert_raise RuntimeError, ~r/providers\.ollama not configured/, fn ->
      Providers.fetch!(p, "ollama")
    end
  end

  test "get/2 returns nil when absent" do
    p = Providers.parse(%{"anthropic" => %{}})
    assert Providers.get(p, "anthropic") == %{}
    assert Providers.get(p, "ollama") == nil
  end

  test "names/1 lists configured providers" do
    p = Providers.parse(%{"anthropic" => %{}, "ollama" => %{}})
    assert Enum.sort(Providers.names(p)) == ["anthropic", "ollama"]
  end
end
