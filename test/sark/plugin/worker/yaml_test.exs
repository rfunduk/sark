defmodule Sark.Plugin.Worker.YAMLTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Worker
  alias Sark.Plugin.Worker.YAML

  @tmp_root "tmp/Sark.Plugin.Worker.YAMLTest"

  setup do
    dir = Path.join([@tmp_root, "p-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "returns [] when workers.yml is absent", %{dir: dir} do
    assert YAML.load(dir) == []
  end

  test "parses inline workers", %{dir: dir} do
    File.write!(Path.join(dir, "workers.yml"), """
    workers:
      smoke:
        description: smoke
        model: m
        tools: [a]
        system: s
        prompt: p
    """)

    [%Worker{name: :smoke, model: "m", tools: ["a"]}] = YAML.load(dir)
  end

  test "merges include files", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "workers"))

    File.write!(Path.join(dir, "workers.yml"), """
    include:
      - workers/*.yml

    workers:
      inline:
        description: inline
        model: m
        tools: [a]
        system: s
        prompt: p
    """)

    File.write!(Path.join(dir, "workers/extra.yml"), """
    workers:
      extra:
        description: extra
        model: m
        tools: [b]
        system: s
        prompt: p
    """)

    workers = YAML.load(dir)
    assert Enum.map(workers, & &1.name) == [:extra, :inline]
  end

  test "raises on duplicate worker name across files", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "workers"))

    File.write!(Path.join(dir, "workers.yml"), """
    include:
      - workers/dup.yml

    workers:
      same:
        description: x
        model: m
        tools: [a]
        system: s
        prompt: p
    """)

    File.write!(Path.join(dir, "workers/dup.yml"), """
    workers:
      same:
        description: y
        model: m
        tools: [a]
        system: s
        prompt: p
    """)

    assert_raise RuntimeError, ~r/duplicate worker `same`/, fn ->
      YAML.load(dir)
    end
  end

  test "raises on missing literal include", %{dir: dir} do
    File.write!(Path.join(dir, "workers.yml"), """
    include:
      - workers/missing.yml
    """)

    assert_raise RuntimeError, ~r/does not exist/, fn ->
      YAML.load(dir)
    end
  end

  test "parses optional when: and load: SQL fields", %{dir: dir} do
    File.write!(Path.join(dir, "workers.yml"), """
    workers:
      gated:
        description: g
        model: m
        tools: [a]
        when: |
          SELECT 1
        load: |
          SELECT count(*) AS n FROM x
        system: s
        prompt: p {{n}}
    """)

    [%Worker{name: :gated, when_sql: when_sql, load_sql: load_sql}] = YAML.load(dir)
    assert when_sql =~ "SELECT 1"
    assert load_sql =~ "FROM x"
  end

  test "raises when system: contains mustache", %{dir: dir} do
    File.write!(Path.join(dir, "workers.yml"), """
    workers:
      bad:
        description: g
        model: m
        tools: [a]
        system: |
          Today is {{date}}.
        prompt: p
    """)

    assert_raise ArgumentError, ~r/system.*mustache/i, fn -> YAML.load(dir) end
  end
end
