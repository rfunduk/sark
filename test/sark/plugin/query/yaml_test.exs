defmodule Sark.Plugin.Query.YAMLTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Query.YAML

  @moduletag :tmp_dir

  defp write(plugin_dir, files) do
    File.mkdir_p!(plugin_dir)

    Enum.each(files, fn {rel, body} ->
      path = Path.join(plugin_dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end)

    plugin_dir
  end

  defp q_yaml(name) do
    """
    queries:
      #{name}:
        description: q
        returns: scalar
        sql: SELECT 1
    """
  end

  test "absent queries.yml → empty queries + default opts", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{})
    assert YAML.load(plugin) == {[], %{allow_sql: false, patchable: %{}}}
  end

  test "loads inline queries", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{"queries.yml" => q_yaml("a")})
    {queries, opts} = YAML.load(plugin)
    assert [%{name: :a}] = queries
    assert opts == %{allow_sql: false, patchable: %{}}
  end

  test "allow_sql: true picked up", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        allow_sql: true
        queries:
          a:
            description: q
            returns: scalar
            sql: SELECT 1
        """
      })

    {_, opts} = YAML.load(plugin)
    assert opts == %{allow_sql: true, patchable: %{}}
  end

  test "patchable: maps table → list of cols", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        patchable:
          notes: [body, title]
          tasks: [body]
        queries:
          a:
            description: q
            returns: scalar
            sql: SELECT 1
        """
      })

    {_, opts} = YAML.load(plugin)
    assert opts.patchable == %{"notes" => ["body", "title"], "tasks" => ["body"]}
  end

  test "patchable defaults to empty map when absent", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{"queries.yml" => q_yaml("a")})
    {_, opts} = YAML.load(plugin)
    assert opts.patchable == %{}
  end

  test "patchable rejects non-map", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        patchable: [notes]
        queries: {}
        """
      })

    assert_raise RuntimeError, ~r/patchable must be a map/, fn -> YAML.load(plugin) end
  end

  test "patchable rejects bad identifier in table name", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        patchable:
          "bad-table": [body]
        queries: {}
        """
      })

    assert_raise RuntimeError, ~r/patchable table name/, fn -> YAML.load(plugin) end
  end

  test "patchable rejects bad identifier in column name", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        patchable:
          notes: ["bad col"]
        queries: {}
        """
      })

    assert_raise RuntimeError, ~r/patchable.notes entry/, fn -> YAML.load(plugin) end
  end

  test "patchable rejects non-list cols", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        patchable:
          notes: body
        queries: {}
        """
      })

    assert_raise RuntimeError, ~r/must be a list of column names/, fn -> YAML.load(plugin) end
  end

  test "allow_sql non-boolean raises", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        allow_sql: yes_please
        queries: {}
        """
      })

    assert_raise RuntimeError, ~r/allow_sql must be boolean/, fn -> YAML.load(plugin) end
  end

  test "include: list of literal files", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        include:
          - extra.yml
        queries:
          a:
            description: q
            returns: scalar
            sql: SELECT 1
        """,
        "extra.yml" => q_yaml("b")
      })

    {queries, _} = YAML.load(plugin)
    names = Enum.map(queries, & &1.name)
    assert names == [:a, :b]
  end

  test "include: glob expands", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        include:
          - queries/*.yml
        """,
        "queries/foo.yml" => q_yaml("foo"),
        "queries/bar.yml" => q_yaml("bar")
      })

    {queries, _} = YAML.load(plugin)
    names = Enum.map(queries, & &1.name)
    assert names == [:bar, :foo]
  end

  test "duplicate query name across files raises", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        include:
          - extra.yml
        queries:
          dup:
            description: q
            returns: scalar
            sql: SELECT 1
        """,
        "extra.yml" => q_yaml("dup")
      })

    assert_raise RuntimeError, ~r/duplicate query `dup`/, fn -> YAML.load(plugin) end
  end

  test "include literal that doesn't exist raises", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        include:
          - missing.yml
        """
      })

    assert_raise RuntimeError, ~r/include `missing.yml` does not exist/, fn ->
      YAML.load(plugin)
    end
  end

  test "include glob with no matches is fine (empty)", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        include:
          - queries/*.yml
        queries:
          a:
            description: q
            returns: scalar
            sql: SELECT 1
        """
      })

    {queries, _} = YAML.load(plugin)
    assert [%{name: :a}] = queries
  end

  test "include must be a list", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "queries.yml" => """
        include: queries/foo.yml
        """
      })

    assert_raise RuntimeError, ~r/include must be a list/, fn -> YAML.load(plugin) end
  end

  describe "shared: fragments" do
    test "@name resolves whole-value reject from same file", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "queries.yml" => """
          shared:
            no_match:
              sql: SELECT 1 WHERE :id = ''
              message: "no match for '{id}'"

          queries:
            a:
              description: q
              write: true
              returns: count
              params:
                id: { type: text }
              reject: @no_match
              sql: UPDATE t SET v = 1 WHERE id = :id
          """
        })

      {[%{reject: [r]}], _} = YAML.load(plugin)
      assert r.message == "no match for '{id}'"
    end

    test "@name list-element splices a list-valued fragment", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "queries.yml" => """
          shared:
            prefix_rejects:
              - sql: SELECT 1 WHERE :id = 'amb'
                message: "ambiguous '{id}'"
              - sql: SELECT 1 WHERE :id = ''
                message: "no match for '{id}'"

          queries:
            a:
              description: q
              write: true
              returns: count
              params:
                id: { type: text }
              reject:
                - @prefix_rejects
                - sql: SELECT 1 WHERE :id = 'extra'
                  message: "extra check on '{id}'"
              sql: UPDATE t SET v = 1 WHERE id = :id
          """
        })

      {[%{reject: rs}], _} = YAML.load(plugin)
      assert length(rs) == 3

      assert Enum.map(rs, & &1.message) == [
               "ambiguous '{id}'",
               "no match for '{id}'",
               "extra check on '{id}'"
             ]
    end

    test "shared merges across include files", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "queries.yml" => """
          include:
            - shared.yml
            - queries/*.yml
          """,
          "shared.yml" => """
          shared:
            no_match:
              sql: SELECT 1 WHERE :id = ''
              message: "no match for '{id}'"
          """,
          "queries/upd.yml" => """
          queries:
            upd:
              description: q
              write: true
              returns: count
              params:
                id: { type: text }
              reject: @no_match
              sql: UPDATE t SET v = 1 WHERE id = :id
          """
        })

      {[%{reject: [r]}], _} = YAML.load(plugin)
      assert r.message == "no match for '{id}'"
    end

    test "duplicate shared fragment across files raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "queries.yml" => """
          include:
            - extra.yml
          shared:
            dup:
              sql: SELECT 1
              message: a
          """,
          "extra.yml" => """
          shared:
            dup:
              sql: SELECT 1
              message: b
          """
        })

      assert_raise RuntimeError, ~r/duplicate shared fragment `@dup`/, fn ->
        YAML.load(plugin)
      end
    end

    test "shared must be a map", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "queries.yml" => """
          shared:
            - oops
          """
        })

      assert_raise RuntimeError, ~r/shared must be a map/, fn -> YAML.load(plugin) end
    end

    test "unknown @name raises with helpful message", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "queries.yml" => """
          shared:
            ok_fragment:
              sql: SELECT 1
              message: x

          queries:
            a:
              description: q
              returns: scalar
              sql: SELECT 1
              reject: @typo
          """
        })

      assert_raise ArgumentError, ~r/unknown fragment `@typo`.+@ok_fragment/s, fn ->
        YAML.load(plugin)
      end
    end

    test "fragment cycle raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "queries.yml" => """
          shared:
            a: "@b"
            b: "@a"

          queries:
            q1:
              description: q
              returns: scalar
              sql: SELECT 1
              reject: @a
          """
        })

      assert_raise ArgumentError, ~r/fragment cycle/, fn -> YAML.load(plugin) end
    end
  end
end
