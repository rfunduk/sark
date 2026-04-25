defmodule Sark.Plugin.QueryTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Query

  describe "parse!/2" do
    test "parses a minimal read query with defaults" do
      q =
        Query.parse!("recent", %{
          "description" => "Recent rows.",
          "returns" => "rows",
          "sql" => "SELECT * FROM t LIMIT :n",
          "params" => %{
            "n" => %{"type" => "integer", "required" => false, "default" => 10}
          }
        })

      assert q.name == :recent
      assert q.returns == :rows
      assert q.write == false
      assert q.compiled_sql == "SELECT * FROM t LIMIT ?"
      assert q.param_order == [:n]
      # default format for reads is :list
      assert q.format == :list
      [p] = q.params
      assert p.name == :n
      assert p.type == :integer
      assert p.required == false
      assert p.default == 10
    end

    test "parses write: true and applies json default format" do
      q =
        Query.parse!("ins", %{
          "description" => "Insert.",
          "returns" => "one_row",
          "write" => true,
          "sql" => "INSERT INTO t(a) VALUES (:a) RETURNING id",
          "params" => %{"a" => %{"type" => "text"}}
        })

      assert q.write == true
      assert q.format == :json
    end

    test "parses explicit list/table/json/template formats" do
      base = %{
        "description" => "x",
        "returns" => "rows",
        "sql" => "SELECT 1"
      }

      assert Query.parse!("a", Map.put(base, "format", "json")).format == :json
      assert Query.parse!("a", Map.put(base, "format", "table")).format == :table
      assert Query.parse!("a", Map.put(base, "format", "list")).format == :list

      tpl =
        Query.parse!("a", Map.put(base, "format", %{"kind" => "template", "template" => "x"}))

      assert tpl.format == {:template, "x"}
    end

    test "parses enum on text param" do
      q =
        Query.parse!("f", %{
          "description" => "x",
          "returns" => "rows",
          "sql" => "SELECT * FROM t WHERE feel = :feel",
          "params" => %{
            "feel" => %{"type" => "text", "enum" => ["easy", "right", "hard"]}
          }
        })

      [p] = q.params
      assert p.enum == ["easy", "right", "hard"]
    end

    test "raises when SQL references undeclared param" do
      assert_raise ArgumentError, ~r/SQL references :nope but it is not declared/, fn ->
        Query.parse!("bad", %{
          "description" => "x",
          "returns" => "rows",
          "sql" => "SELECT :nope FROM t"
        })
      end
    end

    test "raises on invalid returns" do
      assert_raise ArgumentError, ~r/returns must be one of/, fn ->
        Query.parse!("bad", %{
          "description" => "x",
          "returns" => "tuples",
          "sql" => "SELECT 1"
        })
      end
    end

    test "raises on enum for non-text type" do
      assert_raise ArgumentError, ~r/enum is only valid for text/, fn ->
        Query.parse!("bad", %{
          "description" => "x",
          "returns" => "rows",
          "sql" => "SELECT * FROM t WHERE n = :n",
          "params" => %{"n" => %{"type" => "integer", "enum" => [1, 2]}}
        })
      end
    end
  end

  describe "validate_and_bind/2" do
    setup do
      q =
        Query.parse!("get", %{
          "description" => "Get one.",
          "returns" => "maybe_row",
          "sql" => "SELECT * FROM t WHERE k = :k AND n >= :n",
          "params" => %{
            "k" => %{"type" => "text"},
            "n" => %{"type" => "integer", "required" => false, "default" => 0}
          }
        })

      %{q: q}
    end

    test "binds in compiled order, applying defaults", %{q: q} do
      assert {:ok, ["foo", 0]} = Query.validate_and_bind(q, %{"k" => "foo"})
      assert {:ok, ["foo", 5]} = Query.validate_and_bind(q, %{"k" => "foo", "n" => 5})
    end

    test "coerces stringified integer", %{q: q} do
      assert {:ok, ["foo", 7]} = Query.validate_and_bind(q, %{"k" => "foo", "n" => "7"})
    end

    test "missing required → validation error", %{q: q} do
      assert {:error, {:validation, errs}} = Query.validate_and_bind(q, %{"n" => 1})
      assert [%{param: :k, reason: "is required"}] = errs
    end

    test "wrong type → validation error", %{q: q} do
      assert {:error, {:validation, [%{param: :n, reason: "must be an integer"}]}} =
               Query.validate_and_bind(q, %{"k" => "x", "n" => "abc"})
    end

    test "enum violation" do
      q =
        Query.parse!("f", %{
          "description" => "x",
          "returns" => "rows",
          "sql" => "SELECT * FROM t WHERE feel = :feel",
          "params" => %{
            "feel" => %{"type" => "text", "enum" => ["easy", "right", "hard"]}
          }
        })

      assert {:error, {:validation, [%{param: :feel, reason: msg}]}} =
               Query.validate_and_bind(q, %{"feel" => "meh"})

      assert msg =~ "must be one of"
    end
  end

  describe "to_json_schema/1" do
    test "produces a valid object schema with required + types" do
      q =
        Query.parse!("get", %{
          "description" => "x",
          "returns" => "rows",
          "sql" => "SELECT * FROM t WHERE k = :k AND n >= :n",
          "params" => %{
            "k" => %{"type" => "text", "description" => "the key"},
            "n" => %{"type" => "integer", "required" => false, "default" => 0}
          }
        })

      schema = Query.to_json_schema(q)
      assert schema.type == "object"
      assert schema.required == ["k"]
      assert schema.properties["k"] == %{type: "string", description: "the key"}
      assert schema.properties["n"] == %{type: "integer"}
    end
  end
end
