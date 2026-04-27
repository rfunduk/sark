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

  test "absent queries.yml → []", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{})
    assert YAML.load(plugin) == []
  end

  test "loads inline queries", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{"queries.yml" => q_yaml("a")})
    assert [%{name: :a}] = YAML.load(plugin)
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

    names = YAML.load(plugin) |> Enum.map(& &1.name)
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

    names = YAML.load(plugin) |> Enum.map(& &1.name)
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

    assert [%{name: :a}] = YAML.load(plugin)
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
end
