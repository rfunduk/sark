defmodule Sark.Plugin.ToolTest do
  use ExUnit.Case, async: true

  alias Sark.Plugin.Tool

  describe "parse!/2" do
    test "parses a minimal read tool with defaults" do
      q =
        Tool.parse!("recent", %{
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
        Tool.parse!("hidden", %{
          "description" => "Hidden.",
          "returns" => "results",
          "internal" => true,
          "sql" => "SELECT 1"
        })

      assert q.internal == true
    end

    test "raises on non-boolean internal" do
      assert_raise ArgumentError, ~r/internal must be boolean/, fn ->
        Tool.parse!("hidden", %{
          "description" => "x",
          "returns" => "results",
          "internal" => "yes",
          "sql" => "SELECT 1"
        })
      end
    end

    test "parses write: true and applies json default format" do
      q =
        Tool.parse!("ins", %{
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

      assert Tool.parse!("a", Map.put(base, "format", "json")).format == :json
      assert Tool.parse!("a", Map.put(base, "format", "table")).format == :table
      assert Tool.parse!("a", Map.put(base, "format", "list")).format == :list

      tpl =
        Tool.parse!("a", Map.put(base, "format", %{"kind" => "template", "template" => "x"}))

      assert tpl.format == {:template, "x"}
    end

    test "parses enum on text param" do
      q =
        Tool.parse!("f", %{
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
        Tool.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT :nope FROM t"
        })
      end
    end

    test "raises on invalid returns" do
      assert_raise ArgumentError, ~r/returns must be one of/, fn ->
        Tool.parse!("bad", %{
          "description" => "x",
          "returns" => "tuples",
          "sql" => "SELECT 1"
        })
      end
    end

    test "raises on enum for non-text type" do
      assert_raise ArgumentError, ~r/enum is only valid for text/, fn ->
        Tool.parse!("bad", %{
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
        Tool.parse!("upd", %{
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
        Tool.parse!("plain", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1"
        })

      assert q.reject == []
    end

    test "raises when reject entry references undeclared param" do
      assert_raise ArgumentError, ~r/SQL references :missing/, fn ->
        Tool.parse!("bad", %{
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
        Tool.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1",
          "reject" => [%{"message" => "no sql"}]
        })
      end

      assert_raise ArgumentError, ~r/message is required/, fn ->
        Tool.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1",
          "reject" => [%{"sql" => "SELECT 1"}]
        })
      end
    end

    test "raises when reject is neither map nor list" do
      assert_raise ArgumentError, ~r/reject must be a map or list of maps/, fn ->
        Tool.parse!("bad", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1",
          "reject" => "nope"
        })
      end
    end

    test "single map reject is normalized to list of one" do
      q =
        Tool.parse!("upd", %{
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
          Tool.parse!("bad", %{
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
        Tool.parse!("get", %{
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
      assert {:ok, %{k: "foo", n: 0}} = Tool.coerce_params(q, %{"k" => "foo"})
      assert {:ok, %{k: "foo", n: 5}} = Tool.coerce_params(q, %{"k" => "foo", "n" => 5})
    end

    test "coerces stringified integer", %{q: q} do
      assert {:ok, %{k: "foo", n: 7}} = Tool.coerce_params(q, %{"k" => "foo", "n" => "7"})
    end

    test "missing required → validation error", %{q: q} do
      assert {:error, {:validation, errs}} = Tool.coerce_params(q, %{"n" => 1})
      assert [%{param: :k, reason: "is required"}] = errs
    end

    test "wrong type → validation error", %{q: q} do
      assert {:error, {:validation, [%{param: :n, reason: "must be an integer"}]}} =
               Tool.coerce_params(q, %{"k" => "x", "n" => "abc"})
    end

    test "enum violation" do
      q =
        Tool.parse!("f", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT * FROM t WHERE feel = :feel",
          "params" => %{
            "feel" => %{"type" => "text", "enum" => ["easy", "right", "hard"]}
          }
        })

      assert {:error, {:validation, [%{param: :feel, reason: msg}]}} =
               Tool.coerce_params(q, %{"feel" => "meh"})

      assert msg =~ "must be one of"
    end
  end

  describe "array + object params" do
    test "array of objects: parses, validates, JSON-encodes for bind" do
      q =
        Tool.parse!("log_sets", %{
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
               Tool.coerce_params(q, %{
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
        Tool.parse!("x", %{
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
               Tool.coerce_params(q, %{
                 "items" => [%{"n" => 1}, %{"n" => "bad"}]
               })

      assert msg =~ "[1].n must be an integer"
    end

    test "object with missing required property" do
      q =
        Tool.parse!("x", %{
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
               Tool.coerce_params(q, %{"filter" => %{"limit" => 5}})

      assert msg =~ ".kind is required"
    end

    test "JSON Schema reflects nested array + object structure" do
      q =
        Tool.parse!("log_sets", %{
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

      schema = Tool.to_json_schema(q)
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
        Tool.parse!("get", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT * FROM t WHERE k = :k AND n >= :n",
          "params" => %{
            "k" => %{"type" => "text", "description" => "the key"},
            "n" => %{"type" => "integer", "required" => false, "default" => 0}
          }
        })

      schema = Tool.to_json_schema(q)
      assert schema.type == "object"
      assert schema.required == ["k"]
      assert schema.properties["k"] == %{type: "string", description: "the key"}
      assert schema.properties["n"] == %{type: "integer"}
    end
  end

  describe "boolean param type" do
    setup do
      q =
        Tool.parse!("flag", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT * FROM t WHERE active = :active",
          "params" => %{"active" => %{"type" => "boolean"}}
        })

      %{q: q}
    end

    test "coerces true → 1, false → 0", %{q: q} do
      assert {:ok, %{active: 1}} = Tool.coerce_params(q, %{"active" => true})
      assert {:ok, %{active: 0}} = Tool.coerce_params(q, %{"active" => false})
    end

    test "rejects 1 / 0 / strings", %{q: q} do
      for bad <- [1, 0, "true", "false", "yes"] do
        assert {:error, {:validation, [%{param: :active, reason: reason}]}} =
                 Tool.coerce_params(q, %{"active" => bad})

        assert reason =~ "must be true or false"
      end
    end

    test "JSON Schema emits boolean", %{q: q} do
      assert Tool.to_json_schema(q).properties["active"] == %{type: "boolean"}
    end
  end

  describe "embed: modifier on text params" do
    defp search_entry(extra \\ %{}) do
      Map.merge(
        %{
          "description" => "Semantic search.",
          "returns" => "results",
          "params" => %{
            "q" => %{"type" => "text", "embed" => "q_vec"},
            "limit" => %{"type" => "integer", "default" => 10, "required" => false}
          },
          "sql" =>
            "SELECT m.row_pk, ve.distance FROM _embeddings_nodes ve " <>
              "JOIN _embeddings_nodes_meta m ON m.id = ve.rowid " <>
              "WHERE ve.embedding MATCH :q_vec AND k = :limit"
        },
        extra
      )
    end

    test "parses an embed-modified text param" do
      q = Tool.parse!("search_nodes", search_entry())

      assert Tool.embed_pairs(q) == [{:q, :q_vec}]

      q_param = Enum.find(q.params, &(&1.name == :q))
      assert q_param.type == :text
      assert q_param.embed == :q_vec

      [stmt] = q.statements
      # SQL stays exactly as the author wrote it; sark does not rewrite.
      assert stmt.raw_sql == search_entry()["sql"]

      # `:q_vec` shows up positionally in the compiled bind list even
      # though it's not a declared param — it's an embed sibling.
      assert stmt.param_order == [:q_vec, :limit]
    end

    test "JSON schema reports the param as a string (agent sees text)" do
      q = Tool.parse!("search_nodes", search_entry())
      assert q |> Tool.to_json_schema() |> get_in([:properties, "q"]) == %{type: "string"}
    end

    test "embed: rejected on non-text params" do
      bad =
        search_entry(%{
          "params" => %{
            "q" => %{"type" => "integer", "embed" => "q_vec"},
            "limit" => %{"type" => "integer", "default" => 10, "required" => false}
          }
        })

      assert_raise ArgumentError, ~r/embed: only valid on text params/, fn ->
        Tool.parse!("s", bad)
      end
    end

    test "embed: rejected when sibling name is not a valid identifier" do
      bad =
        search_entry(%{
          "params" => %{
            "q" => %{"type" => "text", "embed" => "bad name"},
            "limit" => %{"type" => "integer", "default" => 10, "required" => false}
          }
        })

      assert_raise ArgumentError, ~r/embed: `bad name` is not a valid SQL identifier/, fn ->
        Tool.parse!("s", bad)
      end
    end

    test "embed: rejected when sibling name collides with an existing param" do
      bad =
        search_entry(%{
          "params" => %{
            "q" => %{"type" => "text", "embed" => "limit"},
            "limit" => %{"type" => "integer", "default" => 10, "required" => false}
          }
        })

      assert_raise ArgumentError, ~r/conflicts with an existing param name/, fn ->
        Tool.parse!("s", bad)
      end
    end

    test "embed: rejected when two params declare the same sibling" do
      bad =
        search_entry(%{
          "params" => %{
            "q" => %{"type" => "text", "embed" => "v"},
            "q2" => %{"type" => "text", "embed" => "v"},
            "limit" => %{"type" => "integer", "default" => 10, "required" => false}
          },
          "sql" =>
            "SELECT m.row_pk FROM _embeddings_nodes ve " <>
              "JOIN _embeddings_nodes_meta m ON m.id = ve.rowid " <>
              "WHERE ve.embedding MATCH :v AND k = :limit"
        })

      assert_raise ArgumentError, ~r/two params declare the same embed sibling `v`/, fn ->
        Tool.parse!("s", bad)
      end
    end

    test "SQL referencing an unknown bind still fails" do
      bad =
        search_entry(%{
          "sql" =>
            "SELECT m.row_pk FROM _embeddings_nodes ve " <>
              "JOIN _embeddings_nodes_meta m ON m.id = ve.rowid " <>
              "WHERE ve.embedding MATCH :q_vec AND k = :limit AND score > :threshold"
        })

      assert_raise ArgumentError, ~r/:threshold but it is not declared/, fn ->
        Tool.parse!("s", bad)
      end
    end

    test "tool without any embed: modifier has empty embed_pairs" do
      q =
        Tool.parse!("plain", %{
          "description" => "x",
          "returns" => "results",
          "sql" => "SELECT 1"
        })

      assert Tool.embed_pairs(q) == []
    end
  end
end
