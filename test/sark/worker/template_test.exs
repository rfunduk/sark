defmodule Sark.Worker.TemplateTest do
  use ExUnit.Case, async: true

  alias Sark.Worker.Template

  test "empty rows render with empty context" do
    assert Template.render("x={{n}}", []) == "x="
  end

  test "single row binds columns as scalars" do
    assert Template.render("count={{n}}", [%{"n" => 7}]) == "count=7"
  end

  test "single row's list column iterates with #section" do
    rows = [%{"items" => [%{"k" => "a"}, %{"k" => "b"}]}]
    assert Template.render("{{#items}}-{{k}}\n{{/items}}", rows) == "-a\n-b\n"
  end

  test "multi-row binds under {{#results}}" do
    rows = [%{"k" => "a"}, %{"k" => "b"}]
    assert Template.render("{{#results}}-{{k}}\n{{/results}}", rows) == "-a\n-b\n"
  end
end
