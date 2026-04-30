defmodule Sark.Config do
  @moduledoc """
  Loads and validates `config.yml`.

  Shape:

      listen: 127.0.0.1:8080
      data_dir: /var/sark/data
      log_level: info                # optional
      anthropic_api_key: "${ANTHROPIC_API_KEY}"  # optional, ${VAR} interpolated
      tokens:
        - { name: ryan, plugins: ["*"], token: sk-ryan }
        - { name: wife, plugins: [jot], token: sk-wife }
      plugins:
        jean: ~/code/sark-jean
        jot:  ~/code/sark-jot
        kv:   test/fixtures/plugins/kv

  `tokens[*].plugins` is either `["*"]` (wildcard — all plugins) or a list
  of plugin names. Reachability check happens in `Sark.AuthPlug` against
  the URL path `/<plugin>/mcp`.

  `plugins` is a map: name (used everywhere — tool routing, DB filename,
  pool registry) → directory path. Decoupling the name from the on-disk
  basename keeps tokens stable across plugin dir renames.
  """

  defstruct [
    :listen,
    :data_dir,
    :log_level,
    :anthropic_api_key,
    :tokens,
    :plugins,
    :hot_reload,
    :source_path
  ]

  @type listen :: {:inet.ip_address(), :inet.port_number()}
  @type allowed :: :all | MapSet.t(String.t())
  @type token_entry :: %{name: String.t(), allowed: allowed()}
  @type t :: %__MODULE__{
          listen: listen(),
          data_dir: String.t(),
          log_level: atom(),
          anthropic_api_key: String.t() | nil,
          tokens: %{String.t() => token_entry()},
          plugins: %{String.t() => String.t()},
          hot_reload: boolean(),
          source_path: String.t()
        }

  @env_var_re ~r/\$\{([A-Z_][A-Z0-9_]*)\}/
  @plugin_name_re ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @spec load!(Path.t()) :: t()
  def load!(path) do
    abs = Path.expand(path)

    raw =
      case YamlElixir.read_from_file(abs) do
        {:ok, map} when is_map(map) -> map
        {:ok, _} -> raise "config #{abs}: top-level must be a map"
        {:error, reason} -> raise "config #{abs}: #{inspect(reason)}"
      end

    raw = interpolate(raw)

    listen = parse_listen(fetch!(raw, "listen"))
    data_dir = fetch!(raw, "data_dir")
    File.mkdir_p!(data_dir)

    plugins = parse_plugins(fetch!(raw, "plugins"), Path.dirname(abs))
    tokens = parse_tokens(fetch!(raw, "tokens"), plugins)

    %__MODULE__{
      listen: listen,
      data_dir: data_dir,
      log_level: parse_log_level(Map.get(raw, "log_level", "info")),
      anthropic_api_key: Map.get(raw, "anthropic_api_key"),
      tokens: tokens,
      plugins: plugins,
      hot_reload: parse_hot_reload(Map.get(raw, "hot_reload", true)),
      source_path: abs
    }
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when not is_nil(v) -> v
      _ -> raise "config: missing required key `#{key}`"
    end
  end

  defp parse_listen(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [host, port_str] ->
        port =
          case Integer.parse(port_str) do
            {p, ""} when p in 1..65_535 -> p
            _ -> raise "config: bad port in listen=#{value}"
          end

        ip =
          case :inet.parse_address(String.to_charlist(host)) do
            {:ok, addr} -> addr
            {:error, _} -> raise "config: bad host in listen=#{value} (use IP, not name)"
          end

        {ip, port}

      _ ->
        raise "config: listen must be `IP:PORT`, got #{inspect(value)}"
    end
  end

  defp parse_listen(other), do: raise("config: listen must be string, got #{inspect(other)}")

  defp parse_tokens(list, plugins) when is_list(list) and is_map(plugins) do
    Enum.reduce(list, %{}, fn entry, acc ->
      name = fetch!(entry, "name")
      token = fetch!(entry, "token")
      allowed = parse_allowed(name, fetch!(entry, "plugins"), plugins)

      if Map.has_key?(acc, token) do
        raise "config: duplicate token (entries `#{acc[token].name}` and `#{name}` share value)"
      end

      Map.put(acc, token, %{name: name, allowed: allowed})
    end)
  end

  defp parse_tokens(other, _), do: raise("config: tokens must be list, got #{inspect(other)}")

  defp parse_allowed(_name, ["*"], _plugins), do: :all

  defp parse_allowed(token_name, list, plugins) when is_list(list) do
    Enum.each(list, fn p ->
      unless is_binary(p) do
        raise "config: token `#{token_name}` plugins must be strings, got #{inspect(p)}"
      end

      unless Map.has_key?(plugins, p) do
        raise "config: token `#{token_name}` references unknown plugin `#{p}`"
      end
    end)

    MapSet.new(list)
  end

  defp parse_allowed(token_name, other, _) do
    raise "config: token `#{token_name}` plugins must be `[\"*\"]` or list of plugin names, got #{inspect(other)}"
  end

  defp parse_plugins(map, config_dir) when is_map(map) do
    Map.new(map, fn {name, path} ->
      unless is_binary(name) and Regex.match?(@plugin_name_re, name) do
        raise "config: plugin name `#{inspect(name)}` invalid — must match #{Regex.source(@plugin_name_re)}"
      end

      unless is_binary(path) do
        raise "config: plugin `#{name}` path must be string, got #{inspect(path)}"
      end

      expanded =
        path
        |> Path.expand(config_dir)

      {name, expanded}
    end)
  end

  defp parse_plugins(other, _),
    do: raise("config: plugins must be a map of name → path, got #{inspect(other)}")

  defp parse_hot_reload(v) when is_boolean(v), do: v

  defp parse_hot_reload(other),
    do: raise("config: hot_reload must be boolean, got #{inspect(other)}")

  defp parse_log_level(level) when is_binary(level) do
    case level do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "warn" -> :warning
      "error" -> :error
      _ -> raise "config: bad log_level #{inspect(level)}"
    end
  end

  defp interpolate(value) when is_binary(value) do
    Regex.replace(@env_var_re, value, fn _, var ->
      case System.get_env(var) do
        nil -> raise "config: env var `#{var}` referenced but not set"
        v -> v
      end
    end)
  end

  defp interpolate(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, interpolate(v)} end)

  defp interpolate(value) when is_list(value), do: Enum.map(value, &interpolate/1)
  defp interpolate(value), do: value
end
