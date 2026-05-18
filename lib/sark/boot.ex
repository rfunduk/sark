defmodule Sark.Boot do
  @moduledoc """
  Resolves the active `Sark.Config` at boot.
  """

  @spec load_config!() :: Sark.Config.t()
  def load_config! do
    path =
      System.get_env("SARK_CONFIG") ||
        raise "Sark: no config found. Provide `SARK_CONFIG=/path/to/config.yml`"

    Sark.Config.load!(path)
  end
end
