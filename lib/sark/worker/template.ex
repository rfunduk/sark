defmodule Sark.Worker.Template do
  @moduledoc """
  Render a worker `prompt:` against the rows returned by `load:`.

  Binding rules:

    * `[]`        → empty context (variables expand to "")
    * `[row]`     → row map is the context. `{{col}}` for scalars;
                    `{{#col}}…{{/col}}` for JSON aggregate columns
                    (auto-decoded to lists by `Sark.Plugin.DB`)
    * `[_, _ | _]` → `%{"results" => rows}` so the template can iterate
                     `{{#results}}…{{/results}}`

  Mustache via `:bbmustache` with binary key lookup.
  """

  @spec render(String.t(), [map]) :: String.t()
  def render(template, rows) when is_binary(template) and is_list(rows) do
    :bbmustache.render(template, context(rows), key_type: :binary)
  end

  defp context([]), do: %{}
  defp context([row]) when is_map(row), do: row
  defp context(rows), do: %{"results" => rows}
end
