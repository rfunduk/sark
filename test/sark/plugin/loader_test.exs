defmodule Sark.Plugin.LoaderTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Loader
  alias Sark.Plugin.Spec

  @moduletag :tmp_dir

  defp write_plugin(dir, files) do
    File.mkdir_p!(dir)

    Enum.each(files, fn {name, body} ->
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end)

    dir
  end

  test "loads migrations/", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "kv"), %{
        "migrations/0001_initial.sql" => "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT);"
      })

    spec = Loader.load!(plugin)

    assert %Spec{name: "kv"} = spec
    assert spec.dir == plugin
    assert [%{version: 1, sql: sql}] = spec.migrations
    assert sql =~ "CREATE TABLE kv"
    assert spec.allow_sql == false
    assert spec.queries == []
  end

  test "queries.yml allow_sql flows into Spec", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "kv"), %{
        "migrations/0001_initial.sql" => "CREATE TABLE x(y TEXT);",
        "queries.yml" => """
        allow_sql: true
        queries: {}
        """
      })

    spec = Loader.load!(plugin)
    assert spec.allow_sql == true
  end

  test "uses dir basename as plugin name", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "my_plugin"), %{
        "migrations/0001_initial.sql" => "CREATE TABLE x(y TEXT);"
      })

    spec = Loader.load!(plugin)
    assert spec.name == "my_plugin"
  end

  test "raises when migrations/ missing", %{tmp_dir: dir} do
    plugin = write_plugin(Path.join(dir, "broken"), %{})

    assert_raise RuntimeError, ~r/missing required `migrations\/` directory/, fn ->
      Loader.load!(plugin)
    end
  end

  test "raises on non-directory path", %{tmp_dir: dir} do
    file = Path.join(dir, "notadir")
    File.write!(file, "x")

    assert_raise RuntimeError, ~r/not a directory/, fn ->
      Loader.load!(file)
    end
  end

  test "raises on bad migration filename", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "broken"), %{
        "migrations/initial.sql" => "CREATE TABLE x(y TEXT);"
      })

    assert_raise RuntimeError, ~r/bad migration filename/, fn ->
      Loader.load!(plugin)
    end
  end

  test "raises on version gap", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "broken"), %{
        "migrations/0001_a.sql" => "CREATE TABLE x(y TEXT);",
        "migrations/0003_c.sql" => "CREATE TABLE z(w TEXT);"
      })

    assert_raise RuntimeError, ~r/migration versions must be contiguous/, fn ->
      Loader.load!(plugin)
    end
  end

  test "raises on empty migrations dir", %{tmp_dir: dir} do
    plugin = Path.join(dir, "broken")
    File.mkdir_p!(Path.join(plugin, "migrations"))

    assert_raise RuntimeError, ~r/`migrations\/` is empty/, fn ->
      Loader.load!(plugin)
    end
  end
end
