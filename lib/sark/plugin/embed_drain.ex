defmodule Sark.Plugin.EmbedDrain do
  @moduledoc """
  Per-plugin background worker that drains `_embed_queue` into vector
  storage. Started in the plugin supervision tree when `Spec.embed` is
  non-empty. **Not** user-visible — does not appear in
  `sark_pipelines_list`. Operator-facing surface lives in dedicated
  `sark_embed_*` built-ins (status / pause / resume / reindex).

  Loop:

    1. Tick (idle 5s / busy 50ms).
    2. `SELECT … FROM _embed_queue WHERE status='pending' ORDER BY id
       LIMIT N`. Default N=100.
    3. For each row: dispatch on op + table → load source row → chunk
       embedded fields → skip-if-unchanged via `content_hash` → batch
       embed remaining chunks → upsert vectors + meta → delete queue
       row. All inside one writer-pool tx so a crash mid-batch leaves
       the queue row pending and the partial writes rolled back.
    4. On failure: bump `attempts`, set `last_error`, exponential
       backoff. After `@max_attempts` escalate to `status='failed'`.

  Embedding cost optimization: each chunk has a `content_hash`
  (sha256 of the chunk text). On UPDATE the drain compares hashes
  against existing `_embeddings_<table>_meta` rows for the same
  `row_pk` — only changed chunks re-embed.
  """

  use GenServer
  require Logger

  alias Exqlite.Result
  alias Sark.Embedder
  alias Sark.Embedder.Config, as: EmbedderConfig
  alias Sark.Plugin.DB
  alias Sark.Plugin.Embed

  @default_batch_size 100
  @idle_tick_ms 5_000
  @busy_tick_ms 50
  @max_attempts 5
  @backoff_base_ms 1_000

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :plugin,
      :embed,
      :embedder,
      :embedder_impl,
      :batch_size,
      :max_attempts,
      :backoff_base_ms
    ]
    defstruct [
      :plugin,
      :embed,
      :embedder,
      :embedder_impl,
      :batch_size,
      :max_attempts,
      :backoff_base_ms
    ]
  end

  # ── public API ───────────────────────────────────────────────────────

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :plugin)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts) do
    plugin = Keyword.fetch!(opts, :plugin)
    GenServer.start_link(__MODULE__, opts, name: registered_name(plugin))
  end

  @spec registered_name(String.t()) :: atom
  def registered_name(plugin), do: :"sark_embed_drain_#{plugin}"

  @doc "Synchronously drain one batch. For tests + manual triggers."
  @spec drain_now(String.t()) :: {:ok, non_neg_integer()}
  def drain_now(plugin) do
    GenServer.call(registered_name(plugin), :drain_now, 30_000)
  end

  # ── lifecycle ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %State{
      plugin: Keyword.fetch!(opts, :plugin),
      embed: Keyword.fetch!(opts, :embed),
      embedder: Keyword.fetch!(opts, :embedder),
      embedder_impl: Keyword.get(opts, :embedder_impl, Embedder),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      max_attempts: Keyword.get(opts, :max_attempts, @max_attempts),
      backoff_base_ms: Keyword.get(opts, :backoff_base_ms, @backoff_base_ms)
    }

    schedule_tick(:idle)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    case drain_batch(state) do
      0 -> schedule_tick(:idle)
      _ -> schedule_tick(:busy)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:drain_now, _from, state) do
    {:reply, {:ok, drain_batch(state)}, state}
  end

  defp schedule_tick(:idle), do: Process.send_after(self(), :tick, @idle_tick_ms)
  defp schedule_tick(:busy), do: Process.send_after(self(), :tick, @busy_tick_ms)

  # ── drain loop ───────────────────────────────────────────────────────

  defp drain_batch(state) do
    case fetch_pending(state) do
      [] ->
        0

      rows ->
        Enum.each(rows, fn row -> process_row(state, row) end)
        length(rows)
    end
  end

  defp fetch_pending(%State{plugin: plugin, batch_size: n}) do
    sql = """
    SELECT id, table_name, row_pk, op, attempts
    FROM _embed_queue
    WHERE status = 'pending'
    ORDER BY id
    LIMIT ?
    """

    case DB.read(plugin, sql, [n]) do
      {:ok, _cols, rows} ->
        rows

      {:error, reason} ->
        raise "embed drain (#{plugin}): fetch pending failed: #{inspect(reason)}"
    end
  end

  defp process_row(state, row) do
    qid = row["id"]
    table = row["table_name"]
    op = row["op"]
    row_pk = row["row_pk"]
    attempts = row["attempts"] || 0

    case Map.get(state.embed, table) do
      nil ->
        # Embed config dropped between enqueue + drain — orphan
        # cleanup in EmbedMigrator already wiped derived tables for
        # this table; just discard the queue row.
        delete_queue_row(state.plugin, qid)

      %Embed{} = embed ->
        try do
          do_process(state, embed, op, row_pk)
          delete_queue_row(state.plugin, qid)
        rescue
          e -> record_failure(state, qid, attempts, Exception.message(e))
        end
    end
  end

  # ── per-row work ─────────────────────────────────────────────────────

  defp do_process(state, %Embed{table: table}, "DELETE", row_pk) do
    delete_row_vectors(state.plugin, table, row_pk)
  end

  defp do_process(state, %Embed{} = embed, op, row_pk) when op in ["INSERT", "UPDATE"] do
    case load_source_row(state.plugin, embed, row_pk) do
      nil ->
        # Row gone (deleted, or no longer matches `where:`). Treat as
        # delete — drop any vectors we have for it.
        delete_row_vectors(state.plugin, embed.table, row_pk)

      row ->
        rebuild_embeddings(state, embed, row_pk, row)
    end
  end

  defp load_source_row(plugin, %Embed{table: t, pk: pk, fields: fields, where: where}, row_pk) do
    cols = Enum.join([pk | fields], ", ")
    sql = "SELECT #{cols} FROM #{t} WHERE #{pk} = ?" <> maybe_where(where) <> " LIMIT 1"

    case DB.read(plugin, sql, [row_pk]) do
      {:ok, _cols, [row]} -> row
      {:ok, _cols, []} -> nil
      {:error, reason} -> raise "load source row #{t}/#{row_pk} failed: #{inspect(reason)}"
    end
  end

  defp maybe_where(nil), do: ""
  defp maybe_where(""), do: ""
  defp maybe_where(predicate), do: " AND (#{predicate})"

  defp rebuild_embeddings(state, embed, row_pk, source_row) do
    chunks = build_chunks(state, embed, source_row)
    existing = load_existing_meta(state.plugin, embed.table, row_pk)
    cfg_hash = config_hash(embed, state.embedder)

    {_kept, to_embed} = diff_chunks(chunks, existing, cfg_hash)

    to_embed_texts = Enum.map(to_embed, & &1.text)

    vectors =
      case to_embed_texts do
        [] -> []
        texts -> call_embedder!(state, texts)
      end

    {:ok, _} =
      DB.txn(state.plugin, fn conn ->
        # Drop only entries that are stale: existing meta rows whose
        # (field, idx) is gone from the current source row, OR whose
        # content_hash/config_hash no longer matches. Kept entries
        # remain in place — no re-embed, no vec0 churn.
        delete_stale_in_conn(conn, embed.table, row_pk, existing, chunks, cfg_hash)
        insert_embedded_in_conn(conn, embed.table, row_pk, to_embed, vectors, cfg_hash)
        :ok
      end)
  end

  # ── chunk building ───────────────────────────────────────────────────

  defp build_chunks(state, %Embed{fields: fields} = embed, source_row) do
    chunk_cfg = effective_chunk(embed, state.embedder)

    Enum.flat_map(fields, fn field ->
      text = Map.get(source_row, field)
      chunks_for_field(field, text, chunk_cfg)
    end)
  end

  defp chunks_for_field(_field, nil, _cfg), do: []
  defp chunks_for_field(_field, "", _cfg), do: []

  defp chunks_for_field(field, text, %{size: size, overlap: overlap}) when is_binary(text) do
    text
    |> split_into_chunks(size, overlap)
    |> Enum.with_index()
    |> Enum.map(fn {chunk_text, idx} ->
      %{
        field: field,
        chunk_index: idx,
        text: chunk_text,
        content_hash: content_hash(chunk_text)
      }
    end)
  end

  # Byte-based chunking with overlap. Simple + deterministic; not
  # token-aware. Embedder handles whatever we hand it; if size exceeds
  # the model's context the embedder errors and the row enters retry.
  # Chunk boundaries snap back to UTF-8 codepoint starts so multi-byte
  # characters aren't split — downstream embedders reject invalid UTF-8.
  @doc false
  def split_into_chunks(text, size, _overlap) when byte_size(text) <= size do
    [text]
  end

  def split_into_chunks(text, size, overlap) do
    stride = max(size - overlap, 1)
    total = byte_size(text)
    do_split(text, size, stride, 0, total, [])
  end

  defp do_split(text, size, stride, start, total, acc) do
    start = snap_to_codepoint(text, start, total)
    end_pos = snap_to_codepoint(text, min(start + size, total), total)
    chunk = binary_part(text, start, end_pos - start)
    acc = [chunk | acc]

    # Once the current window already covers the end, halt. Avoids
    # emitting a trailing chunk that's strictly a suffix of the
    # previous one (fully within its overlap window).
    if start + size >= total do
      Enum.reverse(acc)
    else
      do_split(text, size, stride, start + stride, total, acc)
    end
  end

  # Walk back to the nearest UTF-8 codepoint start. Continuation bytes
  # match 0b10xxxxxx (0x80..0xBF); leading bytes do not.
  defp snap_to_codepoint(_text, 0, _total), do: 0
  defp snap_to_codepoint(_text, pos, total) when pos >= total, do: total

  defp snap_to_codepoint(text, pos, total) do
    case :binary.at(text, pos) do
      b when b >= 0x80 and b < 0xC0 -> snap_to_codepoint(text, pos - 1, total)
      _ -> pos
    end
  end

  defp effective_chunk(%Embed{chunk: nil}, %EmbedderConfig{defaults: %{chunk: c}}), do: c
  defp effective_chunk(%Embed{chunk: c}, _), do: c

  # ── hashing ──────────────────────────────────────────────────────────

  defp content_hash(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp config_hash(%Embed{} = embed, %EmbedderConfig{} = embedder) do
    chunk = effective_chunk(embed, embedder)

    parts = [
      embedder.model,
      Integer.to_string(embedder.dim),
      Integer.to_string(chunk.size),
      Integer.to_string(chunk.overlap),
      Enum.join(embed.fields, ",")
    ]

    :crypto.hash(:sha256, Enum.join(parts, "|")) |> Base.encode16(case: :lower)
  end

  # ── meta diffing ─────────────────────────────────────────────────────

  defp load_existing_meta(plugin, table, row_pk) do
    sql = """
    SELECT id, field, chunk_index, content_hash, config_hash
    FROM _embeddings_#{table}_meta
    WHERE row_pk = ?
    """

    case DB.read(plugin, sql, [row_pk]) do
      {:ok, _cols, rows} -> rows
      {:error, _} -> []
    end
  end

  # Returns {kept, to_embed}. `kept` = chunks whose existing meta
  # matches the current chunk's (field, idx, content_hash) AND the
  # current config_hash — we'll carry the vector forward without a
  # re-embed by re-inserting from the existing vec0 row. `to_embed`
  # = new/changed chunks that need a fresh embedder call.
  defp diff_chunks(chunks, existing, cfg_hash) do
    index =
      Map.new(existing, fn row ->
        {{row["field"], row["chunk_index"]}, {row["id"], row["content_hash"], row["config_hash"]}}
      end)

    Enum.split_with(chunks, fn c ->
      case Map.get(index, {c.field, c.chunk_index}) do
        {_id, hash, ^cfg_hash} when hash == c.content_hash -> true
        _ -> false
      end
    end)
    |> case do
      {kept, to_embed} ->
        kept_with_id =
          Enum.map(kept, fn c ->
            {meta_id, _, _} = Map.fetch!(index, {c.field, c.chunk_index})
            Map.put(c, :prior_meta_id, meta_id)
          end)

        {kept_with_id, to_embed}
    end
  end

  # ── writes ───────────────────────────────────────────────────────────

  defp delete_row_vectors(plugin, table, row_pk) do
    {:ok, _} =
      DB.txn(plugin, fn conn ->
        delete_row_vectors_in_conn(conn, table, row_pk)
        :ok
      end)

    :ok
  end

  defp delete_row_vectors_in_conn(conn, table, row_pk) do
    {:ok, %Result{rows: id_rows}} =
      Exqlite.query(
        conn,
        "SELECT id FROM _embeddings_#{table}_meta WHERE row_pk = ?",
        [row_pk]
      )

    ids = Enum.map(id_rows, fn [id] -> id end)

    Enum.each(ids, fn id ->
      {:ok, _} = Exqlite.query(conn, "DELETE FROM _embeddings_#{table} WHERE rowid = ?", [id])

      {:ok, _} =
        Exqlite.query(conn, "DELETE FROM _embeddings_#{table}_meta WHERE id = ?", [id])
    end)

    :ok
  end

  defp insert_embedded_in_conn(_conn, _table, _row_pk, [], _vectors, _cfg_hash), do: :ok

  defp insert_embedded_in_conn(conn, table, row_pk, chunks, vectors, cfg_hash) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.zip(chunks, vectors)
    |> Enum.each(fn {chunk, vector} ->
      vec_bin = SqliteVec.Float32.new(vector) |> SqliteVec.Float32.to_binary()

      {:ok, %Result{rows: [[meta_id]]}} =
        Exqlite.query(
          conn,
          """
          INSERT INTO _embeddings_#{table}_meta
            (row_pk, field, chunk_index, chunk_text, content_hash, config_hash, embedded_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          RETURNING id
          """,
          [row_pk, chunk.field, chunk.chunk_index, chunk.text, chunk.content_hash, cfg_hash, ts]
        )

      {:ok, _} =
        Exqlite.query(
          conn,
          "INSERT INTO _embeddings_#{table} (rowid, embedding) VALUES (?, ?)",
          [meta_id, {:blob, vec_bin}]
        )
    end)

    :ok
  end

  # Drop existing meta + vec0 rows that are no longer represented by
  # an unchanged current chunk. "Unchanged" = same field + chunk_index
  # + content_hash + current config_hash. Anything else is stale and
  # must go (a corresponding `to_embed` entry will re-insert it).
  # `_row_pk` is unused because `existing` is already scoped to one
  # row_pk by `load_existing_meta`; kept in the signature for clarity.
  defp delete_stale_in_conn(conn, table, _row_pk, existing, current_chunks, cfg_hash) do
    fresh_keys =
      MapSet.new(current_chunks, fn c ->
        {c.field, c.chunk_index, c.content_hash, cfg_hash}
      end)

    stale_ids =
      existing
      |> Enum.filter(fn row ->
        not MapSet.member?(
          fresh_keys,
          {row["field"], row["chunk_index"], row["content_hash"], row["config_hash"]}
        )
      end)
      |> Enum.map(fn row -> row["id"] end)

    Enum.each(stale_ids, fn id ->
      {:ok, _} = Exqlite.query(conn, "DELETE FROM _embeddings_#{table} WHERE rowid = ?", [id])

      {:ok, _} =
        Exqlite.query(conn, "DELETE FROM _embeddings_#{table}_meta WHERE id = ?", [id])
    end)

    :ok
  end

  # ── embedder dispatch ────────────────────────────────────────────────

  defp call_embedder!(%State{embedder_impl: impl, embedder: spec}, texts) do
    case do_embed(impl, texts, spec) do
      {:ok, vectors} ->
        unless length(vectors) == length(texts) do
          raise "embedder returned #{length(vectors)} vectors for #{length(texts)} texts"
        end

        vectors

      {:error, reason} ->
        raise "embedder call failed: #{inspect(reason)}"
    end
  end

  # Allow tests to inject a 1-arg stub that doesn't know about the
  # spec. The production module (`Sark.Embedder`) is the 1-arg form
  # too (pulls spec from config); the 2-arg form is what adapter
  # modules implement directly.
  defp do_embed(impl, texts, _spec) when impl == Sark.Embedder do
    Sark.Embedder.embed(texts)
  end

  defp do_embed(impl, texts, spec) do
    cond do
      function_exported?(impl, :embed, 2) -> impl.embed(texts, spec)
      function_exported?(impl, :embed, 1) -> impl.embed(texts)
      true -> raise "embedder impl #{inspect(impl)} has no embed/1 or embed/2"
    end
  end

  # ── queue bookkeeping ────────────────────────────────────────────────

  defp delete_queue_row(plugin, qid) do
    {:ok, _} = DB.write(plugin, "DELETE FROM _embed_queue WHERE id = ?", [qid])
    :ok
  end

  defp record_failure(state, qid, attempts, msg) do
    attempts = attempts + 1

    cond do
      attempts >= state.max_attempts ->
        {:ok, _} =
          DB.write(
            state.plugin,
            "UPDATE _embed_queue SET status='failed', attempts=?, last_error=? WHERE id=?",
            [attempts, truncate(msg), qid]
          )

        Logger.warning(
          "embed drain (#{state.plugin}) — queue row #{qid} escalated to failed " <>
            "(#{attempts}/#{state.max_attempts}): #{inspect_short(msg)}"
        )

      true ->
        # Backoff is advisory — we keep status='pending' and bump
        # `attempts`. Next batch picks it back up. Real wall-clock
        # backoff would need a `next_attempt_at` column; deferred.
        {:ok, _} =
          DB.write(
            state.plugin,
            "UPDATE _embed_queue SET attempts=?, last_error=? WHERE id=?",
            [attempts, truncate(msg), qid]
          )

        Logger.warning(
          "embed drain (#{state.plugin}) — queue row #{qid} attempt #{attempts} " <>
            "failed: #{inspect_short(msg)}"
        )

        Process.sleep(backoff_ms(state.backoff_base_ms, attempts))
    end
  end

  defp backoff_ms(base, attempt), do: (base * :math.pow(2, attempt - 1)) |> trunc()

  defp truncate(msg) when is_binary(msg), do: String.slice(msg, 0, 1_000)
  defp truncate(msg), do: msg |> inspect() |> truncate()

  defp inspect_short(v) when is_binary(v), do: String.slice(v, 0, 120)
  defp inspect_short(v), do: v |> inspect() |> String.slice(0, 120)
end
