defmodule Sark.CLI do
  @moduledoc """
  Release entrypoint. Parses `--config` and stashes the parsed
  config before the OTP application starts.

  Used by the release boot script. In dev, prefer `iex -S mix` with
  `SARK_CONFIG` env var set.
  """

  def main(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [config: :string],
        aliases: [c: :config]
      )

    case Keyword.get(opts, :config) do
      nil ->
        IO.puts(:stderr, "sark: --config <path> required")
        System.halt(2)

      path ->
        config = Sark.Config.load!(path)
        Sark.Boot.put(config)
        Application.ensure_all_started(:sark)
        Process.sleep(:infinity)
    end
  end
end
