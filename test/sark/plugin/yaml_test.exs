defmodule Sark.Plugin.YAMLTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Worker
  alias Sark.Plugin.YAML

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

  defp w_yaml(name) do
    """
    workers:
      #{name}:
        description: w
        model: m
        tools: [a]
        system: s
        prompt: p
        schedule: "0 3 * * *"
    """
  end

  test "absent plugin.yml → empty everything + default opts", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{})
    assert YAML.load(plugin) == {[], [], %{allow_sql: false, patchable: %{}}}
  end

  test "loads inline queries + workers", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "plugin.yml" => q_yaml("a") <> w_yaml("smoke")
      })

    {queries, workers, opts} = YAML.load(plugin)
    assert [%{name: :a}] = queries
    assert [%Worker{name: :smoke, model: "m", tools: ["a"]}] = workers
    assert opts == %{allow_sql: false, patchable: %{}}
  end

  describe "plugin-wide opts (entry only)" do
    test "allow_sql: true picked up", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "allow_sql: true\n" <> q_yaml("a")
        })

      {_, _, opts} = YAML.load(plugin)
      assert opts == %{allow_sql: true, patchable: %{}}
    end

    test "patchable maps table → cols", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          patchable:
            notes: [body, title]
            tasks: [body]
          queries: {}
          """
        })

      {_, _, opts} = YAML.load(plugin)
      assert opts.patchable == %{"notes" => ["body", "title"], "tasks" => ["body"]}
    end

    test "patchable defaults to empty map", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => q_yaml("a")})
      {_, _, opts} = YAML.load(plugin)
      assert opts.patchable == %{}
    end

    test "patchable rejects non-map", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "patchable: [notes]\nqueries: {}\n"})

      assert_raise RuntimeError, ~r/patchable must be a map/, fn -> YAML.load(plugin) end
    end

    test "patchable rejects bad table identifier", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "patchable:\n  \"bad-table\": [body]\nqueries: {}\n"
        })

      assert_raise RuntimeError, ~r/patchable table name/, fn -> YAML.load(plugin) end
    end

    test "patchable rejects bad column identifier", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "patchable:\n  notes: [\"bad col\"]\nqueries: {}\n"
        })

      assert_raise RuntimeError, ~r/patchable.notes entry/, fn -> YAML.load(plugin) end
    end

    test "patchable rejects non-list cols", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "patchable:\n  notes: body\nqueries: {}\n"})

      assert_raise RuntimeError, ~r/must be a list of column names/, fn ->
        YAML.load(plugin)
      end
    end

    test "allow_sql non-boolean raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "allow_sql: yes_please\nqueries: {}\n"})

      assert_raise RuntimeError, ~r/allow_sql must be boolean/, fn -> YAML.load(plugin) end
    end
  end

  describe "include" do
    test "literal files merge queries + workers", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" =>
            """
            include:
              - extra.yml
            """ <> q_yaml("a"),
          "extra.yml" => q_yaml("b") <> w_yaml("worker_b")
        })

      {queries, workers, _} = YAML.load(plugin)
      assert Enum.map(queries, & &1.name) == [:a, :b]
      assert Enum.map(workers, & &1.name) == [:worker_b]
    end

    test "one included file may carry queries: + workers: + shared: together", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - all.yml\n",
          "all.yml" => """
          shared:
            no_match:
              sql: SELECT 1 WHERE :id = ''
              message: "no match for '{id}'"

          queries:
            upd:
              description: q
              write: true
              returns: count
              params:
                id: { type: text }
              reject: @no_match
              sql: UPDATE t SET v = 1 WHERE id = :id

          workers:
            w1:
              description: w
              model: m
              tools: [a]
              system: s
              prompt: p
              schedule: "0 3 * * *"
          """
        })

      {[%{name: :upd, reject: [r]}], [%Worker{name: :w1}], _} = YAML.load(plugin)
      assert r.message == "no match for '{id}'"
    end

    test "glob expands + sorts", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - q/*.yml\n",
          "q/foo.yml" => q_yaml("foo"),
          "q/bar.yml" => q_yaml("bar")
        })

      {queries, _, _} = YAML.load(plugin)
      assert Enum.map(queries, & &1.name) == [:bar, :foo]
    end

    test "duplicate query across files raises naming both", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - extra.yml\n" <> q_yaml("dup"),
          "extra.yml" => q_yaml("dup")
        })

      assert_raise RuntimeError, ~r/duplicate query `dup`/, fn -> YAML.load(plugin) end
    end

    test "duplicate worker across files raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - extra.yml\n" <> w_yaml("same"),
          "extra.yml" => w_yaml("same")
        })

      assert_raise RuntimeError, ~r/duplicate worker `same`/, fn -> YAML.load(plugin) end
    end

    test "missing literal include raises", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => "include:\n  - missing.yml\n"})

      assert_raise RuntimeError, ~r/include `missing.yml` does not exist/, fn ->
        YAML.load(plugin)
      end
    end

    test "glob with no matches is fine", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "include:\n  - q/*.yml\n" <> q_yaml("a")})

      {queries, _, _} = YAML.load(plugin)
      assert [%{name: :a}] = queries
    end

    test "include must be a list", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => "include: q/foo.yml\n"})
      assert_raise RuntimeError, ~r/include must be a list/, fn -> YAML.load(plugin) end
    end

    test "allow_sql in an included file raises (entry-only)", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - extra.yml\n",
          "extra.yml" => "allow_sql: true\n" <> q_yaml("a")
        })

      assert_raise RuntimeError, ~r/allow_sql .*entry-only/, fn -> YAML.load(plugin) end
    end

    test "patchable in an included file merges", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "patchable:\n  notes: [body]\ninclude:\n  - extra.yml\n",
          "extra.yml" => "patchable:\n  tasks: [title]\n" <> q_yaml("a")
        })

      {_, _, opts} = YAML.load(plugin)
      assert opts.patchable == %{"notes" => ["body"], "tasks" => ["title"]}
    end

    test "duplicate patchable table across files raises naming both", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "patchable:\n  notes: [body]\ninclude:\n  - extra.yml\n",
          "extra.yml" => "patchable:\n  notes: [title]\n"
        })

      assert_raise RuntimeError, ~r/duplicate patchable table `notes`/, fn ->
        YAML.load(plugin)
      end
    end
  end

  describe "workers" do
    test "workers resolve @shared fragments too", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          shared:
            kv_tools: [list, get]

          workers:
            w:
              description: w
              model: m
              tools: @kv_tools
              system: s
              prompt: p
              schedule: "0 3 * * *"
          """
        })

      {_, [%Worker{name: :w, tools: tools}], _} = YAML.load(plugin)
      assert tools == ["list", "get"]
    end

    test "parses optional when: and load:", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
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
              schedule: "0 3 * * *"
          """
        })

      {_, [%Worker{name: :gated, when_sql: w, load_sql: l}], _} = YAML.load(plugin)
      assert w =~ "SELECT 1"
      assert l =~ "FROM x"
    end

    test "system: with mustache raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          workers:
            bad:
              description: g
              model: m
              tools: [a]
              system: |
                Today is {{date}}.
              prompt: p
              schedule: "0 3 * * *"
          """
        })

      assert_raise ArgumentError, ~r/system.*mustache/i, fn -> YAML.load(plugin) end
    end
  end

  describe "shared: fragments" do
    test "@name resolves whole-value reject", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
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

      {[%{reject: [r]}], _, _} = YAML.load(plugin)
      assert r.message == "no match for '{id}'"
    end

    test "shared merges across include files", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          include:
            - shared.yml
            - q/*.yml
          """,
          "shared.yml" => """
          shared:
            no_match:
              sql: SELECT 1 WHERE :id = ''
              message: "no match for '{id}'"
          """,
          "q/upd.yml" => """
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

      {[%{reject: [r]}], _, _} = YAML.load(plugin)
      assert r.message == "no match for '{id}'"
    end

    test "duplicate shared fragment across files raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
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

      assert_raise RuntimeError, ~r/duplicate shared fragment `dup`/, fn ->
        YAML.load(plugin)
      end
    end

    test "shared must be a map", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => "shared:\n  - oops\n"})
      assert_raise RuntimeError, ~r/`shared` must be a map/, fn -> YAML.load(plugin) end
    end

    test "unknown @name raises helpfully", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
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

    test "a fragment may reference another fragment", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          shared:
            base_reject:
              sql: SELECT 1 WHERE :id = ''
              message: "no '{id}'"
            alias_reject: "@base_reject"

          queries:
            a:
              description: q
              write: true
              returns: count
              params:
                id: { type: text }
              reject: @alias_reject
              sql: UPDATE t SET v = 1 WHERE id = :id
          """
        })

      {[%{reject: [r]}], _, _} = YAML.load(plugin)
      assert r.message == "no '{id}'"
    end

    test "fragment cycle raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
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
