defmodule Sark.ConfigTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp write_config(dir, body) do
    path = Path.join(dir, "config.yml")
    File.write!(path, body)
    path
  end

  test "parses minimal valid config", %{tmp_dir: dir} do
    data_dir = Path.join(dir, "data")

    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{data_dir}
      auth:
        tokens:
          - { name: laptop, plugins: ["*"], token: sk-aaaa }
          - { name: phone,  plugins: ["*"], token: sk-bbbb }
      plugins: {}
      """)

    cfg = Sark.Config.load!(path)

    assert cfg.listen == {{127, 0, 0, 1}, 9090}
    assert cfg.data_dir == data_dir
    assert cfg.log_level == :info

    assert cfg.tokens == %{
             "sk-aaaa" => %{name: "laptop", allowed: :all},
             "sk-bbbb" => %{name: "phone", allowed: :all}
           }

    assert cfg.plugins == %{}
    assert File.dir?(data_dir)
  end

  test "resolves relative data_dir against config file dir", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: ./data
      auth:
        tokens:
          - { name: laptop, plugins: ["*"], token: sk-aaaa }
      plugins: {}
      """)

    cfg = Sark.Config.load!(path)

    assert cfg.data_dir == Path.join(dir, "data")
    assert File.dir?(cfg.data_dir)
  end

  test "interpolates ${ENV} in string values", %{tmp_dir: dir} do
    # Unique env var name keeps this test parallel-safe — concurrent
    # async tests can't clobber each other's interpolation values.
    var = "SARK_TEST_TOKEN_#{System.unique_integer([:positive])}"
    System.put_env(var, "sk-from-env")
    on_exit(fn -> System.delete_env(var) end)

    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: laptop, plugins: ["*"], token: "${#{var}}" }
      plugins: {}
      """)

    cfg = Sark.Config.load!(path)
    assert cfg.tokens == %{"sk-from-env" => %{name: "laptop", allowed: :all}}
  end

  test "raises when env var missing", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: laptop, plugins: ["*"], token: "${SARK_DEFINITELY_UNSET_XYZ}" }
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/SARK_DEFINITELY_UNSET_XYZ/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects missing required key", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      auth: { tokens: [] }
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/data_dir/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects bad listen format", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: not-a-host-port
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/listen/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects duplicate token values", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: a, plugins: ["*"], token: sk-same }
          - { name: b, plugins: ["*"], token: sk-same }
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/duplicate token/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "expands relative plugin paths against config dir", %{tmp_dir: dir} do
    plugins_dir = Path.join(dir, "plugins")
    File.mkdir_p!(plugins_dir)

    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins:
        workouts: plugins/workouts
      """)

    cfg = Sark.Config.load!(path)
    assert cfg.plugins == %{"workouts" => Path.join(plugins_dir, "workouts")}
  end

  test "scopes a token to specific plugins (bare name = unrestricted)", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: steve, plugins: [kb], token: sk-steve }
      plugins:
        kb:  ./kb
        workouts: ./workouts
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-steve" => %{name: "steve", allowed: allowed}} = cfg.tokens
    assert allowed == %{"kb" => :all}
  end

  test "single-key map scopes a token to specific tool names", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - name: ro
            plugins: [{kv: [get, list, find]}]
            token: sk-ro
      plugins:
        kv: ./kv
        kb: ./kb
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-ro" => %{allowed: %{"kv" => patterns}}} = cfg.tokens
    assert length(patterns) == 3
    assert Enum.all?(patterns, &match?(%Regex{}, &1))

    [get_re, list_re, find_re] = patterns
    assert Regex.match?(get_re, "get")
    refute Regex.match?(get_re, "getter")
    assert Regex.match?(list_re, "list")
    assert Regex.match?(find_re, "find")
  end

  test "scalar pattern value is sugar for a single-element list", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: ro, plugins: [{kv: "read_*"}], token: sk-ro }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-ro" => %{allowed: %{"kv" => [re]}}} = cfg.tokens
    assert Regex.match?(re, "read_things")
    assert Regex.match?(re, "read_one")
    refute Regex.match?(re, "write_things")
  end

  test "glob `*` matches any tool, `?` matches one char", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [{kv: ["*", "ge?"]}], token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => [star, q]}}} = cfg.tokens
    assert Regex.match?(star, "anything")
    assert Regex.match?(star, "sark_patch")
    assert Regex.match?(q, "get")
    refute Regex.match?(q, "gets")
    refute Regex.match?(q, "g")
  end

  test "patterns are anchored — partial match doesn't pass", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [{kv: ["read_*"]}], token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => [re]}}} = cfg.tokens
    refute Regex.match?(re, "foo_read_one")
    refute Regex.match?(re, "read")
    assert Regex.match?(re, "read_anything")
  end

  test "wildcard `*` plugin key expands across all known plugins", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [{"*": [sark_catalog]}], token: sk-t }
      plugins:
        kv: ./kv
        kb: ./kb
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: allowed}} = cfg.tokens
    assert Map.keys(allowed) |> Enum.sort() == ["kb", "kv"]
    assert match?([%Regex{}], Map.fetch!(allowed, "kv"))
    assert match?([%Regex{}], Map.fetch!(allowed, "kb"))
  end

  test "wildcard `*` unions with explicit plugin entries", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - name: t
            plugins:
              - {kv: [bump]}
              - {"*": [sark_catalog]}
            token: sk-t
      plugins:
        kv: ./kv
        kb: ./kb
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => kv_pats, "kb" => kb_pats}}} = cfg.tokens
    assert length(kv_pats) == 2
    assert length(kb_pats) == 1
  end

  test "duplicate plugin entries union their pattern lists", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - name: t
            plugins:
              - {kv: [read_*]}
              - {kv: [bump]}
            token: sk-t
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => patterns}}} = cfg.tokens
    assert length(patterns) == 2
  end

  test "bare plugin entry overrides any prior pattern list for that plugin", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - name: t
            plugins:
              - {kv: [read_*]}
              - kv
            token: sk-t
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => kv_value}}} = cfg.tokens
    # `:all` ∪ anything = `:all`
    assert kv_value == :all
  end

  test "scalar `plugins: \"*\"` is sugar for `[\"*\"]`", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: "*", token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    assert %{"sk-t" => %{allowed: :all}} = cfg.tokens
  end

  test "scalar `plugins: <name>` is sugar for `[<name>]`", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: kv, token: sk-t }
      plugins:
        kv: ./kv
        kb: ./kb
      """)

    cfg = Sark.Config.load!(path)
    assert %{"sk-t" => %{allowed: %{"kv" => :all}}} = cfg.tokens
  end

  test "`[\"*\"]` legacy shorthand stays `:all`", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: ["*"], token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    assert %{"sk-t" => %{allowed: :all}} = cfg.tokens
  end

  test "rejects unknown plugin name inside a single-key map", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: bad, plugins: [{ghost: ["x"]}], token: sk-bad }
      plugins:
        kb: ./kb
      """)

    assert_raise RuntimeError, ~r/unknown plugin `ghost`/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects multi-key map plugin entry", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - name: bad
            plugins:
              - {kv: [a], kb: [b]}
            token: sk-bad
      plugins:
        kv: ./kv
        kb: ./kb
      """)

    assert_raise RuntimeError, ~r/single-key map/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects non-string pattern in a list", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: bad, plugins: [{kv: [42]}], token: sk-bad }
      plugins:
        kv: ./kv
      """)

    assert_raise RuntimeError, ~r/must be string/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects non-list/non-string pattern value", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: bad, plugins: [{kv: 42}], token: sk-bad }
      plugins:
        kv: ./kv
      """)

    assert_raise RuntimeError, ~r/string or list/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects token referencing unknown plugin (bare name)", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: bad, plugins: [ghost], token: sk-bad }
      plugins:
        kb: ./kb
      """)

    assert_raise RuntimeError, ~r/unknown plugin `ghost`/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects invalid plugin name in plugins map", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins:
        "Bad Name!": ./bad
      """)

    assert_raise RuntimeError, ~r/invalid/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "rejects top-level `tokens:` with a migration hint", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      tokens:
        - { name: legacy, plugins: ["*"], token: sk-legacy }
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/moved under `auth\.tokens:`/, fn ->
      Sark.Config.load!(path)
    end
  end

  test "parses optional url:", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      url: https://sark.example.com
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins: {}
      """)

    cfg = Sark.Config.load!(path)
    assert cfg.url == "https://sark.example.com"
  end

  test "url defaults to nil when absent", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins: {}
      """)

    cfg = Sark.Config.load!(path)
    assert cfg.url == nil
  end

  test "url drops trailing slash and default port", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      url: https://sark.example.com:443/
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins: {}
      """)

    cfg = Sark.Config.load!(path)
    assert cfg.url == "https://sark.example.com"
  end

  test "url rejects non-http(s) scheme", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      url: ftp://sark.example.com
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/http or https/, fn -> Sark.Config.load!(path) end
  end

  test "url rejects paths", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      url: https://sark.example.com/sub
      data_dir: #{Path.join(dir, "data")}
      auth: { tokens: [] }
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/bare origin/, fn -> Sark.Config.load!(path) end
  end

  test "rejects non-map `auth:` block", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth: "nope"
      plugins: {}
      """)

    assert_raise RuntimeError, ~r/`auth` must be a map/, fn ->
      Sark.Config.load!(path)
    end
  end
end
