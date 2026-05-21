defmodule Sark.Pipeline.TemplateTest do
  use ExUnit.Case, async: true

  alias Sark.Pipeline.Template

  test "nil context expands variables to empty string" do
    assert Template.render("hello {{name}}!", nil) == "hello !"
  end

  test "empty map context expands variables to empty string" do
    assert Template.render("hello {{name}}!", %{}) == "hello !"
  end

  test "string-keyed map binds scalars" do
    assert Template.render("hello {{name}}", %{"name" => "Ryan"}) == "hello Ryan"
  end

  test "nested map iterated with mustache section" do
    out =
      Template.render(
        "items:\n{{#items}}- {{n}}\n{{/items}}",
        %{"items" => [%{"n" => 1}, %{"n" => 2}]}
      )

    assert out == "items:\n- 1\n- 2\n"
  end

  test "JSON-array stdin bound under {{#results}}" do
    out =
      Template.render(
        "{{#results}}- {{x}}\n{{/results}}",
        [%{"x" => "a"}, %{"x" => "b"}]
      )

    assert out == "- a\n- b\n"
  end
end
