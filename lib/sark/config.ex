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
          - { name: ryan,   plugins: [ALL], token: sk-ryan }
          - { name: reader, plugins: [{kv: [get, list, find]}], token: sk-ro }
          - { name: mixed,  plugins: [kb, {kv: read_%}], token: sk-mix }
          - { name: minus,  plugins: [ALL, -secrets, {kv: [ALL, -sark_%]}], token: sk-mn }
      plugins:
        kb:  ~/code/sark-kb
        kv:  test/fixtures/plugins/kv

  All identity config lives under `auth:` — `tokens:` (bearer table)
  and/or `idp:` (OAuth/OIDC broker). Both are optional individually,
  but at least one must be present; an `auth:` block with neither is
  rejected (idp-only is a legitimate deployment).

  `auth: none` (the literal) disables authentication entirely: every
  request is anonymous with full access to every plugin, carrying a
  synthesized `{"sub": "anon", "iss": "sark.none"}` envelope. Explicit
  opt-out for local / trusted-network deployments — sark doesn't gate
  it on bind address; saying `none` is the consent.

  `url:` is the externally-visible base URL of this sark instance.
  Required only when sark runs behind a reverse proxy (nginx, Cloudflare,
  Caddy) — the proxy terminates TLS and forwards a different host/scheme
  than what clients see. Used to build the metadata-document URL in the
  `WWW-Authenticate` challenge and the `resource` field in the
  protected-resource metadata doc. When absent, both are derived from
  the incoming `conn` (correct for local + single-host deployments).

  Each entry in `auth.tokens[*].plugins` is either:

    * a string — plugin name (full access), `ALL` (every known plugin),
      or `-<plugin>` / `-ALL` to negate
    * a single-key map — `{plugin: pattern_or_list}` where value is a
      glob pattern (`%`) or list of patterns/negations matched against
      tool names. Key can be `ALL` to apply patterns across every plugin.

  Reserved tokens:

    * `ALL` — uppercase keyword for "everything" (plugin or tool level).
      Plugin + tool names are enforced lowercase so `ALL` never shadows
      a real name.
    * `-prefix` — negation. `-secrets` removes plugin `secrets`. `-foo_%`
      excludes tools matching `foo_*`. Negation narrows the grant it
      appears in — never reaches across rules or tokens.
    * `%` — glob char (any sequence). SQL-LIKE flavour. `_` stays
      literal (snake_case-safe). Compiled to anchored regex.

  `[ALL]` shorthand is `:all` — every plugin, every tool. Multi-entry
  per plugin within a token unions as separate grants; negation in one
  doesn't suppress positives from another.

  Patterns are anchored (`read_%` matches `read_foo` but not `foo_read`).

  Legacy `*` / `?` / `!` syntax is hard-rejected with a migration hint.

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
    auth_none: false,
    providers: %Sark.Providers{},
    embedder: nil
  ]

  @type listen :: {:inet.ip_address(), :inet.port_number()}
  @type block :: %{pos: [Regex.t()], neg: [Regex.t()]}
  @type tool_grant :: :all | [block()]
  @type allowed :: :all | %{String.t() => tool_grant()}
  @type token_entry :: %{name: String.t(), allowed: allowed()}
  @type t :: %__MODULE__{
          listen: listen(),
          url: String.t() | nil,
          data_dir: String.t(),
          log_level: atom(),
          tokens: %{String.t() => token_entry()},
          auth_none: boolean(),
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

    {tokens, idp, auth_none} = parse_auth(fetch!(raw, "auth"), plugins)

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
      auth_none: auth_none,
      plugins: plugins,
      source_path: abs,
      providers: providers,
      embedder: embedder
    }
  end

  # `auth: none` — explicit opt-out: every request is anonymous with
  # full access to every plugin. The operator said so; sark doesn't
  # second-guess where it's deployed.
  defp parse_auth("none", _plugins), do: {%{}, nil, true}

  defp parse_auth(auth, plugins) when is_map(auth) do
    tokens = parse_tokens(Map.get(auth, "tokens", []), plugins)
    idp = parse_idp(Map.get(auth, "idp"), plugins)

    if tokens == %{} and is_nil(idp) do
      raise "config: `auth` must define `tokens:` or `idp:` (or both) — " <>
              "or be the literal `none` to disable auth entirely"
    end

    {tokens, idp, false}
  end

  defp parse_auth(other, _plugins) do
    raise "config: `auth` must be a map or the literal `none`, got #{inspect(other)}"
  end

  defp parse_idp(nil, _plugins), do: nil

  defp parse_idp(map, plugins) when is_map(map) do
    issuer = fetch_idp_url!(map, "issuer")
    client_id = parse_optional_idp_string(map, "client_id")
    client_secret = parse_optional_idp_string(map, "client_secret")
    audience = parse_audience(Map.get(map, "audience"), client_id)
    scope = parse_scope(Map.get(map, "scope"))
    rules = parse_rules(Map.get(map, "rules"), plugins)

    %Sark.Config.IdP{
      issuer: issuer,
      audience: audience,
      client_id: client_id,
      client_secret: client_secret,
      scope: scope,
      rules: rules
    }
  end

  defp parse_idp(other, _plugins) do
    raise "config: auth.idp must be a map, got #{inspect(other)}"
  end

  defp parse_rules(nil, _plugins), do: []
  defp parse_rules([], _plugins), do: []

  defp parse_rules(list, plugins) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {raw, idx} -> parse_rule(raw, idx, plugins) end)
  end

  defp parse_rules(other, _plugins),
    do: raise("config: auth.idp.rules must be a list, got #{inspect(other)}")

  defp parse_rule(raw, idx, plugins) when is_map(raw) do
    plugins_field =
      case Map.fetch(raw, "plugins") do
        {:ok, v} -> v
        :error -> raise "config: auth.idp.rules[#{idx}] missing required `plugins:`"
      end

    %{
      match: parse_match(Map.get(raw, "match"), idx),
      plugins: parse_allowed("auth.idp.rules[#{idx}]", plugins_field, plugins)
    }
  end

  defp parse_rule(other, idx, _plugins),
    do: raise("config: auth.idp.rules[#{idx}] must be a map, got #{inspect(other)}")

  defp parse_match(nil, _idx), do: nil
  defp parse_match(true, _idx), do: nil

  defp parse_match(false, idx),
    do: raise("config: auth.idp.rules[#{idx}].match: false is a dead rule — remove it")

  defp parse_match(map, idx) when is_map(map) do
    path_raw =
      case Map.get(map, "path") do
        v when is_binary(v) and v != "" ->
          v

        other ->
          raise "config: auth.idp.rules[#{idx}].match.path must be non-empty string, got #{inspect(other)}"
      end

    {op, value} = parse_match_op(map, idx)

    %{path: Sark.Auth.JSONPath.parse(path_raw), op: op, value: value}
  end

  defp parse_match(other, idx),
    do: raise("config: auth.idp.rules[#{idx}].match must be a map, got #{inspect(other)}")

  @match_ops ~w(equals in contains suffix exists)

  defp parse_match_op(map, idx) do
    ops = Enum.filter(@match_ops, &Map.has_key?(map, &1))

    case ops do
      [op] ->
        {String.to_atom(op), validate_op_value(op, Map.fetch!(map, op), idx)}

      [] ->
        raise "config: auth.idp.rules[#{idx}].match needs one of: #{Enum.join(@match_ops, ", ")}"

      multi ->
        raise "config: auth.idp.rules[#{idx}].match has conflicting operators #{inspect(multi)} — pick one"
    end
  end

  defp validate_op_value("exists", true, _idx), do: true

  defp validate_op_value("exists", other, idx),
    do: raise("config: auth.idp.rules[#{idx}].match.exists must be `true`, got #{inspect(other)}")

  defp validate_op_value("in", list, idx) when is_list(list) do
    if list == [] do
      raise "config: auth.idp.rules[#{idx}].match.in must be a non-empty list"
    end

    Enum.each(list, fn
      v when is_binary(v) or is_number(v) or is_boolean(v) ->
        :ok

      bad ->
        raise "config: auth.idp.rules[#{idx}].match.in entries must be scalar (string/number/boolean), got #{inspect(bad)}"
    end)

    list
  end

  defp validate_op_value("in", other, idx),
    do:
      raise(
        "config: auth.idp.rules[#{idx}].match.in must be a list of scalars, got #{inspect(other)} — for list-claim membership use `contains: <v>`"
      )

  defp validate_op_value(op, v, _idx)
       when op in ["equals", "contains", "suffix"] and is_binary(v),
       do: v

  defp validate_op_value(op, v, _idx)
       when op in ["equals", "contains"] and (is_number(v) or is_boolean(v)),
       do: v

  defp validate_op_value(op, other, idx),
    do: raise("config: auth.idp.rules[#{idx}].match.#{op} value invalid: #{inspect(other)}")

  # `scope:` is an additive list of extras. Sark always sends the
  # baseline (`openid email profile`); operator's list tacks more onto
  # it. Effective scope computed by `IdP.effective_scope/1`.
  defp parse_scope(nil), do: []
  defp parse_scope([]), do: []

  defp parse_scope(list) when is_list(list) do
    Enum.map(list, fn
      tok when is_binary(tok) and tok != "" ->
        tok

      bad ->
        raise "config: auth.idp.scope entries must be non-empty strings, got #{inspect(bad)}"
    end)
  end

  defp parse_scope(other),
    do: raise("config: auth.idp.scope must be a list of strings, got #{inspect(other)}")

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

  # Trim surrounding whitespace — credential values sourced from files,
  # Docker secrets, or `${ENV}` interpolation routinely pick up a trailing
  # newline/space, which upstream IdPs reject as an invalid secret.
  defp parse_optional_idp_string(map, key) do
    case Map.get(map, key) do
      nil ->
        nil

      v when is_binary(v) ->
        case String.trim(v) do
          "" -> nil
          trimmed -> trimmed
        end

      other ->
        raise "config: auth.idp.#{key} must be a string, got #{inspect(other)}"
    end
  end

  defp fetch_idp_string!(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) ->
        case String.trim(v) do
          "" -> raise "config: auth.idp.#{key} is required"
          trimmed -> trimmed
        end

      _ ->
        raise "config: auth.idp.#{key} is required"
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
      allowed = parse_allowed("token `#{name}`", fetch!(entry, "plugins"), plugins)

      if Map.has_key?(acc, token) do
        raise "config: duplicate token (entries `#{acc[token].name}` and `#{name}` share value)"
      end

      Map.put(acc, token, %{name: name, allowed: allowed})
    end)
  end

  defp parse_tokens(other, _), do: raise("config: tokens must be list, got #{inspect(other)}")

  # Public so Sark.Auth.Rules can reuse it for parsing rule plugins blocks.
  @doc false
  @spec parse_allowed(String.t(), term(), %{String.t() => term()}) :: allowed()
  def parse_allowed(where, raw, plugins)

  # Scalar sugar — `plugins: ALL` / `plugins: kv` parse as list-of-one.
  def parse_allowed(where, s, plugins) when is_binary(s),
    do: parse_allowed(where, [s], plugins)

  def parse_allowed(_where, ["ALL"], _plugins), do: :all

  def parse_allowed(where, list, plugins) when is_list(list) do
    Enum.each(list, &reject_legacy!(&1, where))

    Enum.reduce(list, %{}, fn entry, acc ->
      apply_entry(entry, acc, where, plugins)
    end)
  end

  def parse_allowed(where, other, _) do
    raise "config: #{where} plugins must be a list, got #{inspect(other)}"
  end

  # --- legacy-syntax rejection -----------------------------------------------

  defp reject_legacy!("*", where),
    do: raise("config: #{where} `*` is no longer valid — use `ALL` (uppercase keyword)")

  defp reject_legacy!("!" <> _ = s, where),
    do: raise("config: #{where} `!`-prefix negation is no longer valid (`#{s}`) — use `-` prefix")

  defp reject_legacy!(s, where) when is_binary(s) do
    cond do
      String.contains?(s, "*") ->
        raise "config: #{where} glob char `*` is no longer valid in `#{s}` — use `%`"

      String.contains?(s, "?") ->
        raise "config: #{where} glob char `?` is no longer valid in `#{s}` — use `%` (any sequence; single-char glob not supported)"

      true ->
        :ok
    end
  end

  defp reject_legacy!(map, where) when is_map(map) and map_size(map) == 1 do
    [{k, v}] = Map.to_list(map)

    if is_binary(k) do
      cond do
        k == "*" ->
          raise "config: #{where} plugin key `*` is no longer valid — use `ALL`"

        String.starts_with?(k, "!") ->
          raise "config: #{where} `!`-prefix on plugin key (`#{k}`) is invalid — negation only applies to bare entries"

        true ->
          :ok
      end
    end

    cond do
      is_binary(v) -> reject_legacy!(v, where)
      is_list(v) -> Enum.each(v, &reject_legacy!(&1, where))
      true -> :ok
    end
  end

  defp reject_legacy!(_other, _where), do: :ok

  # --- entry dispatch --------------------------------------------------------

  defp apply_entry("ALL", acc, _where, plugins) do
    Enum.reduce(Map.keys(plugins), acc, fn p, acc ->
      Map.update(acc, p, :all, &union_value(&1, :all))
    end)
  end

  defp apply_entry("-ALL", _acc, _where, _plugins), do: %{}

  defp apply_entry("-" <> name, acc, where, plugins) do
    validate_plugin!(name, where, plugins)
    Map.delete(acc, name)
  end

  defp apply_entry(name, acc, where, plugins) when is_binary(name) do
    validate_plugin!(name, where, plugins)
    Map.update(acc, name, :all, &union_value(&1, :all))
  end

  defp apply_entry(map, acc, where, plugins) when is_map(map) and map_size(map) == 1 do
    [{key, raw}] = Map.to_list(map)

    unless is_binary(key) do
      raise "config: #{where} plugin key must be string, got #{inspect(key)}"
    end

    value = parse_tool_value(raw, where, key)

    cond do
      key == "ALL" ->
        Enum.reduce(Map.keys(plugins), acc, fn p, acc ->
          Map.update(acc, p, value, &union_value(&1, value))
        end)

      String.starts_with?(key, "-") ->
        raise "config: #{where} negated plugin key `#{key}` cannot carry tool patterns — " <>
                "drop the patterns or remove the `-`"

      true ->
        validate_plugin!(key, where, plugins)
        Map.update(acc, key, value, &union_value(&1, value))
    end
  end

  defp apply_entry(other, _acc, where, _plugins) do
    raise "config: #{where} plugins entry must be a name or single-key map (got #{inspect(other)})"
  end

  defp validate_plugin!(name, where, plugins) do
    unless Map.has_key?(plugins, name) do
      raise "config: #{where} references unknown plugin `#{name}`"
    end
  end

  # --- tool-value parser (the {plugin: <value>} payload) ---------------------

  # Scalar sugar.
  defp parse_tool_value(s, where, plugin) when is_binary(s),
    do: parse_tool_value([s], where, plugin)

  defp parse_tool_value(list, where, plugin) when is_list(list) do
    Enum.each(list, fn
      s when is_binary(s) -> :ok
      o -> raise "config: #{where} tool pattern for `#{plugin}` must be string, got #{inspect(o)}"
    end)

    {has_all, pos, neg} =
      Enum.reduce(list, {false, [], []}, fn item, {ha, p, n} ->
        case classify_pattern(item, where, plugin) do
          :all -> {true, p, n}
          {:pos, re} -> {ha, [re | p], n}
          {:neg, re} -> {ha, p, [re | n]}
          :all_neg -> {ha, p, [~r/.*/ | n]}
        end
      end)

    pos = Enum.reverse(pos)
    neg = Enum.reverse(neg)

    cond do
      has_all and neg == [] ->
        :all

      has_all ->
        [%{pos: [~r/.*/], neg: neg}]

      true ->
        [%{pos: pos, neg: neg}]
    end
  end

  defp parse_tool_value(other, where, plugin) do
    raise "config: #{where} tool patterns for `#{plugin}` must be string or list, got #{inspect(other)}"
  end

  defp classify_pattern("ALL", _where, _plugin), do: :all
  defp classify_pattern("-ALL", _where, _plugin), do: :all_neg

  defp classify_pattern("-" <> rest, where, plugin) when rest != "" do
    {:neg, compile_glob!(rest, where, plugin)}
  end

  defp classify_pattern("-", where, plugin),
    do: raise("config: #{where} tool pattern `-` is empty for plugin `#{plugin}`")

  defp classify_pattern("", where, plugin),
    do: raise("config: #{where} empty tool pattern for plugin `#{plugin}`")

  defp classify_pattern(s, where, plugin), do: {:pos, compile_glob!(s, where, plugin)}

  defp compile_glob!(s, where, plugin) do
    regex =
      s
      |> String.graphemes()
      |> Enum.map_join(fn
        "%" -> ".*"
        c -> Regex.escape(c)
      end)

    case Regex.compile("\\A" <> regex <> "\\z") do
      {:ok, re} ->
        re

      {:error, reason} ->
        raise "config: #{where} bad tool pattern `#{s}` for plugin `#{plugin}`: #{inspect(reason)}"
    end
  end

  # --- union ---------------------------------------------------------------

  @doc false
  @spec union_value(tool_grant(), tool_grant()) :: tool_grant()
  def union_value(:all, _), do: :all
  def union_value(_, :all), do: :all
  def union_value(a, b) when is_list(a) and is_list(b), do: a ++ b

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
