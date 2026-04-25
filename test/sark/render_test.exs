defmodule Sark.RenderTest do
  use ExUnit.Case, async: true

  alias Sark.Render

  describe ":json" do
    test "encodes scalar" do
      assert Render.render(42, :json, :scalar) =~ "42"
    end

    test "encodes rows" do
      out = Render.render([%{"a" => 1}], :json, :rows)
      assert out =~ "\"a\""
      assert out =~ "1"
    end
  end

  describe ":table" do
    test "renders header + sep + body for rows" do
      out = Render.render([%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => "y"}], :table, :rows)
      assert out =~ "| a | b |"
      assert out =~ "| --- | --- |"
      assert out =~ "| 1 | x |"
      assert out =~ "| 2 | y |"
    end

    test "(no rows) for empty" do
      assert Render.render([], :table, :rows) == "(no rows)"
    end

    test "wraps single row" do
      out = Render.render(%{"a" => 1}, :table, :one_row)
      assert out =~ "| a |"
      assert out =~ "| 1 |"
    end
  end

  describe ":list" do
    test "rows render as bullet blocks" do
      out = Render.render([%{"a" => 1, "b" => "x"}, %{"a" => 2, "b" => "y"}], :list, :rows)
      assert out =~ "- a: 1"
      assert out =~ "  b: x"
      assert out =~ "- a: 2"
    end

    test "one_row renders without bullet" do
      out = Render.render(%{"a" => 1}, :list, :one_row)
      assert out == "a: 1"
    end

    test "maybe_row nil → (no row)" do
      assert Render.render(nil, :list, :maybe_row) == "(no row)"
    end

    test "empty rows → (no rows)" do
      assert Render.render([], :list, :rows) == "(no rows)"
    end
  end

  describe "{:template, ...}" do
    test "{{var}} substitution on one_row" do
      out = Render.render(%{"name" => "Ryan"}, {:template, "Hi {{name}}"}, :one_row)
      assert out == "Hi Ryan"
    end

    test "{{#rows}}…{{/rows}} iteration" do
      tpl = "{{#rows}}- {{name}}\n{{/rows}}"
      out = Render.render([%{"name" => "a"}, %{"name" => "b"}], {:template, tpl}, :rows)
      assert out == "- a\n- b\n"
    end

    test "missing var renders as empty" do
      out = Render.render(%{}, {:template, "[{{missing}}]"}, :one_row)
      assert out == "[]"
    end
  end

  describe "default_format/2 (via Query)" do
    test "matches the spec rule matrix" do
      alias Sark.Plugin.Query
      assert Query.default_format(:rows, false) == :list
      assert Query.default_format(:one_row, false) == :list
      assert Query.default_format(:maybe_row, false) == :list
      assert Query.default_format(:scalar, false) == :json
      assert Query.default_format(:count, false) == :json
      assert Query.default_format(:none, false) == :json
      assert Query.default_format(:rows, true) == :json
    end
  end
end
