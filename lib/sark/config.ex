defmodule Sark.Config do
  @moduledoc """
  Loads and validates `config.yml`.

  Shape:

      listen: 127.0.0.1:8080
      url: https://sark.example.com  # optional, see below
      data_dir: /var/sark/data
      log_level: info                # optional
      providers:                     # optional, only required if LLM/embedder used
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
        ollama:
          url: http://localhost:11434
      embedder:                      # optional, only required for RAG
        provider: ollama
        model: nomic-embed-text
        dim: 768
        defaults:
          chunk: { size: 1024, overlap: 128 }
      auth:
        tokens:
          - { name: ryan,   plugins: ["*"], token: sk-ryan }
          - { name: reader, plugins: [{kv: ["get", "list", "find"]}], token: sk-ro }
          - { name: mixed,  plugins: [kb, {kv: "read_*"}], token: sk-mix }
      plugins:
        kb:  ~/code/sark-kb
        kv:  test/fixtures/plugins/kv

  All identity config lives under `auth:`. Currently only `tokens:`; a
  future OAuth IdP block will sit alongside it as `auth.idp:`.

  `url:` is the externally-visible base URL of this sark instance.
  Required only when sark runs behind a reverse proxy (nginx, Cloudflare,
  Caddy) — the proxy terminates TLS and forwards a different host/scheme
  than what clients see. Used to build the metadata-document URL in the
  `WWW-Authenticate` challenge and the `resource` field in the
  protected-resource metadata doc. When absent, both are derived from
  the incoming `conn` (correct for local + single-host deployments).

  Each entry in `auth.tokens[*].plugins` is either:

    * a string — plugin name (full access to all of its tools), or `"*"`
      (every known plugin)
    * a single-key map — `{plugin: pattern_or_list}` where the value is a
      glob pattern (`*` / `?`) or list of glob patterns matched against
      tool names. `plugin` can be `"*"` to apply patterns across every
      known plugin.

  `["*"]` shorthand is equivalent to `[{"*": "*"}]` — every plugin, every
  tool. Multiple entries for the same plugin union; if any contributes
  `"*"` the plugin's surface is unrestricted.

  Patterns are anchored fnmatch (`read_*` matches `read_foo` but not
  `foo_read`). Globs only work if the plugin author names tools
  consistently — sark doesn't enforce naming.

  Reachability check happens in `Sark.AuthPlug` against the URL path
  `/<plugin>/mcp`. Tool-name filtering happens in the generated router's
  `connect/2` via `Phantom.Session.allowed_tools`.

  `plugins` is a map: name (used everywhere — tool routing, DB filename,
  pool registry) → directory path. Decoupling the name from the on-disk
  basename keeps tokens stable across plugin dir renames.
  """

  defstruct [
    :listen,
    :url,
    :data_dir,
    :log_level,
    :tokens,
    :plugins,
    :source_path,
    idp: nil,
    providers: %Sark.Providers{},
    embedder: nil
  ]

  @type listen :: {:inet.ip_address(), :inet.port_number()}
  @type tool_patterns :: :all | [Regex.t()]
  @type allowed :: :all | %{String.t() => tool_patterns()}
  @type token_entry :: %{name: String.t(), allowed: allowed()}
  @type t :: %__MODULE__{
          listen: listen(),
          url: String.t() | nil,
          data_dir: String.t(),
          log_level: atom(),
          tokens: %{String.t() => token_entry()},
          plugins: %{String.t() => String.t()},
          source_path: String.t(),
          providers: Sark.Providers.t(),
          embedder: Sark.Embedder.Config.t() | nil
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

    config_dir = Path.dirname(abs)

    listen = parse_listen(fetch!(raw, "listen"))
    url = parse_url(Map.get(raw, "url"))
    data_dir = Path.expand(fetch!(raw, "data_dir"), config_dir)
    File.mkdir_p!(data_dir)

    plugins = parse_plugins(fetch!(raw, "plugins"), config_dir)

    if Map.has_key?(raw, "tokens") do
      raise "config: top-level `tokens:` was moved under `auth.tokens:` — " <>
              "nest your tokens list inside an `auth:` block"
    end

    auth = fetch!(raw, "auth")

    unless is_map(auth) do
      raise "config: `auth` must be a map, got #{inspect(auth)}"
    end

    tokens = parse_tokens(fetch!(auth, "tokens"), plugins)
    idp = parse_idp(Map.get(auth, "idp"))
    providers = Sark.Providers.parse(Map.get(raw, "providers"))
    embedder = Sark.Embedder.Config.parse(Map.get(raw, "embedder"))

    :ok = Sark.Embedder.validate_config!(embedder, providers)

    %__MODULE__{
      listen: listen,
      url: url,
      data_dir: data_dir,
      log_level: parse_log_level(Map.get(raw, "log_level", "info")),
      tokens: tokens,
      idp: idp,
      plugins: plugins,
      source_path: abs,
      providers: providers,
      embedder: embedder
    }
  end

  defp parse_idp(nil), do: nil

  defp parse_idp(map) when is_map(map) do
    issuer = fetch_idp_url!(map, "issuer")
    client_id = parse_optional_idp_string(map, "client_id")
    client_secret = parse_optional_idp_string(map, "client_secret")
    audience = parse_audience(Map.get(map, "audience"), client_id)

    %Sark.Config.IdP{
      issuer: issuer,
      audience: audience,
      client_id: client_id,
      client_secret: client_secret
    }
  end

  defp parse_idp(other) do
    raise "config: auth.idp must be a map, got #{inspect(other)}"
  end

  # Audience resolution:
  #   1. Explicit `audience:` wins.
  #   2. Else default to `client_id` (Google-style: aud = client_id).
  #   3. Else default to `"sark"` (resource-indicator IdPs: PocketID,
  #      Okta, Auth0, Keycloak, Authelia — operator registers the
  #      resource as `sark`).
  defp parse_audience(v, _client_id) when is_binary(v) and v != "", do: v
  defp parse_audience(nil, client_id) when is_binary(client_id) and client_id != "", do: client_id
  defp parse_audience("", client_id) when is_binary(client_id) and client_id != "", do: client_id
  defp parse_audience(nil, _), do: "sark"
  defp parse_audience("", _), do: "sark"

  defp parse_audience(other, _),
    do: raise("config: auth.idp.audience must be a string, got #{inspect(other)}")

  defp parse_optional_idp_string(map, key) do
    case Map.get(map, key) do
      nil -> nil
      "" -> nil
      v when is_binary(v) -> v
      other -> raise "config: auth.idp.#{key} must be a string, got #{inspect(other)}"
    end
  end

  defp fetch_idp_string!(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> v
      _ -> raise "config: auth.idp.#{key} is required"
    end
  end

  defp fetch_idp_url!(map, key) do
    value = fetch_idp_string!(map, key)
    validate_idp_url!(value, "auth.idp.#{key}")
  end

  defp validate_idp_url!(value, where) do
    uri = URI.parse(value)

    cond do
      uri.scheme not in ["http", "https"] ->
        raise "config: #{where} must use http or https scheme, got #{inspect(value)}"

      uri.host in [nil, ""] ->
        raise "config: #{where} must include a host, got #{inspect(value)}"

      true ->
        value
    end
  end

  defp parse_url(nil), do: nil

  defp parse_url(value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      uri.scheme not in ["http", "https"] ->
        raise "config: url must use http or https scheme, got #{inspect(value)}"

      uri.host in [nil, ""] ->
        raise "config: url must include a host, got #{inspect(value)}"

      uri.path not in [nil, "", "/"] ->
        raise "config: url must be a bare origin (no path), got #{inspect(value)}"

      true ->
        # Normalize: strip trailing slash, drop empty path/query/fragment.
        port_part =
          case {uri.scheme, uri.port} do
            {"http", 80} -> ""
            {"https", 443} -> ""
            {_, nil} -> ""
            {_, p} -> ":#{p}"
          end

        "#{uri.scheme}://#{uri.host}#{port_part}"
    end
  end

  defp parse_url(other), do: raise("config: url must be a string, got #{inspect(other)}")

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

  # Legacy shorthand: `plugins: ["*"]` → unrestricted everywhere. Kept
  # because it's terser than `[{"*": "*"}]` for the common "give me a
  # full-access token" case and matches the README example.
  defp parse_allowed(_token_name, ["*"], _plugins), do: :all

  # Scalar sugar — `plugins: "*"` / `plugins: "kv"` parse as list-of-one,
  # matching the same string→list affordance the per-plugin pattern value
  # already gives (`{kv: "read_*"}`).
  defp parse_allowed(token_name, s, plugins) when is_binary(s),
    do: parse_allowed(token_name, [s], plugins)

  defp parse_allowed(token_name, list, plugins) when is_list(list) do
    list
    |> Enum.reduce(%{}, fn entry, acc -> merge_entry(entry, acc, token_name, plugins) end)
    |> expand_wildcard(plugins)
  end

  defp parse_allowed(token_name, other, _) do
    raise "config: token `#{token_name}` plugins must be a list, got #{inspect(other)}"
  end

  defp merge_entry(plugin, acc, token_name, plugins) when is_binary(plugin) do
    validate_plugin_or_wildcard!(plugin, token_name, plugins)
    Map.update(acc, plugin, :all, &merge_patterns(&1, :all))
  end

  defp merge_entry(map, acc, token_name, plugins) when is_map(map) and map_size(map) == 1 do
    [{plugin, raw}] = Map.to_list(map)

    unless is_binary(plugin) do
      raise "config: token `#{token_name}` plugin key must be string, got #{inspect(plugin)}"
    end

    validate_plugin_or_wildcard!(plugin, token_name, plugins)
    patterns = parse_pattern_value(raw, token_name, plugin)
    Map.update(acc, plugin, patterns, &merge_patterns(&1, patterns))
  end

  defp merge_entry(other, _acc, token_name, _plugins) do
    raise "config: token `#{token_name}` plugins entries must be a plugin name or a single-key map " <>
            "(got #{inspect(other)})"
  end

  defp validate_plugin_or_wildcard!("*", _token, _plugins), do: :ok

  defp validate_plugin_or_wildcard!(name, token_name, plugins) do
    unless Map.has_key?(plugins, name) do
      raise "config: token `#{token_name}` references unknown plugin `#{name}`"
    end
  end

  defp parse_pattern_value(s, token_name, plugin) when is_binary(s),
    do: [compile_glob!(s, token_name, plugin)]

  defp parse_pattern_value(list, token_name, plugin) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) ->
        compile_glob!(s, token_name, plugin)

      other ->
        raise "config: token `#{token_name}` tool pattern for `#{plugin}` must be string, got #{inspect(other)}"
    end)
  end

  defp parse_pattern_value(other, token_name, plugin) do
    raise "config: token `#{token_name}` tool patterns for `#{plugin}` must be string or list, got #{inspect(other)}"
  end

  defp merge_patterns(:all, _), do: :all
  defp merge_patterns(_, :all), do: :all
  defp merge_patterns(a, b) when is_list(a) and is_list(b), do: a ++ b

  defp expand_wildcard(map, plugins) do
    case Map.pop(map, "*") do
      {nil, m} ->
        m

      {wild, m} ->
        Enum.reduce(Map.keys(plugins), m, fn p, acc ->
          Map.update(acc, p, wild, &merge_patterns(&1, wild))
        end)
    end
  end

  defp compile_glob!(s, token_name, plugin) do
    regex =
      s
      |> String.graphemes()
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        c -> Regex.escape(c)
      end)

    case Regex.compile("\\A" <> regex <> "\\z") do
      {:ok, re} ->
        re

      {:error, reason} ->
        raise "config: token `#{token_name}` bad tool pattern `#{s}` for plugin `#{plugin}`: #{inspect(reason)}"
    end
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
