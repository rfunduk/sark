defmodule Sark.AuthRegistryTest do
  use ExUnit.Case, async: true

  alias Sark.AuthRegistry

  describe "authorized?/2" do
    test "`:all` entry passes every plugin" do
      entry = %{name: "t", allowed: :all}
      assert AuthRegistry.authorized?(entry, "kv")
      assert AuthRegistry.authorized?(entry, "kb")
    end

    test "map entry — plugin key present = authorized" do
      entry = %{name: "t", allowed: %{"kv" => :all}}
      assert AuthRegistry.authorized?(entry, "kv")
      refute AuthRegistry.authorized?(entry, "kb")
    end

    test "map entry with pattern list still authorizes the plugin" do
      entry = %{name: "t", allowed: %{"kv" => [~r/\Aread_.*\z/]}}
      assert AuthRegistry.authorized?(entry, "kv")
    end
  end

  describe "tool_allowlist/3" do
    test "`:all` entry → `:all` (no filter)" do
      assert AuthRegistry.tool_allowlist(%{allowed: :all}, "kv", ["a", "b"]) == :all
    end

    test "plugin → `:all` → `:all`" do
      entry = %{allowed: %{"kv" => :all}}
      assert AuthRegistry.tool_allowlist(entry, "kv", ["a", "b"]) == :all
    end

    test "plugin not present → empty list (deny all)" do
      entry = %{allowed: %{"kv" => :all}}
      assert AuthRegistry.tool_allowlist(entry, "kb", ["a", "b"]) == []
    end

    test "patterns filter the candidate list" do
      entry = %{allowed: %{"kv" => [~r/\Aread_.*\z/]}}

      assert AuthRegistry.tool_allowlist(entry, "kv", [
               "read_one",
               "read_two",
               "write_one"
             ]) == ["read_one", "read_two"]
    end

    test "multiple patterns union" do
      entry = %{allowed: %{"kv" => [~r/\Aread_.*\z/, ~r/\Asark_catalog\z/]}}

      result =
        AuthRegistry.tool_allowlist(entry, "kv", [
          "read_one",
          "sark_catalog",
          "sark_sql",
          "write_one"
        ])

      assert Enum.sort(result) == ["read_one", "sark_catalog"]
    end

    test "patterns are order-preserving filter of candidates" do
      entry = %{allowed: %{"kv" => [~r/.*/]}}

      assert AuthRegistry.tool_allowlist(entry, "kv", ["c", "a", "b"]) == ["c", "a", "b"]
    end
  end
end
