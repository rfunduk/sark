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

  describe "eval — operators" do
    test "equals matches when path value strictly equals" do
      rules = [rule("email", :equals, "ryan@figment.io", :all)]
      assert Rules.eval(%{"email" => "ryan@figment.io"}, rules) == :all
    end

    test "equals does not match different string" do
      rules = [rule("email", :equals, "ryan@figment.io", :all)]
      assert Rules.eval(%{"email" => "someone@else"}, rules) == :deny
    end

    test "in matches list membership" do
      rules = [rule("groups", :in, "admin", :all)]
      assert Rules.eval(%{"groups" => ["user", "admin"]}, rules) == :all
    end

    test "in against non-list value never matches" do
      rules = [rule("groups", :in, "admin", :all)]
      assert Rules.eval(%{"groups" => "admin"}, rules) == :deny
    end

    test "suffix matches string ending" do
      rules = [rule("email", :suffix, "@figment.io", :all)]
      assert Rules.eval(%{"email" => "ryan@figment.io"}, rules) == :all
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
      rules = [rule("realm_access.roles", :in, "reader", :all)]
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
        rule("groups", :in, "support", %{"ticketing" => :all})
      ]

      assert Rules.eval(%{"email" => "x", "groups" => ["support"]}, rules) ==
               %{"openfig" => :all, "ticketing" => :all}
    end

    test ":all absorbs map in union" do
      rules = [
        rule("email", :equals, "x", %{"openfig" => :all}),
        rule("groups", :in, "admin", :all)
      ]

      assert Rules.eval(%{"email" => "x", "groups" => ["admin"]}, rules) == :all
    end

    test "same plugin in two rules: :all wins over pattern list" do
      {:ok, re} = Regex.compile("read_.*")

      rules = [
        rule("a", :equals, 1, %{"kv" => [re]}),
        rule("b", :equals, 2, %{"kv" => :all})
      ]

      assert Rules.eval(%{"a" => 1, "b" => 2}, rules) == %{"kv" => :all}
    end

    test "same plugin in two rules: pattern lists concatenate" do
      {:ok, ra} = Regex.compile("read_.*")
      {:ok, rb} = Regex.compile("list_.*")

      rules = [
        rule("a", :equals, 1, %{"kv" => [ra]}),
        rule("b", :equals, 2, %{"kv" => [rb]})
      ]

      assert %{"kv" => patterns} = Rules.eval(%{"a" => 1, "b" => 2}, rules)
      assert length(patterns) == 2
    end

    test "order does not matter — additivity holds either way" do
      rules_a = [
        rule("groups", :in, "admin", :all),
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

  describe "eval — claim shapes" do
    test "nil claims with no default-allow rule → :deny" do
      assert Rules.eval(nil, [rule("email", :equals, "x", :all)]) == :deny
    end
  end
end
