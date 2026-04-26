defmodule Sark.RenderTest do
  use ExUnit.Case, async: true

  alias Sark.Render

  describe ":json" do
    test "encodes scalar" do
      assert Render.render(42, :json, :scalar) =~ "42"
    end

    test "encodes results" do
      out = Render.render([%{"a" => 1}], :json, :results)
      assert out =~ "\"a\""
      assert out =~ "1"
    end
  end

  describe ":table" do
    test "renders header + sep + body for results" do
      out = Render.render([%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => "y"}], :table, :results)
      assert out =~ "| a | b |"
      assert out =~ "| --- | --- |"
      assert out =~ "| 1 | x |"
      assert out =~ "| 2 | y |"
    end

    test "(no results) for empty" do
      assert Render.render([], :table, :results) == "(no results)"
    end

    test "honours explicit column order, ignoring map iteration" do
      rows = [%{"z" => 1, "a" => 2, "m" => 3}]
      out = Render.render(rows, :table, :results, ["z", "a", "m"])
      assert out =~ "| z | a | m |"
      assert out =~ "| 1 | 2 | 3 |"
    end
  end

  describe ":list" do
    test "multi-row results render as bullet blocks" do
      out = Render.render([%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => "y"}], :list, :results)
      assert out =~ "- a: 1"
      assert out =~ "  b: x"
      assert out =~ "- a: 2"
    end

    test "single-row results render without bullet" do
      out = Render.render([%{"a" => 1}], :list, :results)
      assert out == "a: 1"
    end

    test "empty results → (no results)" do
      assert Render.render([], :list, :results) == "(no results)"
    end

    test "honours explicit column order across rows" do
      rows = [%{"z" => 1, "a" => 2}, %{"z" => 3, "a" => 4}]
      out = Render.render(rows, :list, :results, ["z", "a"])
      assert out == "- z: 1\n  a: 2\n\n- z: 3\n  a: 4"
    end

    test "honours explicit column order on single-row results" do
      out = Render.render([%{"z" => 1, "a" => 2}], :list, :results, ["z", "a"])
      assert out == "z: 1\na: 2"
    end

    test "renders nested map/list values as JSON, not Elixir inspect" do
      rows = [%{"name" => "Garage", "equipment" => [%{"category" => "barbell"}]}]
      out = Render.render(rows, :list, :results, ["name", "equipment"])
      assert out =~ "name: Garage"
      assert out =~ ~s(equipment: [{"category":"barbell"}])
      refute out =~ "%{"
      refute out =~ "=>"
    end
  end

  describe "{:template, ...}" do
    test "{{#results}}…{{/results}} iteration" do
      tpl = "{{#results}}- {{name}}\n{{/results}}"
      out = Render.render([%{"name" => "a"}, %{"name" => "b"}], {:template, tpl}, :results)
      assert out == "- a\n- b\n"
    end

    test "single result still iterates once" do
      tpl = "{{#results}}Hi {{name}}{{/results}}"
      out = Render.render([%{"name" => "Ryan"}], {:template, tpl}, :results)
      assert out == "Hi Ryan"
    end

    test "empty results renders empty body" do
      tpl = "before {{#results}}x{{/results}} after"
      out = Render.render([], {:template, tpl}, :results)
      assert out == "before  after"
    end
  end

  describe "default_format/2 (via Query)" do
    test "matches the spec rule matrix" do
      alias Sark.Plugin.Query
      assert Query.default_format(:results, false) == :list
      assert Query.default_format(:scalar, false) == :json
      assert Query.default_format(:count, false) == :json
      assert Query.default_format(:none, false) == :json
      assert Query.default_format(:results, true) == :json
    end
  end
end
