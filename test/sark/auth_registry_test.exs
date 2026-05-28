defmodule Sark.AuthRegistryTest do
  use ExUnit.Case, async: true

  alias Sark.AuthRegistry

  defp block(pos, neg \\ []) do
    pos_res = Enum.map(pos, fn s -> Regex.compile!("\\A" <> regex_of(s) <> "\\z") end)
    neg_res = Enum.map(neg, fn s -> Regex.compile!("\\A" <> regex_of(s) <> "\\z") end)
    %{pos: pos_res, neg: neg_res}
  end

  defp regex_of(s) do
    s
    |> String.graphemes()
    |> Enum.map_join(fn
      "%" -> ".*"
      c -> Regex.escape(c)
    end)
  end

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

    test "map entry with block list still authorizes the plugin" do
      entry = %{name: "t", allowed: %{"kv" => [block(["read_%"])]}}
      assert AuthRegistry.authorized?(entry, "kv")
    end
  end

  describe "tool_allowlist/3 — positive only" do
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

    test "single block with one positive filters candidates" do
      entry = %{allowed: %{"kv" => [block(["read_%"])]}}

      assert AuthRegistry.tool_allowlist(entry, "kv", ["read_one", "read_two", "write_one"]) ==
               ["read_one", "read_two"]
    end

    test "multiple positives within block (union)" do
      entry = %{allowed: %{"kv" => [block(["read_%", "list_%"])]}}

      result =
        AuthRegistry.tool_allowlist(entry, "kv", ["read_a", "list_b", "write_c"])

      assert Enum.sort(result) == ["list_b", "read_a"]
    end

    test "filter preserves candidate order" do
      entry = %{allowed: %{"kv" => [block(["%"])]}}
      assert AuthRegistry.tool_allowlist(entry, "kv", ["c", "a", "b"]) == ["c", "a", "b"]
    end
  end

  describe "tool_allowlist/3 — negation within a single block" do
    test "ALL minus one tool" do
      entry = %{allowed: %{"kv" => [block(["%"], ["read_secret"])]}}

      assert AuthRegistry.tool_allowlist(entry, "kv", ["read_secret", "read_other", "bump"]) ==
               ["read_other", "bump"]
    end

    test "glob positive minus glob negative" do
      entry = %{allowed: %{"kv" => [block(["read_%"], ["%_audit"])]}}

      assert AuthRegistry.tool_allowlist(entry, "kv", [
               "read_secret",
               "read_audit",
               "read_audit_log",
               "write_audit"
             ]) == ["read_secret", "read_audit_log"]
    end

    test "negation-only block (empty pos) yields empty effective set" do
      entry = %{allowed: %{"kv" => [block([], ["foo"])]}}
      assert AuthRegistry.tool_allowlist(entry, "kv", ["foo", "bar"]) == []
    end

    test "ALL ∩ NOT ALL = empty" do
      entry = %{allowed: %{"kv" => [block(["%"], ["%"])]}}
      assert AuthRegistry.tool_allowlist(entry, "kv", ["foo", "bar"]) == []
    end
  end

  describe "tool_allowlist/3 — cross-block union (rules / multi-entry semantics)" do
    test "two positive blocks union — names from either pass" do
      entry = %{
        allowed: %{"kv" => [block(["read_%"]), block(["bump"])]}
      }

      result =
        AuthRegistry.tool_allowlist(entry, "kv", ["read_a", "bump", "write_x"])

      assert Enum.sort(result) == ["bump", "read_a"]
    end

    test "block A grants name X, block B negates X — X still present via A (cross-block non-interference)" do
      entry = %{
        allowed: %{
          "kv" => [
            block(["read_%"]),
            block(["%"], ["read_secret"])
          ]
        }
      }

      # Block B alone would exclude read_secret, but block A grants it directly.
      # Union of resolved name sets includes it.
      result =
        AuthRegistry.tool_allowlist(entry, "kv", ["read_secret", "bump", "other"])

      assert "read_secret" in result
      assert "bump" in result
      assert "other" in result
    end

    test "negation only in one block doesn't suppress other-block positive" do
      entry = %{
        allowed: %{
          "kv" => [
            block(["bump"]),
            block(["%"], ["bump"])
          ]
        }
      }

      result = AuthRegistry.tool_allowlist(entry, "kv", ["bump", "other"])
      # Block A grants `bump` directly; block B excludes it but grants everything else.
      # Union: both names present.
      assert Enum.sort(result) == ["bump", "other"]
    end
  end
end
