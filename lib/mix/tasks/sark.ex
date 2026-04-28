defmodule Mix.Tasks.Sark do
  @shortdoc "Run sark with --config <path>"

  @moduledoc """
  Dev runner. Mirrors the release entrypoint:

      mix sark --config path/to/config.yml
      mix sark -c path/to/config.yml

  Boots the OTP application and blocks until interrupted. Same code
  path as `Sark.CLI.main/1` — releases call that directly.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    path = Sark.CLI.parse_args!(argv, &Mix.raise/1)
    Sark.CLI.boot!(path)
    Process.sleep(:infinity)
  end
end
