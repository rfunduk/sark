defmodule Mix.Tasks.Sark do
  @shortdoc "Run sark (config via SARK_CONFIG)"

  @moduledoc """
  Dev runner. Boots the OTP application and blocks until interrupted.

      SARK_CONFIG=config.yml mix sark

  Config resolution is identical to the release: `SARK_CONFIG` (or the
  `:sark, :config_path` app env). No CLI flags — boot fails loud if
  neither is set (see `Sark.Boot`).
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_argv) do
    {:ok, _} = Application.ensure_all_started(:sark)
    Process.sleep(:infinity)
  end
end
