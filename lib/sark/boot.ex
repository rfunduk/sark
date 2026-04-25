defmodule Sark.Boot do
  @moduledoc """
  Resolves the active `Sark.Config` at boot.

  Lookup order:
    1. value cached in `:persistent_term` under `{Sark, :config}`
       (set by `Sark.CLI.main/1` for releases / explicit boots)
    2. application env `:sark, :config_path`
    3. env var `SARK_CONFIG`

  The CLI path puts the parsed struct in persistent_term so the path is
  parsed exactly once. The other two fall through to a fresh `load!/1`.
  """

  @key {Sark, :config}

  @spec put(Sark.Config.t()) :: :ok
  def put(%Sark.Config{} = c), do: :persistent_term.put(@key, c)

  @spec load_config!() :: Sark.Config.t()
  def load_config! do
    case :persistent_term.get(@key, :unset) do
      %Sark.Config{} = c ->
        c

      :unset ->
        path =
          Application.get_env(:sark, :config_path) ||
            System.get_env("SARK_CONFIG") ||
            raise """
            sark: no config found.

            Provide one of:
              * launch via `sark --config path/to/config.yml`
              * set `:sark, :config_path` in app env (config/*.exs)
              * export `SARK_CONFIG=/path/to/config.yml`
            """

        Sark.Config.load!(path)
    end
  end
end
