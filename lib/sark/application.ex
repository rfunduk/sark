defmodule Sark.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    if Application.get_env(:sark, :auto_start, true) do
      start_supervised(Sark.Boot.load_config!())
    else
      Supervisor.start_link(base_children(), strategy: :one_for_one, name: Sark.Supervisor)
    end
  end

  defp start_supervised(%Sark.Config{} = config) do
    configure_logger(config)

    # Externally-visible base URL. Read by `Sark.URL.base/1` at request
    # time when building metadata + challenge URLs. nil → derive from
    # the incoming conn.
    Application.put_env(:sark, :url, config.url)

    # OAuth IdP. Read by `Sark.AuthPlug` (JWT verify path) and
    # `Sark.Endpoint` (protected-resource metadata advertisement).
    # nil → bearer-only deployment.
    Application.put_env(:sark, :idp, config.idp)

    # `auth: none` — Sark.AuthPlug skips authentication entirely and
    # synthesizes an anonymous identity envelope.
    Application.put_env(:sark, :auth_none, config.auth_none)

    {ip, port} = config.listen

    children =
      base_children() ++
        idp_children(config.idp) ++
        [
          {Sark.AuthRegistry, config.tokens},
          {Sark.PluginSupervisor,
           [
             plugins: config.plugins,
             data_dir: config.data_dir
           ]},
          {Plug.Cowboy, scheme: :http, plug: Sark.Endpoint, options: [ip: ip, port: port]}
        ]

    auth_summary =
      if config.auth_none, do: "auth=none ", else: "tokens=#{map_size(config.tokens)} "

    Logger.info(
      "sark starting — listen=#{:inet.ntoa(ip)}:#{port} " <>
        auth_summary <>
        "plugins=#{map_size(config.plugins)} " <>
        "data_dir=#{config.data_dir}"
    )

    Supervisor.start_link(children, strategy: :one_for_one, name: Sark.Supervisor)
  end

  defp idp_children(nil), do: []

  defp idp_children(%Sark.Config.IdP{} = idp) do
    [
      {Sark.Auth.KeyStore, idp},
      Sark.OAuth.Correlator
    ]
  end

  defp base_children do
    [
      {Phoenix.PubSub, name: Sark.PubSub},
      {Phantom.Tracker, [name: Phantom.Tracker, pubsub_server: Sark.PubSub]},
      {Task.Supervisor, name: Sark.Pipeline.TaskSup},
      Sark.Pipeline.Lock,
      Sark.Pipeline.Cancel
    ]
  end

  defp configure_logger(%Sark.Config{log_level: level}) do
    Logger.configure(level: level)
  end
end
