defmodule Sark.Plugin.YAMLTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Pipeline
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

  defp t_yaml(name) do
    """
    tools:
      #{name}:
        description: q
        returns: scalar
        sql: SELECT 1
    """
  end

  defp p_yaml(name) do
    """
    pipelines:
      #{name}:
        description: p
        schedule: "0 3 * * *"
        steps:
          - shell: echo hi
    """
  end

  test "absent plugin.yml → empty everything + default opts", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{})
    assert YAML.load(plugin) == {[], [], %{allow_sql: false, patchable: %{}, embed: %{}}}
  end

  test "loads inline tools + pipelines", %{tmp_dir: dir} do
    plugin =
      write(Path.join(dir, "p"), %{
        "plugin.yml" => t_yaml("a") <> p_yaml("smoke")
      })

    {tools, pipelines, opts} = YAML.load(plugin)
    assert [%{name: :a}] = tools
    assert [%Pipeline{name: :smoke, steps: [%{kind: :shell}]}] = pipelines
    assert opts == %{allow_sql: false, patchable: %{}, embed: %{}}
  end

  describe "plugin-wide opts (entry only)" do
    test "allow_sql: true picked up", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "allow_sql: true\n" <> t_yaml("a")
        })

      {_, _, opts} = YAML.load(plugin)
      assert opts == %{allow_sql: true, patchable: %{}, embed: %{}}
    end

    test "patchable maps table → cols", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          patchable:
            notes: [body, title]
            tasks: [body]
          tools: {}
          """
        })

      {_, _, opts} = YAML.load(plugin)
      assert opts.patchable == %{"notes" => ["body", "title"], "tasks" => ["body"]}
    end

    test "patchable defaults to empty map", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => t_yaml("a")})
      {_, _, opts} = YAML.load(plugin)
      assert opts.patchable == %{}
    end

    test "patchable rejects non-map", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "patchable: [notes]\ntools: {}\n"})

      assert_raise RuntimeError, ~r/patchable must be a map/, fn -> YAML.load(plugin) end
    end

    test "patchable rejects bad table identifier", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "patchable:\n  \"bad-table\": [body]\ntools: {}\n"
        })

      assert_raise RuntimeError, ~r/patchable table name/, fn -> YAML.load(plugin) end
    end

    test "patchable rejects bad column identifier", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "patchable:\n  notes: [\"bad col\"]\ntools: {}\n"
        })

      assert_raise RuntimeError, ~r/patchable.notes entry/, fn -> YAML.load(plugin) end
    end

    test "patchable rejects non-list cols", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "patchable:\n  notes: body\ntools: {}\n"})

      assert_raise RuntimeError, ~r/must be a list of column names/, fn ->
        YAML.load(plugin)
      end
    end

    test "allow_sql non-boolean raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "allow_sql: yes_please\ntools: {}\n"})

      assert_raise RuntimeError, ~r/allow_sql must be boolean/, fn -> YAML.load(plugin) end
    end
  end

  describe "include" do
    test "literal files merge tools + pipelines", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" =>
            """
            include:
              - extra.yml
            """ <> t_yaml("a"),
          "extra.yml" => t_yaml("b") <> p_yaml("p_b")
        })

      {tools, pipelines, _} = YAML.load(plugin)
      assert Enum.map(tools, & &1.name) == [:a, :b]
      assert Enum.map(pipelines, & &1.name) == [:p_b]
    end

    test "one included file may carry tools: + pipelines: + shared: together", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - all.yml\n",
          "all.yml" => """
          shared:
            no_match:
              sql: SELECT 1 WHERE :id = ''
              message: "no match for '{id}'"

          tools:
            upd:
              description: q
              write: true
              returns: count
              params:
                id: { type: text }
              reject: @no_match
              sql: UPDATE t SET v = 1 WHERE id = :id

          pipelines:
            p1:
              description: p
              schedule: "0 3 * * *"
              steps:
                - shell: echo hi
          """
        })

      {[%{name: :upd, reject: [r]}], [%Pipeline{name: :p1}], _} = YAML.load(plugin)
      assert r.message == "no match for '{id}'"
    end

    test "glob expands + sorts", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - q/*.yml\n",
          "q/foo.yml" => t_yaml("foo"),
          "q/bar.yml" => t_yaml("bar")
        })

      {tools, _, _} = YAML.load(plugin)
      assert Enum.map(tools, & &1.name) == [:bar, :foo]
    end

    test "duplicate tool across files raises naming both", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - extra.yml\n" <> t_yaml("dup"),
          "extra.yml" => t_yaml("dup")
        })

      assert_raise RuntimeError, ~r/duplicate tool `dup`/, fn -> YAML.load(plugin) end
    end

    test "duplicate pipeline across files raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - extra.yml\n" <> p_yaml("same"),
          "extra.yml" => p_yaml("same")
        })

      assert_raise RuntimeError, ~r/duplicate pipeline `same`/, fn -> YAML.load(plugin) end
    end

    test "missing literal include raises", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => "include:\n  - missing.yml\n"})

      assert_raise RuntimeError, ~r/include `missing.yml` does not exist/, fn ->
        YAML.load(plugin)
      end
    end

    test "glob with no matches is fine", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "include:\n  - q/*.yml\n" <> t_yaml("a")})

      {tools, _, _} = YAML.load(plugin)
      assert [%{name: :a}] = tools
    end

    test "include must be a list", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => "include: q/foo.yml\n"})
      assert_raise RuntimeError, ~r/include must be a list/, fn -> YAML.load(plugin) end
    end

    test "allow_sql in an included file raises (entry-only)", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "include:\n  - extra.yml\n",
          "extra.yml" => "allow_sql: true\n" <> t_yaml("a")
        })

      assert_raise RuntimeError, ~r/allow_sql .*entry-only/, fn -> YAML.load(plugin) end
    end

    test "patchable in an included file merges", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => "patchable:\n  notes: [body]\ninclude:\n  - extra.yml\n",
          "extra.yml" => "patchable:\n  tasks: [title]\n" <> t_yaml("a")
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

  describe "pipelines" do
    test "pipelines resolve @shared fragments", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          shared:
            kv_tools: [list, get]

          pipelines:
            p:
              description: p
              schedule: "0 3 * * *"
              steps:
                - llm:
                    model: m
                    tools: @kv_tools
                    system: s
                    prompt: p
                    max_turns: 2
          """
        })

      {_, [%Pipeline{name: :p, steps: [%{kind: :llm, tools: tools}]}], _} = YAML.load(plugin)
      assert tools == ["list", "get"]
    end

    test "parses optional when:", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          pipelines:
            gated:
              description: g
              schedule: "0 3 * * *"
              when: |
                SELECT 1
              steps:
                - shell: echo hi
          """
        })

      {_, [%Pipeline{name: :gated, when_sql: w}], _} = YAML.load(plugin)
      assert w =~ "SELECT 1"
    end

    test "llm system: with mustache raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          pipelines:
            bad:
              description: g
              schedule: "0 3 * * *"
              steps:
                - llm:
                    model: m
                    tools: []
                    system: |
                      Today is {{date}}.
                    prompt: p
                    max_turns: 2
          """
        })

      assert_raise ArgumentError, ~r/system.*mustache/i, fn -> YAML.load(plugin) end
    end

    test "unscheduled pipelines load with schedule: nil", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          pipelines:
            manual:
              description: m
              steps:
                - shell: echo hi
          """
        })

      {_, [%Pipeline{name: :manual, schedule: nil}], _} = YAML.load(plugin)
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

          tools:
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
          tools:
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

          tools:
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

          tools:
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

          tools:
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

  describe "embed" do
    test "embed defaults to empty map", %{tmp_dir: dir} do
      plugin = write(Path.join(dir, "p"), %{"plugin.yml" => t_yaml("a")})
      {_, _, opts} = YAML.load(plugin)
      assert opts.embed == %{}
    end

    test "inline embed parses into table → spec map", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          embed:
            nodes:
              fields: [summary, body]
              chunk: { size: 512, overlap: 64 }
              where: "status != 'archived'"
            docs:
              fields: [content]
              pk: uri
          tools: {}
          """
        })

      {_, _, opts} = YAML.load(plugin)

      assert %{
               "nodes" => %Sark.Plugin.Embed{
                 fields: ["summary", "body"],
                 pk: "id",
                 chunk: %{size: 512, overlap: 64},
                 where: "status != 'archived'"
               },
               "docs" => %Sark.Plugin.Embed{
                 fields: ["content"],
                 pk: "uri",
                 chunk: nil,
                 where: nil
               }
             } = opts.embed
    end

    test "embed merges across includes", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          include:
            - more.yml
          embed:
            nodes:
              fields: [body]
          """,
          "more.yml" => """
          embed:
            docs:
              fields: [content]
          """
        })

      {_, _, opts} = YAML.load(plugin)
      assert Map.keys(opts.embed) |> Enum.sort() == ["docs", "nodes"]
    end

    test "duplicate embed.<table> across files raises", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          include:
            - extra.yml
          embed:
            nodes:
              fields: [body]
          """,
          "extra.yml" => """
          embed:
            nodes:
              fields: [summary]
          """
        })

      assert_raise RuntimeError, ~r/duplicate embed table `nodes`/, fn ->
        YAML.load(plugin)
      end
    end

    test "embed rejects non-map", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{"plugin.yml" => "embed: [nodes]\ntools: {}\n"})

      assert_raise RuntimeError, ~r/embed must be a map/, fn -> YAML.load(plugin) end
    end

    test "embed propagates per-table validation errors", %{tmp_dir: dir} do
      plugin =
        write(Path.join(dir, "p"), %{
          "plugin.yml" => """
          embed:
            nodes:
              chunk: { size: 1024, overlap: 128 }
          """
        })

      assert_raise RuntimeError, ~r/embed\.nodes\.fields is required/, fn ->
        YAML.load(plugin)
      end
    end
  end
end
