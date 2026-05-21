defmodule Sark.Pipeline.Template do
  @moduledoc """
  Mustache-render a pipeline `llm:` prompt against parsed-JSON stdin.

  Context mapping:

    * `nil` or `%{}` → empty context (variables expand to "")
    * a string-keyed map → bound directly. `{{key}}` for scalars;
      `{{#nested}}…{{/nested}}` for nested objects/arrays.
    * a list (JSON array on stdin) → bound as `{{#results}}…{{/results}}`
      to mirror the rendering shape used by tools that return rows.

  bbmustache with binary key lookup; numbers / booleans get the
  library's default rendering.
  """

  @spec render(String.t(), term) :: String.t()
  def render(template, nil), do: render(template, %{})

  def render(template, ctx) when is_binary(template) do
    :bbmustache.render(template, context(ctx), key_type: :binary)
  end

  defp context(%{} = m), do: m
  defp context(list) when is_list(list), do: %{"results" => list}
  defp context(other), do: %{"value" => other}
end
