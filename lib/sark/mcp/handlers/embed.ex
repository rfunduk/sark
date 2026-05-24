defmodule Sark.MCP.Handlers.Embed do
  @moduledoc """
  Built-in operator-facing tools for the embed surface.

  Registered automatically on every plugin that declares `embed:`. Not
  declared in `plugin.yml`. Two tools:

    * **`sark_embed_status`** — read-only snapshot of `_embed_queue`
      counts (per status, per table) + the configured embedder spec
      (`provider`, `model`, `dim`). For operators to see "is this
      plugin caught up?".

    * **`sark_embed_reindex(table)`** — drops all embeddings for one
      embed-configured table and enqueues every matching source row
      for re-embed. Used after a model/dim change, a bulk import, or
      when the operator believes the index is corrupt.

  No pause/resume in v1 — see jot `rag-builtin` for the reasoning
  (rare op edge cases, can ship later under the same prefix).
  """

  alias Phantom.Tool, as: Reply
  alias Sark.MCP.Telemetry
  alias Sark.Plugin.DB
  alias Sark.Plugin.Embed

  # ── tool specs (consumed by Registration) ────────────────────────────

  @doc "MCP tool specs for the embed admin tools."
  @spec tool_specs() :: [%{name: String.t(), description: String.t(), input_schema: map}]
  def tool_specs do
    [
      %{
        name: "sark_embed_status",
        description:
          "Snapshot of the embed queue for this plugin: counts per status, " <>
            "per table, plus the configured embedder (provider/model/dim).",
        input_schema: %{type: "object", properties: %{}, required: []}
      },
      %{
        name: "sark_embed_reindex",
        description:
          "Drop all embeddings + meta for one embed-configured table and " <>
            "enqueue every matching source row for re-embed. Use after a " <>
            "model/dim change, bulk import, or suspected index corruption.",
        input_schema: %{
          type: "object",
          required: ["table"],
          properties: %{
            "table" => %{
              type: "string",
              description: "Embed-configured table name to reindex."
            }
          }
        }
      }
    ]
  end

  # ── status ───────────────────────────────────────────────────────────

  @spec status(String.t(), map, term) :: {:reply, map, term}
  def status(plugin, raw_params, session) do
    Telemetry.with_logging("#{plugin}.sark_embed_status", raw_params, fn ->
      payload = build_status(plugin)
      {:reply, Reply.text(Jason.encode!(payload)), session}
    end)
  end

  defp build_status(plugin) do
    {:ok, _, by_status} =
      DB.read(
        plugin,
        "SELECT status, COUNT(*) AS count FROM _embed_queue GROUP BY status",
        []
      )

    {:ok, _, by_table} =
      DB.read(
        plugin,
        "SELECT table_name, status, COUNT(*) AS count " <>
          "FROM _embed_queue GROUP BY table_name, status",
        []
      )

    {:ok, _, [%{"last_enqueued_at" => last_enqueued}]} =
      DB.read(
        plugin,
        "SELECT MAX(enqueued_at) AS last_enqueued_at FROM _embed_queue",
        []
      )

    embedder =
      try do
        case Sark.Boot.load_config!().embedder do
          nil ->
            nil

          spec ->
            %{
              "provider" => spec.provider,
              "model" => spec.model,
              "dim" => spec.dim
            }
        end
      rescue
        # If the config isn't reachable (test harness without
        # SARK_CONFIG), report `embedder: nil` rather than crashing
        # the status tool — operators still get queue counts.
        _ -> nil
      end

    %{
      "plugin" => plugin,
      "queue" => %{
        "by_status" => format_status_counts(by_status),
        "by_table" => Enum.map(by_table, &Map.take(&1, ["table_name", "status", "count"]))
      },
      "last_enqueued_at" => last_enqueued,
      "embedder" => embedder
    }
  end

  defp format_status_counts(rows) do
    Map.new(rows, fn row -> {row["status"], row["count"]} end)
  end

  # ── reindex ──────────────────────────────────────────────────────────

  @spec reindex(String.t(), map, term) :: {:reply, map, term}
  def reindex(plugin, raw_params, session) do
    Telemetry.with_logging("#{plugin}.sark_embed_reindex", raw_params, fn ->
      with {:ok, table} <- fetch_table(raw_params),
           {:ok, embed} <- find_embed(plugin, table),
           {:ok, count} <- do_reindex(plugin, embed) do
        {:reply, Reply.text(Jason.encode!(%{"table" => table, "enqueued" => count})), session}
      else
        {:error, msg} -> {:reply, Reply.error(msg), session}
      end
    end)
  end

  defp fetch_table(%{"table" => t}) when is_binary(t) and t != "", do: {:ok, t}
  defp fetch_table(_), do: {:error, "validation: `table` is required (string)"}

  defp find_embed(plugin, table) do
    case Sark.MCP.Registry.get_spec(plugin) do
      {:ok, spec} ->
        case Map.get(spec.embed, table) do
          nil -> {:error, "validation: `#{table}` is not an embed-configured table"}
          %Embed{} = embed -> {:ok, embed}
        end

      :error ->
        {:error, "internal: plugin `#{plugin}` is not registered"}
    end
  end

  defp do_reindex(plugin, %Embed{table: table, pk: pk, where: where}) do
    # Wipe derived state for this table, then enqueue every matching
    # source row. Drain rebuilds via the normal INSERT path.
    case DB.txn(plugin, fn conn ->
           Exqlite.query!(conn, "DELETE FROM _embeddings_#{table}_meta", [])
           Exqlite.query!(conn, "DELETE FROM _embeddings_#{table}", [])
           Exqlite.query!(conn, "DELETE FROM _embed_queue WHERE table_name = ?", [table])

           enqueue_sql = """
           INSERT INTO _embed_queue (table_name, row_pk, op, enqueued_at)
           SELECT '#{table}', #{pk}, 'INSERT',
                  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
           FROM #{table}#{if where, do: " WHERE #{where}", else: ""}
           """

           Exqlite.query!(conn, enqueue_sql, [])
           |> Map.fetch!(:num_rows) || 0
         end) do
      {:ok, _} ->
        # num_rows of the SELECT-INSERT isn't always reliable across
        # exqlite versions — count post-write instead.
        {:ok, _, [%{"count" => c}]} =
          DB.read(
            plugin,
            "SELECT COUNT(*) AS count FROM _embed_queue " <>
              "WHERE table_name = ? AND status = 'pending'",
            [table]
          )

        {:ok, c}

      {:error, reason} ->
        {:error, "internal: reindex failed: #{inspect(reason)}"}
    end
  end
end
