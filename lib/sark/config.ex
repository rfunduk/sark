defmodule Sark.Config do
  @moduledoc """
  Loads and validates `config.yml`.

  Shape:

      listen: 127.0.0.1:8080
      data_dir: /var/sark/data
      log_level: info                # optional
      anthropic_api_key_env: ANTHROPIC_API_KEY  # optional
      tokens:
        - { name: laptop, token: sk-... }
      plugins:
        - /srv/sark-plugins/jean
  """

  defstruct [
    :listen,
    :data_dir,
    :log_level,
    :anthropic_api_key_env,
    :tokens,
    :plugin_paths,
    :hot_reload,
    :source_path
  ]

  @type listen :: {:inet.ip_address(), :inet.port_number()}
  @type t :: %__MODULE__{
          listen: listen(),
          data_dir: String.t(),
          log_level: atom(),
          anthropic_api_key_env: String.t() | nil,
          tokens: %{String.t() => String.t()},
          plugin_paths: [String.t()],
          hot_reload: boolean(),
          source_path: String.t()
        }

  @env_var_re ~r/\$\{([A-Z_][A-Z0-9_]*)\}/

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

    tokens = parse_tokens(fetch!(raw, "tokens"))
    plugins = parse_plugins(fetch!(raw, "plugins"), Path.dirname(abs))

    %__MODULE__{
      listen: listen,
      data_dir: data_dir,
      log_level: parse_log_level(Map.get(raw, "log_level", "info")),
      anthropic_api_key_env: Map.get(raw, "anthropic_api_key_env"),
      tokens: tokens,
      plugin_paths: plugins,
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

  defp parse_tokens(list) when is_list(list) do
    Enum.reduce(list, %{}, fn entry, acc ->
      name = fetch!(entry, "name")
      token = fetch!(entry, "token")

      if Map.has_key?(acc, token) do
        raise "config: duplicate token (entries `#{acc[token]}` and `#{name}` share value)"
      end

      Map.put(acc, token, name)
    end)
  end

  defp parse_tokens(other), do: raise("config: tokens must be list, got #{inspect(other)}")

  defp parse_plugins(list, config_dir) when is_list(list) do
    Enum.map(list, fn
      p when is_binary(p) ->
        if Path.type(p) == :absolute, do: p, else: Path.expand(p, config_dir)

      other ->
        raise "config: plugin entry must be string path, got #{inspect(other)}"
    end)
  end

  defp parse_plugins(other, _), do: raise("config: plugins must be list, got #{inspect(other)}")

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
