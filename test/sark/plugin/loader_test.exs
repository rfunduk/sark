defmodule Sark.Plugin.LoaderTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Loader
  alias Sark.Plugin.Spec

  @moduletag :tmp_dir

  defp write_plugin(dir, files) do
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)
    dir
  end

  test "loads schema.sql + metadata.yml", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "kv"), %{
        "schema.sql" => "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT);",
        "metadata.yml" => """
        title: KV
        tables:
          kv:
            description: Test
        """
      })

    spec = Loader.load!(plugin)

    assert %Spec{name: "kv"} = spec
    assert spec.dir == plugin
    assert spec.schema_sql =~ "CREATE TABLE kv"
    assert spec.metadata["title"] == "KV"
    assert get_in(spec.metadata, ["tables", "kv", "description"]) == "Test"
  end

  test "uses dir basename as plugin name", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "my_plugin"), %{
        "schema.sql" => "",
        "metadata.yml" => "title: x"
      })

    spec = Loader.load!(plugin)
    assert spec.name == "my_plugin"
  end

  test "raises when schema.sql missing", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "broken"), %{
        "metadata.yml" => "title: x"
      })

    assert_raise RuntimeError, ~r/missing required file `schema.sql`/, fn ->
      Loader.load!(plugin)
    end
  end

  test "raises when metadata.yml missing", %{tmp_dir: dir} do
    plugin =
      write_plugin(Path.join(dir, "broken"), %{
        "schema.sql" => "CREATE TABLE x(y TEXT);"
      })

    assert_raise RuntimeError, ~r/missing required file `metadata.yml`/, fn ->
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
end
