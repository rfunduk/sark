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
          - { name: laptop, plugins: [ALL], token: sk-aaaa }
          - { name: phone,  plugins: [ALL], token: sk-bbbb }
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
          - { name: laptop, plugins: [ALL], token: sk-aaaa }
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
          - { name: laptop, plugins: [ALL], token: "${#{var}}" }
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
          - { name: laptop, plugins: [ALL], token: "${SARK_DEFINITELY_UNSET_XYZ}" }
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
          - { name: a, plugins: [ALL], token: sk-same }
          - { name: b, plugins: [ALL], token: sk-same }
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
      auth: { tokens: [{ name: t, plugins: [ALL], token: sk-t }] }
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
    %{"sk-ro" => %{allowed: %{"kv" => [%{pos: pos, neg: []}]}}} = cfg.tokens
    assert length(pos) == 3
    assert Enum.all?(pos, &match?(%Regex{}, &1))

    [get_re, list_re, find_re] = pos
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
          - { name: ro, plugins: [{kv: read_%}], token: sk-ro }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-ro" => %{allowed: %{"kv" => [%{pos: [re], neg: []}]}}} = cfg.tokens
    assert Regex.match?(re, "read_things")
    assert Regex.match?(re, "read_one")
    refute Regex.match?(re, "write_things")
  end

  test "`%` glob matches any sequence (leading, mid, trailing)", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [{kv: [read_%, %_audit, foo_%_bar]}], token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => [%{pos: [trail, lead, mid], neg: []}]}}} = cfg.tokens

    assert Regex.match?(trail, "read_foo")
    refute Regex.match?(trail, "write_foo")
    assert Regex.match?(lead, "user_audit")
    refute Regex.match?(lead, "user_audit_x")
    assert Regex.match?(mid, "foo_x_bar")
    refute Regex.match?(mid, "foo__")
  end

  test "patterns are anchored — partial match doesn't pass", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [{kv: [read_%]}], token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => [%{pos: [re]}]}}} = cfg.tokens
    refute Regex.match?(re, "foo_read_one")
    refute Regex.match?(re, "read")
    assert Regex.match?(re, "read_anything")
  end

  test "`_` is literal in patterns (snake_case safe)", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [{kv: [read_audit]}], token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => [%{pos: [re]}]}}} = cfg.tokens
    assert Regex.match?(re, "read_audit")
    refute Regex.match?(re, "readxaudit")
  end

  test "`{ALL: ...}` plugin key expands across all known plugins", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [{ALL: [get_meta]}], token: sk-t }
      plugins:
        kv: ./kv
        kb: ./kb
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: allowed}} = cfg.tokens
    assert Map.keys(allowed) |> Enum.sort() == ["kb", "kv"]
    assert match?([%{pos: [%Regex{}], neg: []}], Map.fetch!(allowed, "kv"))
    assert match?([%{pos: [%Regex{}], neg: []}], Map.fetch!(allowed, "kb"))
  end

  test "`{ALL: ...}` unions with explicit plugin entries", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - name: t
            plugins:
              - {kv: [bump]}
              - {ALL: [get_meta]}
            token: sk-t
      plugins:
        kv: ./kv
        kb: ./kb
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => kv_blocks, "kb" => kb_blocks}}} = cfg.tokens
    assert length(kv_blocks) == 2
    assert length(kb_blocks) == 1
  end

  test "duplicate plugin entries union as separate blocks", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - name: t
            plugins:
              - {kv: [read_%]}
              - {kv: [bump]}
            token: sk-t
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-t" => %{allowed: %{"kv" => blocks}}} = cfg.tokens
    assert length(blocks) == 2
    Enum.each(blocks, fn b -> assert match?(%{pos: [_], neg: []}, b) end)
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
              - {kv: [read_%]}
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

  test "scalar `plugins: ALL` is sugar for `[ALL]`", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: ALL, token: sk-t }
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

  test "`[ALL]` becomes top-level `:all`", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens:
          - { name: t, plugins: [ALL], token: sk-t }
      plugins:
        kv: ./kv
      """)

    cfg = Sark.Config.load!(path)
    assert %{"sk-t" => %{allowed: :all}} = cfg.tokens
  end

  describe "plugin-level negation" do
    test "[ALL, -name] removes the named plugin", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [ALL, -secrets], token: sk-t }
        plugins:
          kv: ./kv
          kb: ./kb
          secrets: ./secrets
        """)

      cfg = Sark.Config.load!(path)
      %{"sk-t" => %{allowed: allowed}} = cfg.tokens
      assert Map.keys(allowed) |> Enum.sort() == ["kb", "kv"]
      assert allowed["kv"] == :all
      assert allowed["kb"] == :all
    end

    test "[-ALL] empties everything (explicit deny-all marker)", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [ALL, -ALL], token: sk-t }
        plugins:
          kv: ./kv
        """)

      cfg = Sark.Config.load!(path)
      assert %{"sk-t" => %{allowed: %{}}} = cfg.tokens
    end

    test "[-name] alone (no positive) = empty allowlist", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [-secrets], token: sk-t }
        plugins:
          secrets: ./secrets
          kv: ./kv
        """)

      cfg = Sark.Config.load!(path)
      assert %{"sk-t" => %{allowed: %{}}} = cfg.tokens
    end

    test "order matters — [ALL, -secrets] vs [-secrets, ALL]", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: a, plugins: [ALL, -secrets],  token: sk-a }
            - { name: b, plugins: [-secrets, ALL],  token: sk-b }
        plugins:
          kv: ./kv
          secrets: ./secrets
        """)

      cfg = Sark.Config.load!(path)
      # [ALL, -secrets]: add all, remove secrets → no secrets
      assert Map.keys(cfg.tokens["sk-a"].allowed) |> Enum.sort() == ["kv"]
      # [-secrets, ALL]: remove (no-op, not in acc), then add all → secrets back
      assert Map.keys(cfg.tokens["sk-b"].allowed) |> Enum.sort() == ["kv", "secrets"]
    end

    test "negated plugin must exist (unknown plugin → error)", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [ALL, -ghost], token: sk-t }
        plugins:
          kv: ./kv
        """)

      assert_raise RuntimeError, ~r/unknown plugin `ghost`/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "plugin-level mix: [ALL, -secrets, {kv: [...]}]", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [ALL, -secrets, {kv: [read_%]}], token: sk-t }
        plugins:
          kv: ./kv
          kb: ./kb
          secrets: ./secrets
        """)

      cfg = Sark.Config.load!(path)
      %{"sk-t" => %{allowed: allowed}} = cfg.tokens
      assert Map.keys(allowed) |> Enum.sort() == ["kb", "kv"]
      assert allowed["kb"] == :all
      # kv: ALL block from `ALL` (which is :all), then `{kv: [read_%]}` block.
      # Union: :all absorbs.
      assert allowed["kv"] == :all
    end

    test "negated plugin key carrying patterns is rejected", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{"-secrets": [foo]}], token: sk-t }
        plugins:
          secrets: ./secrets
        """)

      assert_raise RuntimeError, ~r/negated plugin key/, fn ->
        Sark.Config.load!(path)
      end
    end
  end

  describe "tool-level negation" do
    test "[ALL, -name] resolves correctly", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{kv: [ALL, -read_audit]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      cfg = Sark.Config.load!(path)
      %{"sk-t" => %{allowed: %{"kv" => [block]}}} = cfg.tokens
      assert match?(%{pos: [%Regex{}], neg: [%Regex{}]}, block)

      # Block grants any name except `read_audit`
      [pos] = block.pos
      [neg] = block.neg
      assert Regex.match?(pos, "read_audit")
      assert Regex.match?(pos, "anything")
      assert Regex.match?(neg, "read_audit")
      refute Regex.match?(neg, "read_other")
    end

    test "[-name] only (no positive) → empty effective set", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{kv: [-foo]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      cfg = Sark.Config.load!(path)
      %{"sk-t" => %{allowed: %{"kv" => [%{pos: [], neg: [_]}]}}} = cfg.tokens
    end

    test "[ALL, -%_secret] glob negation", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{kv: [ALL, -%_secret]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      cfg = Sark.Config.load!(path)
      %{"sk-t" => %{allowed: %{"kv" => [block]}}} = cfg.tokens
      [neg] = block.neg
      assert Regex.match?(neg, "user_secret")
      assert Regex.match?(neg, "api_secret")
      refute Regex.match?(neg, "user_audit")
    end

    test "[-ALL] inside tool list = empty (negation absorbs)", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{kv: [ALL, -ALL]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      cfg = Sark.Config.load!(path)
      %{"sk-t" => %{allowed: %{"kv" => [block]}}} = cfg.tokens
      # pos = [.*], neg = [.*] → resolves to empty in AuthRegistry
      assert match?(%{pos: [%Regex{}], neg: [%Regex{}]}, block)
    end

    test "[ALL] alone in tool list = :all (no neg → unrestricted)", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{kv: [ALL]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      cfg = Sark.Config.load!(path)
      assert %{"sk-t" => %{allowed: %{"kv" => :all}}} = cfg.tokens
    end

    test "{ALL: [ALL, -sark_%]} — all plugins, no builtins", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{ALL: [ALL, -sark_%]}], token: sk-t }
        plugins:
          kv: ./kv
          kb: ./kb
        """)

      cfg = Sark.Config.load!(path)
      %{"sk-t" => %{allowed: allowed}} = cfg.tokens
      assert Map.keys(allowed) |> Enum.sort() == ["kb", "kv"]
      [%{neg: [neg]}] = allowed["kv"]
      assert Regex.match?(neg, "sark_catalog")
      refute Regex.match?(neg, "read_foo")
    end
  end

  describe "legacy syntax rejection" do
    test "rejects `*` wildcard with migration hint", %{tmp_dir: dir} do
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

      assert_raise RuntimeError, ~r/use `ALL`/, fn -> Sark.Config.load!(path) end
    end

    test "rejects `*` glob inside pattern", %{tmp_dir: dir} do
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

      assert_raise RuntimeError, ~r/use `%`/, fn -> Sark.Config.load!(path) end
    end

    test "rejects `?` glob", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{kv: ["ge?"]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      assert_raise RuntimeError, ~r/`\?`/, fn -> Sark.Config.load!(path) end
    end

    test "rejects `!`-prefix negation", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{kv: [ALL, "!read_audit"]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      assert_raise RuntimeError, ~r/`!`-prefix/, fn -> Sark.Config.load!(path) end
    end

    test "rejects `*` plugin key", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens:
            - { name: t, plugins: [{"*": [foo]}], token: sk-t }
        plugins:
          kv: ./kv
        """)

      assert_raise RuntimeError, ~r/use `ALL`/, fn -> Sark.Config.load!(path) end
    end
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
        - { name: legacy, plugins: [ALL], token: sk-legacy }
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
      auth: { tokens: [{ name: t, plugins: [ALL], token: sk-t }] }
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
      auth: { tokens: [{ name: t, plugins: [ALL], token: sk-t }] }
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
      auth: { tokens: [{ name: t, plugins: [ALL], token: sk-t }] }
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

  describe "auth.idp" do
    test "parses a minimal idp block", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens: []
          idp:
            issuer: https://accounts.google.com
            audience: sark.example.com
        plugins: {}
        """)

      cfg = Sark.Config.load!(path)

      assert %Sark.Config.IdP{
               issuer: "https://accounts.google.com",
               audience: "sark.example.com"
             } = cfg.idp
    end

    test "trims surrounding whitespace on idp credentials", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          idp:
            issuer: "  https://accounts.google.com  "
            audience: sark.example.com
            client_id: "abc123 "
            client_secret: "shh-secret\\n"
        plugins: {}
        """)

      cfg = Sark.Config.load!(path)
      assert cfg.idp.issuer == "https://accounts.google.com"
      assert cfg.idp.client_id == "abc123"
      assert cfg.idp.client_secret == "shh-secret"
    end

    test "idp defaults to nil when block absent", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth: { tokens: [{ name: t, plugins: [ALL], token: sk-t }] }
        plugins: {}
        """)

      cfg = Sark.Config.load!(path)
      assert cfg.idp == nil
    end

    test "idp without tokens is valid — tokens are optional", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          idp:
            issuer: https://accounts.google.com
            audience: sark.example.com
        plugins: {}
        """)

      cfg = Sark.Config.load!(path)
      assert %Sark.Config.IdP{} = cfg.idp
      assert cfg.tokens == %{}
    end

    test "rejects auth with neither tokens nor idp", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth: { tokens: [] }
        plugins: {}
        """)

      assert_raise RuntimeError, ~r/must define `tokens:` or `idp:`/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rejects missing issuer", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens: []
          idp:
            audience: sark
        plugins: {}
        """)

      assert_raise RuntimeError, ~r/auth\.idp\.issuer is required/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "audience defaults to `sark` when omitted", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens: []
          idp:
            issuer: https://idp.local
        plugins: {}
        """)

      cfg = Sark.Config.load!(path)
      assert cfg.idp.audience == "sark"
    end

    test "rejects non-http(s) issuer", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens: []
          idp:
            issuer: ftp://nope.example.com
            audience: sark
        plugins: {}
        """)

      assert_raise RuntimeError, ~r/auth\.idp\.issuer must use http or https/, fn ->
        Sark.Config.load!(path)
      end
    end
  end

  describe "auth.idp.rules" do
    defp idp_config(dir, rules_yaml) do
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      auth:
        tokens: []
        idp:
          issuer: https://idp.example.com
          audience: sark
          rules:
      #{rules_yaml}
      plugins:
        kv: test/fixtures/plugins/kv
      """)
    end

    test "absent → empty list (default deny — every claim eval misses)", %{tmp_dir: dir} do
      path =
        write_config(dir, """
        listen: 127.0.0.1:9090
        data_dir: #{Path.join(dir, "data")}
        auth:
          tokens: []
          idp:
            issuer: https://idp.example.com
            audience: sark
        plugins: {}
        """)

      cfg = Sark.Config.load!(path)
      assert cfg.idp.rules == []
    end

    test "parses a happy rule with each operator", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: role,     in: [owner, admin] },       plugins: [ALL] }
              - { match: { path: groups,   contains: admin },          plugins: [kv] }
              - { match: { path: email,    equals: ryan@example.com }, plugins: [kv] }
              - { match: { path: email,    suffix: "@example.com" },   plugins: [{kv: [read_%]}] }
              - { match: { path: sub,      exists: true },             plugins: [kv] }
        """)

      cfg = Sark.Config.load!(path)
      assert [r1, r2, r3, r4, r5] = cfg.idp.rules
      assert r1.match.op == :in
      assert r1.match.value == ["owner", "admin"]
      assert r1.match.path == ["role"]
      assert r1.plugins == :all
      assert r2.match.op == :contains
      assert r2.match.value == "admin"
      assert r3.match.op == :equals
      assert r4.match.op == :suffix
      assert r4.match.value == "@example.com"
      assert r5.match.op == :exists
      assert r5.match.value == true
    end

    test "nested path parses into segments", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: realm_access.roles, contains: reader }, plugins: [kv] }
        """)

      cfg = Sark.Config.load!(path)
      assert [%{match: %{path: ["realm_access", "roles"]}}] = cfg.idp.rules
    end

    test "in: rejects scalar (must be list)", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: role, in: admin }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/must be a list/, fn -> Sark.Config.load!(path) end
    end

    test "in: rejects empty list", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: role, in: [] }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/non-empty list/, fn -> Sark.Config.load!(path) end
    end

    test "in: rejects nested non-scalars", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: role, in: [[nested]] }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/scalar/, fn -> Sark.Config.load!(path) end
    end

    test "contains: rejects list value", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: groups, contains: [admin] }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/match\.contains value invalid/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rule without match is unconditional default-allow", %{tmp_dir: dir} do
      path = idp_config(dir, "        - { plugins: [kv] }\n")

      cfg = Sark.Config.load!(path)
      assert [%{match: nil, plugins: %{"kv" => :all}}] = cfg.idp.rules
    end

    test "`match: true` is explicit unconditional sugar", %{tmp_dir: dir} do
      path = idp_config(dir, "        - { match: true, plugins: [kv] }\n")

      cfg = Sark.Config.load!(path)
      assert [%{match: nil, plugins: %{"kv" => :all}}] = cfg.idp.rules
    end

    test "rejects `match: false` (dead rule)", %{tmp_dir: dir} do
      path = idp_config(dir, "        - { match: false, plugins: [kv] }\n")

      assert_raise RuntimeError, ~r/dead rule/, fn -> Sark.Config.load!(path) end
    end

    test "rejects rule missing plugins:", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: email, equals: x } }
        """)

      assert_raise RuntimeError, ~r/auth\.idp\.rules\[0\] missing required `plugins:`/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rejects match with conflicting operators", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: email, equals: x, suffix: y }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/conflicting operators/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rejects match with no operator", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: email }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/match needs one of/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rejects exists with non-true value", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: email, exists: false }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/exists must be `true`/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rejects empty path string", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: "", equals: x }, plugins: [kv] }
        """)

      assert_raise RuntimeError, ~r/match\.path must be non-empty string/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rejects unknown plugin in rule plugins:", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              - { match: { path: sub, exists: true }, plugins: [nonexistent] }
        """)

      assert_raise RuntimeError, ~r/references unknown plugin `nonexistent`/, fn ->
        Sark.Config.load!(path)
      end
    end

    test "rejects non-list rules:", %{tmp_dir: dir} do
      path =
        idp_config(dir, """
              foo: bar
        """)

      assert_raise RuntimeError, ~r/auth\.idp\.rules must be a list/, fn ->
        Sark.Config.load!(path)
      end
    end
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
