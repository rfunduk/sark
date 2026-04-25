defmodule Sark.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    if Application.get_env(:sark, :auto_start, true) do
      start_supervised(Sark.Boot.load_config!())
    else
      Supervisor.start_link([], strategy: :one_for_one, name: Sark.Supervisor)
    end
  end

  defp start_supervised(%Sark.Config{} = config) do
    configure_logger(config)

    {ip, port} = config.listen

    children = [
      {Sark.AuthRegistry, config.tokens},
      {Sark.PluginSupervisor, [plugin_paths: config.plugin_paths, data_dir: config.data_dir]},
      {Plug.Cowboy, scheme: :http, plug: Sark.Endpoint, options: [ip: ip, port: port]}
    ]

    Logger.info(
      "sark starting — listen=#{:inet.ntoa(ip)}:#{port} " <>
        "tokens=#{map_size(config.tokens)} " <>
        "plugins=#{length(config.plugin_paths)} " <>
        "data_dir=#{config.data_dir}"
    )

    Supervisor.start_link(children, strategy: :one_for_one, name: Sark.Supervisor)
  end

  defp configure_logger(%Sark.Config{log_level: level}) do
    Logger.configure(level: level)
  end
end
