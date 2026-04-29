defmodule Sark.ConfigTest do
  use ExUnit.Case, async: false

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

  test "interpolates ${ENV} in string values", %{tmp_dir: dir} do
    System.put_env("SARK_TEST_TOKEN", "sk-from-env")
    on_exit(fn -> System.delete_env("SARK_TEST_TOKEN") end)

    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      tokens:
        - { name: laptop, plugins: ["*"], token: "${SARK_TEST_TOKEN}" }
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
      tokens: []
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
      tokens: []
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
      tokens: []
      plugins:
        jean: plugins/jean
      """)

    cfg = Sark.Config.load!(path)
    assert cfg.plugins == %{"jean" => Path.join(plugins_dir, "jean")}
  end

  test "scopes a token to specific plugins", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      tokens:
        - { name: wife, plugins: [jot], token: sk-wife }
      plugins:
        jot:  ./jot
        jean: ./jean
      """)

    cfg = Sark.Config.load!(path)
    %{"sk-wife" => %{name: "wife", allowed: allowed}} = cfg.tokens
    assert MapSet.equal?(allowed, MapSet.new(["jot"]))
  end

  test "rejects token referencing unknown plugin", %{tmp_dir: dir} do
    path =
      write_config(dir, """
      listen: 127.0.0.1:9090
      data_dir: #{Path.join(dir, "data")}
      tokens:
        - { name: bad, plugins: [ghost], token: sk-bad }
      plugins:
        jot: ./jot
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
      tokens: []
      plugins:
        "Bad Name!": ./bad
      """)

    assert_raise RuntimeError, ~r/invalid/, fn ->
      Sark.Config.load!(path)
    end
  end
end
