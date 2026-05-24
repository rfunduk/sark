defmodule Sark.Plugin.SyntheticTools do
  @moduledoc """
  Tools that sark synthesises for a plugin at registration time —
  things plugin author opts into via config (e.g. `embed:`) but
  shouldn't have to write the SQL for.

  Currently:

    * **`sark_vec_<X>`** — semantic search per `embed:` table. Built
      from a templated vec0 KNN query against `_embeddings_<X>` +
      `_embeddings_<X>_meta`, joined to the source table on its
      declared `pk`. Aggregates best-chunk-per-row via ROW_NUMBER.
      Returns source row + `score` + `chunk_preview`.

  Synthetic tools look just like `plugin.yml`-declared tools after
  this module is done — they go through the same `Tool.parse!/2`
  validation and dispatch. The only difference is they bypass the
  reserved-name check in registration (sark owns the `sark_` prefix).
  """

  alias Sark.Plugin.Embed
  alias Sark.Plugin.Spec
  alias Sark.Plugin.Tool

  @spec for_spec(Spec.t()) :: [Tool.t()]
  def for_spec(%Spec{embed: embed}) when map_size(embed) == 0, do: []

  def for_spec(%Spec{embed: embed}) do
    embed
    |> Map.values()
    |> Enum.map(&build_vec_tool/1)
  end

  defp build_vec_tool(%Embed{table: table, pk: pk}) do
    name = "sark_vec_#{table}"

    sql = """
    WITH ranked AS (
      SELECT
        m.row_pk,
        m.chunk_text,
        ve.distance,
        ROW_NUMBER() OVER (PARTITION BY m.row_pk ORDER BY ve.distance) AS rn
      FROM _embeddings_#{table} ve
      JOIN _embeddings_#{table}_meta m ON m.id = ve.rowid
      WHERE ve.embedding MATCH :q_vec AND k = :limit
    )
    SELECT t.*,
           r.chunk_text AS chunk_preview,
           r.distance   AS score
    FROM ranked r
    JOIN #{table} t ON t.#{pk} = r.row_pk
    WHERE r.rn = 1
    ORDER BY r.distance
    """

    Tool.parse!(name, %{
      "description" =>
        "Semantic (vector) search over `#{table}`. Returns each matching " <>
          "source row with its best-scoring chunk as `chunk_preview` plus " <>
          "the `score` (lower = closer match). `q` is the natural-language " <>
          "query — sark embeds it before search.",
      "returns" => "results",
      # JSON is the right surface for an agent calling vector search —
      # the results are structured records (id, body, score, etc),
      # not a flat list of strings.
      "format" => "json",
      "params" => %{
        "q" => %{
          "type" => "text",
          "embed" => "q_vec",
          "description" => "Natural-language query. Embedded before search."
        },
        "limit" => %{
          "type" => "integer",
          "required" => false,
          "default" => 10,
          "description" =>
            "Upper bound on chunks fetched from vec0. Final row count may " <>
              "be smaller after best-chunk-per-row dedup."
        }
      },
      "sql" => sql
    })
  end
end
