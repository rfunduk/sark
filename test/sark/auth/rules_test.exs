defmodule Sark.Auth.RulesTest do
  use ExUnit.Case, async: true

  alias Sark.Auth.Rules

  defp rule(path, op, value, plugins) do
    %{
      match: %{path: String.split(path, "."), op: op, value: value},
      plugins: plugins
    }
  end

  defp open_rule(plugins), do: %{match: nil, plugins: plugins}

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

  describe "eval — operators" do
    test "equals matches when path value strictly equals" do
      rules = [rule("email", :equals, "ryan@example.com", :all)]
      assert Rules.eval(%{"email" => "ryan@example.com"}, rules) == :all
    end

    test "equals does not match different string" do
      rules = [rule("email", :equals, "ryan@example.com", :all)]
      assert Rules.eval(%{"email" => "someone@else"}, rules) == :deny
    end

    test "in: scalar claim ∈ config list" do
      rules = [rule("role", :in, ["owner", "admin"], :all)]
      assert Rules.eval(%{"role" => "admin"}, rules) == :all
    end

    test "in: scalar claim not in list → deny" do
      rules = [rule("role", :in, ["owner", "admin"], :all)]
      assert Rules.eval(%{"role" => "viewer"}, rules) == :deny
    end

    test "in: against list claim never matches (use contains)" do
      rules = [rule("groups", :in, ["admin"], :all)]
      assert Rules.eval(%{"groups" => ["admin"]}, rules) == :deny
    end

    test "in: against nil claim never matches" do
      rules = [rule("role", :in, ["owner"], :all)]
      assert Rules.eval(%{}, rules) == :deny
    end

    test "in: matches numbers + booleans" do
      r1 = [rule("level", :in, [1, 2, 3], :all)]
      assert Rules.eval(%{"level" => 2}, r1) == :all

      r2 = [rule("flag", :in, [true], :all)]
      assert Rules.eval(%{"flag" => true}, r2) == :all
    end

    test "contains: config scalar ∈ claim list" do
      rules = [rule("groups", :contains, "admin", :all)]
      assert Rules.eval(%{"groups" => ["user", "admin"]}, rules) == :all
    end

    test "contains: scalar not in claim list → deny" do
      rules = [rule("groups", :contains, "admin", :all)]
      assert Rules.eval(%{"groups" => ["user"]}, rules) == :deny
    end

    test "contains: against non-list claim never matches" do
      rules = [rule("groups", :contains, "admin", :all)]
      assert Rules.eval(%{"groups" => "admin"}, rules) == :deny
    end

    test "suffix matches string ending" do
      rules = [rule("email", :suffix, "@example.com", :all)]
      assert Rules.eval(%{"email" => "ryan@example.com"}, rules) == :all
    end

    test "suffix against non-string never matches" do
      rules = [rule("groups", :suffix, "admin", :all)]
      assert Rules.eval(%{"groups" => ["admin"]}, rules) == :deny
    end

    test "exists matches any non-null value" do
      rules = [rule("sub", :exists, true, :all)]
      assert Rules.eval(%{"sub" => "abc"}, rules) == :all
    end

    test "exists does not match missing claim" do
      rules = [rule("sub", :exists, true, :all)]
      assert Rules.eval(%{}, rules) == :deny
    end

    test "nested path resolves through dotted segments" do
      rules = [rule("realm_access.roles", :contains, "reader", :all)]
      assert Rules.eval(%{"realm_access" => %{"roles" => ["reader"]}}, rules) == :all
    end
  end

  describe "eval — additivity" do
    test "zero matches → :deny" do
      assert Rules.eval(%{"foo" => "bar"}, [rule("email", :equals, "x", :all)]) == :deny
    end

    test "single match returns that rule's plugins" do
      rules = [rule("email", :equals, "x", %{"openfig" => :all})]
      assert Rules.eval(%{"email" => "x"}, rules) == %{"openfig" => :all}
    end

    test "two matches union plugin keys" do
      rules = [
        rule("email", :equals, "x", %{"openfig" => :all}),
        rule("groups", :contains, "support", %{"ticketing" => :all})
      ]

      assert Rules.eval(%{"email" => "x", "groups" => ["support"]}, rules) ==
               %{"openfig" => :all, "ticketing" => :all}
    end

    test ":all absorbs map in union" do
      rules = [
        rule("email", :equals, "x", %{"openfig" => :all}),
        rule("groups", :contains, "admin", :all)
      ]

      assert Rules.eval(%{"email" => "x", "groups" => ["admin"]}, rules) == :all
    end

    test "same plugin in two rules: :all wins over block list" do
      rules = [
        rule("a", :equals, 1, %{"kv" => [block(["read_%"])]}),
        rule("b", :equals, 2, %{"kv" => :all})
      ]

      assert Rules.eval(%{"a" => 1, "b" => 2}, rules) == %{"kv" => :all}
    end

    test "same plugin in two rules: block lists concatenate" do
      rules = [
        rule("a", :equals, 1, %{"kv" => [block(["read_%"])]}),
        rule("b", :equals, 2, %{"kv" => [block(["list_%"])]})
      ]

      assert %{"kv" => blocks} = Rules.eval(%{"a" => 1, "b" => 2}, rules)
      assert length(blocks) == 2
    end

    test "order does not matter — additivity holds either way" do
      rules_a = [
        rule("groups", :contains, "admin", :all),
        rule("email", :equals, "ryan", %{"openfig" => :all})
      ]

      rules_b = Enum.reverse(rules_a)
      claims = %{"groups" => ["admin"], "email" => "ryan"}

      assert Rules.eval(claims, rules_a) == Rules.eval(claims, rules_b)
    end

    test "match=nil rule is unconditional default-allow" do
      assert Rules.eval(%{}, [open_rule(:all)]) == :all
    end
  end

  describe "eval — cross-rule negation non-interference" do
    # End-to-end: rules union into block list, then `Sark.AuthRegistry.tool_allowlist`
    # resolves names. Rule B's negation must not suppress rule A's positive.
    test "rule A grants read_%, rule B grants ALL minus read_secret → read_secret stays granted via A" do
      rules = [
        rule("a", :equals, 1, %{"kv" => [block(["read_%"])]}),
        rule("b", :equals, 2, %{"kv" => [block(["%"], ["read_secret"])]})
      ]

      merged = Rules.eval(%{"a" => 1, "b" => 2}, rules)
      assert %{"kv" => blocks} = merged
      assert length(blocks) == 2

      entry = %{name: "test", allowed: merged}

      result =
        Sark.AuthRegistry.tool_allowlist(entry, "kv", [
          "read_secret",
          "read_other",
          "bump",
          "write_x"
        ])

      # read_secret: granted via A (read_%), even though B negates it.
      # read_other: granted via A and B.
      # bump, write_x: granted via B only (A doesn't cover).
      assert "read_secret" in result
      assert "read_other" in result
      assert "bump" in result
      assert "write_x" in result
    end

    test "single-rule negation IS effective (intra-block neg applies)" do
      rules = [
        rule("a", :equals, 1, %{"kv" => [block(["%"], ["read_secret"])]})
      ]

      merged = Rules.eval(%{"a" => 1}, rules)
      entry = %{name: "test", allowed: merged}

      result = Sark.AuthRegistry.tool_allowlist(entry, "kv", ["read_secret", "bump"])
      assert result == ["bump"]
    end
  end

  describe "eval — claim shapes" do
    test "nil claims with no default-allow rule → :deny" do
      assert Rules.eval(nil, [rule("email", :equals, "x", :all)]) == :deny
    end
  end
end
