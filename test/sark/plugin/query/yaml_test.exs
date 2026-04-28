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
    assert YAML.load(plugin) == {[], %{allow_sql: false}}
  end

  test "loads inline queries", %{tmp_dir: dir} do
    plugin = write(Path.join(dir, "p"), %{"queries.yml" => q_yaml("a")})
    {queries, opts} = YAML.load(plugin)
    assert [%{name: :a}] = queries
    assert opts == %{allow_sql: false}
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
    assert opts == %{allow_sql: true}
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
end
