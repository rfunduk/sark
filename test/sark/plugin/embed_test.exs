defmodule Sark.Plugin.EmbedTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Embed

  @src "plugin.yml"

  describe "parse!/3" do
    test "minimal valid spec defaults pk to id" do
      raw = %{"fields" => ["summary", "body"]}

      assert %Embed{
               table: "nodes",
               fields: ["summary", "body"],
               pk: "id",
               chunk: nil,
               where: nil
             } = Embed.parse!("nodes", raw, @src)
    end

    test "custom pk" do
      raw = %{"fields" => ["body"], "pk" => "uri"}
      assert %Embed{pk: "uri"} = Embed.parse!("docs", raw, @src)
    end

    test "chunk block parses" do
      raw = %{
        "fields" => ["body"],
        "chunk" => %{"size" => 512, "overlap" => 64}
      }

      assert %Embed{chunk: %{size: 512, overlap: 64}} = Embed.parse!("docs", raw, @src)
    end

    test "where predicate parses" do
      raw = %{"fields" => ["body"], "where" => "status != 'archived'"}
      assert %Embed{where: "status != 'archived'"} = Embed.parse!("docs", raw, @src)
    end

    test "rejects missing fields" do
      assert_raise RuntimeError, ~r/fields is required/, fn ->
        Embed.parse!("docs", %{}, @src)
      end
    end

    test "rejects empty fields list" do
      assert_raise RuntimeError, ~r/fields must be non-empty/, fn ->
        Embed.parse!("docs", %{"fields" => []}, @src)
      end
    end

    test "rejects non-list fields" do
      assert_raise RuntimeError, ~r/fields must be a list/, fn ->
        Embed.parse!("docs", %{"fields" => "body"}, @src)
      end
    end

    test "rejects non-identifier field name" do
      assert_raise RuntimeError, ~r/fields entry .* invalid/, fn ->
        Embed.parse!("docs", %{"fields" => ["body!"]}, @src)
      end
    end

    test "rejects duplicate field" do
      assert_raise RuntimeError, ~r/duplicate column `body`/, fn ->
        Embed.parse!("docs", %{"fields" => ["body", "body"]}, @src)
      end
    end

    test "rejects non-identifier table name" do
      assert_raise RuntimeError, ~r/embed table name .* invalid/, fn ->
        Embed.parse!("bad name", %{"fields" => ["body"]}, @src)
      end
    end

    test "rejects non-identifier pk" do
      assert_raise RuntimeError, ~r/pk .* invalid/, fn ->
        Embed.parse!("docs", %{"fields" => ["body"], "pk" => "1id"}, @src)
      end
    end

    test "rejects chunk overlap >= size" do
      raw = %{
        "fields" => ["body"],
        "chunk" => %{"size" => 128, "overlap" => 128}
      }

      assert_raise RuntimeError, ~r/overlap must be < size/, fn ->
        Embed.parse!("docs", raw, @src)
      end
    end

    test "rejects non-positive chunk size" do
      raw = %{"fields" => ["body"], "chunk" => %{"size" => 0, "overlap" => 0}}

      assert_raise RuntimeError, ~r/chunk\.size must be positive/, fn ->
        Embed.parse!("docs", raw, @src)
      end
    end

    test "rejects non-string where" do
      assert_raise RuntimeError, ~r/where must be a non-empty string/, fn ->
        Embed.parse!("docs", %{"fields" => ["body"], "where" => 123}, @src)
      end
    end

    test "rejects unknown keys" do
      raw = %{"fields" => ["body"], "model" => "voyage-3"}

      assert_raise RuntimeError, ~r/unknown keys: model/, fn ->
        Embed.parse!("docs", raw, @src)
      end
    end

    test "rejects non-map spec" do
      assert_raise RuntimeError, ~r/must be a map/, fn ->
        Embed.parse!("docs", "fields", @src)
      end
    end
  end
end
