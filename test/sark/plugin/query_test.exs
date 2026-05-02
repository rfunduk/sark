defmodule Sark.Plugin.QueryTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Query

  describe "parse!/2" do
    test "parses a minimal read query with defaults" do
      q =
        Query.parse!("recent", %{
          "description" => "Recent rows.",
          "returns" => "results",
          "sql" => "SELECT * FROM t LIMIT :n",
          "params" => %{
            "n" => %{"type" => "integer", "required" => false, "default" => 10}
          }
        })

      assert q.name == :recent
      assert q.returns == :results
      assert q.write == false
      assert q.internal == false
      assert [%{compiled_sql: "SELECT * FROM t LIMIT ?", param_order: [:n]}] = q.statements
      # default format for reads is :list
      assert q.format == :list
      [p] = q.params
      assert p.name == :n
      assert p.type == :integer
      assert p.required == false
      assert p.default == 10
    end

    test "parses internal: true" do
      q =
        Query.parse!("hidden", %{
          "description" => "Hidden.",
          "returns" => "results",
          "internal" => true,
          "sql" => "SELECT 1"
        })

      assert q.internal == true
    end

    test "raises on non-boolean internal" do
      assert_raise ArgumentError, ~r/internal must be boolean/, fn ->
        Query.parse!("hidden", %{
          "description" => "x",
          "returns" => "results",
          "internal" => "yes",
          "sql" => "SELECT 1"
        })
      end
    end

    test "parses write: true and applies json default format" do
      q =
        Query.parse!("ins", %{
          "description" => "Insert.",
          "returns" => "results",
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
        "returns" => "results",
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
          "returns" => "results",
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
          "returns" => "results",
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
          "returns" => "results",
          "sql" => "SELECT * FROM t WHERE n = :n",
          "params" => %{"n" => %{"type" => "integer", "enum" => [1, 2]}}
        })
      end
    end
  end

  describe "reject:" do
    test "parses a list of reject entries with sql + message" do
      q =
        Query.parse!("upd", %{
          "description" => "x",
          "returns" => "count",
          "write" => true,
          "sql" => "UPDATE t SET v = :v WHERE id = :id",
          "params" => %{
            "id" => %{"type" => "text"},
            "v" => %{"type" => "text"}
          },
          "reject" => [
            %{
              "sql" => "SELECT 1 FROM t WHERE id LIKE :id || '%' GROUP BY 1 HAVING COUNT(*) > 1",
              "message" => "ambiguous prefix '{id}'"
            },
            %{
              "sql" => "SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM t WHERE id LIKE :id || '%')",
              "message" => "no row matches '{id}'"
            }
          ]
        })

      assert [r1, r2] = q.reject
      assert r1.compiled_sql =~ "GROUP BY 1"
      assert r1.param_order == [:id]
      assert r1.message == "ambiguous prefix '{id}'"
      assert r2.message == "no row matches '{id}'"
    end

    test "defaults to empty list when reject not given" do
      q =
        Query.parse!("plain", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1"
        })

      assert q.reject == []
    end

    test "raises when reject entry references undeclared param" do
      assert_raise ArgumentError, ~r/SQL references :missing/, fn ->
        Query.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1",
          "reject" => [
            %{"sql" => "SELECT :missing", "message" => "x"}
          ]
        })
      end
    end

    test "raises when reject entry is missing sql or message" do
      assert_raise ArgumentError, ~r/sql is required/, fn ->
        Query.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1",
          "reject" => [%{"message" => "no sql"}]
        })
      end

      assert_raise ArgumentError, ~r/message is required/, fn ->
        Query.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1",
          "reject" => [%{"sql" => "SELECT 1"}]
        })
      end
    end

    test "raises when reject is neither map nor list" do
      assert_raise ArgumentError, ~r/reject must be a map or list of maps/, fn ->
        Query.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1",
          "reject" => "nope"
        })
      end
    end

    test "single map reject is normalized to list of one" do
      q =
        Query.parse!("upd", %{
          "description" => "x",
          "returns" => "count",
          "write" => true,
          "sql" => "UPDATE t SET v = :v WHERE id = :id",
          "params" => %{
            "id" => %{"type" => "text"},
            "v" => %{"type" => "text"}
          },
          "reject" => %{
            "sql" => "SELECT 1 WHERE :id = ''",
            "message" => "id required"
          }
        })

      assert [%{message: "id required"}] = q.reject
    end

    test "raises when reject sql is not a SELECT" do
      bad_sqls = [
        "INSERT INTO t VALUES (1)",
        "  update t set v = 1",
        "DELETE FROM t",
        "WITH x AS (SELECT 1) SELECT * FROM x",
        "PRAGMA foreign_keys = ON"
      ]

      for sql <- bad_sqls do
        assert_raise ArgumentError, ~r/reject sql must be a plain SELECT/, fn ->
          Query.parse!("bad", %{
            "description" => "x",
            "returns" => "results",
            "sql" => "SELECT 1",
            "reject" => [%{"sql" => sql, "message" => "x"}]
          })
        end
      end
    end
  end

  describe "coerce_params/2" do
    setup do
      q =
        Query.parse!("get", %{
          "description" => "Get one.",
          "returns" => "results",
          "sql" => "SELECT * FROM t WHERE k = :k AND n >= :n",
          "params" => %{
            "k" => %{"type" => "text"},
            "n" => %{"type" => "integer", "required" => false, "default" => 0}
          }
        })

      %{q: q}
    end

    test "coerces and applies defaults", %{q: q} do
      assert {:ok, %{k: "foo", n: 0}} = Query.coerce_params(q, %{"k" => "foo"})
      assert {:ok, %{k: "foo", n: 5}} = Query.coerce_params(q, %{"k" => "foo", "n" => 5})
    end

    test "coerces stringified integer", %{q: q} do
      assert {:ok, %{k: "foo", n: 7}} = Query.coerce_params(q, %{"k" => "foo", "n" => "7"})
    end

    test "missing required → validation error", %{q: q} do
      assert {:error, {:validation, errs}} = Query.coerce_params(q, %{"n" => 1})
      assert [%{param: :k, reason: "is required"}] = errs
    end

    test "wrong type → validation error", %{q: q} do
      assert {:error, {:validation, [%{param: :n, reason: "must be an integer"}]}} =
               Query.coerce_params(q, %{"k" => "x", "n" => "abc"})
    end

    test "enum violation" do
      q =
        Query.parse!("f", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT * FROM t WHERE feel = :feel",
          "params" => %{
            "feel" => %{"type" => "text", "enum" => ["easy", "right", "hard"]}
          }
        })

      assert {:error, {:validation, [%{param: :feel, reason: msg}]}} =
               Query.coerce_params(q, %{"feel" => "meh"})

      assert msg =~ "must be one of"
    end
  end

  describe "array + object params" do
    test "array of objects: parses, validates, JSON-encodes for bind" do
      q =
        Query.parse!("log_sets", %{
          "description" => "Bulk insert sets.",
          "returns" => "count",
          "write" => true,
          "sql" => """
          INSERT INTO sets (session_id, exercise_id, reps, feeling)
          SELECT :session_id,
                 json_extract(value, '$.exercise_id'),
                 json_extract(value, '$.reps'),
                 json_extract(value, '$.feeling')
          FROM json_each(:sets)
          """,
          "params" => %{
            "session_id" => %{"type" => "integer", "required" => true},
            "sets" => %{
              "type" => "array",
              "required" => true,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "exercise_id" => %{"type" => "integer", "required" => true},
                  "reps" => %{"type" => "integer", "required" => true},
                  "feeling" => %{
                    "type" => "text",
                    "required" => true,
                    "enum" => ["easy", "right", "hard"]
                  }
                }
              }
            }
          }
        })

      assert {:ok, %{session_id: 1, sets: json}} =
               Query.coerce_params(q, %{
                 "session_id" => 1,
                 "sets" => [
                   %{"exercise_id" => 5, "reps" => 8, "feeling" => "right"},
                   %{"exercise_id" => 5, "reps" => 6, "feeling" => "hard"}
                 ]
               })

      decoded = Jason.decode!(json)

      assert decoded == [
               %{"exercise_id" => 5, "reps" => 8, "feeling" => "right"},
               %{"exercise_id" => 5, "reps" => 6, "feeling" => "hard"}
             ]
    end

    test "validation error path includes index + field" do
      q =
        Query.parse!("x", %{
          "description" => "x",
          "returns" => "none",
          "write" => true,
          "sql" => "SELECT 1",
          "params" => %{
            "items" => %{
              "type" => "array",
              "required" => true,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "n" => %{"type" => "integer", "required" => true}
                }
              }
            }
          }
        })

      assert {:error, {:validation, [%{param: :items, reason: msg}]}} =
               Query.coerce_params(q, %{
                 "items" => [%{"n" => 1}, %{"n" => "bad"}]
               })

      assert msg =~ "[1].n must be an integer"
    end

    test "object with missing required property" do
      q =
        Query.parse!("x", %{
          "description" => "x",
          "returns" => "none",
          "write" => true,
          "sql" => "SELECT 1",
          "params" => %{
            "filter" => %{
              "type" => "object",
              "required" => true,
              "properties" => %{
                "kind" => %{"type" => "text", "required" => true},
                "limit" => %{"type" => "integer", "required" => false, "default" => 10}
              }
            }
          }
        })

      assert {:error, {:validation, [%{param: :filter, reason: msg}]}} =
               Query.coerce_params(q, %{"filter" => %{"limit" => 5}})

      assert msg =~ ".kind is required"
    end

    test "JSON Schema reflects nested array + object structure" do
      q =
        Query.parse!("log_sets", %{
          "description" => "x",
          "returns" => "none",
          "write" => true,
          "sql" => "SELECT 1",
          "params" => %{
            "sets" => %{
              "type" => "array",
              "required" => true,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "n" => %{"type" => "integer", "required" => true}
                }
              }
            }
          }
        })

      schema = Query.to_json_schema(q)
      sets = schema.properties["sets"]
      assert sets.type == "array"
      assert sets.items.type == "object"
      assert sets.items.properties["n"] == %{type: "integer"}
      assert sets.items.required == ["n"]
    end
  end

  describe "to_json_schema/1" do
    test "produces a valid object schema with required + types" do
      q =
        Query.parse!("get", %{
          "description" => "x",
          "returns" => "results",
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

  describe "boolean param type" do
    setup do
      q =
        Query.parse!("flag", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT * FROM t WHERE active = :active",
          "params" => %{"active" => %{"type" => "boolean"}}
        })

      %{q: q}
    end

    test "coerces true → 1, false → 0", %{q: q} do
      assert {:ok, %{active: 1}} = Query.coerce_params(q, %{"active" => true})
      assert {:ok, %{active: 0}} = Query.coerce_params(q, %{"active" => false})
    end

    test "rejects 1 / 0 / strings", %{q: q} do
      for bad <- [1, 0, "true", "false", "yes"] do
        assert {:error, {:validation, [%{param: :active, reason: reason}]}} =
                 Query.coerce_params(q, %{"active" => bad})

        assert reason =~ "must be true or false"
      end
    end

    test "JSON Schema emits boolean", %{q: q} do
      assert Query.to_json_schema(q).properties["active"] == %{type: "boolean"}
    end
  end
end
