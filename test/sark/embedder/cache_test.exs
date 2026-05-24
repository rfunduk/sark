defmodule Sark.Embedder.CacheTest do
  # Cache is a single named public ETS table shared across the BEAM —
  # one of these tests calls `clear/0` which would wipe entries from
  # concurrent users. Run sync to avoid that race.
  use ExUnit.Case, async: false

  alias Sark.Embedder.Cache

  defp unique, do: "k_#{System.unique_integer([:positive])}"

  describe "lookup/insert" do
    test "miss for unknown key" do
      assert Cache.lookup(unique(), "anything") == :miss
    end

    test "hit after insert" do
      model = unique()
      vec = :crypto.strong_rand_bytes(64)
      assert :ok = Cache.insert(model, "hello", vec)
      assert {:ok, ^vec} = Cache.lookup(model, "hello")
    end

    test "miss for same text under a different model" do
      vec = :crypto.strong_rand_bytes(64)
      :ok = Cache.insert(unique() <> "_a", "hello", vec)
      assert Cache.lookup(unique() <> "_b", "hello") == :miss
    end

    test "miss for same model under different text" do
      model = unique()
      :ok = Cache.insert(model, "hello", :crypto.strong_rand_bytes(64))
      assert Cache.lookup(model, "goodbye") == :miss
    end

    test "insert overwrites prior entry with the same key" do
      model = unique()
      v1 = :crypto.strong_rand_bytes(64)
      v2 = :crypto.strong_rand_bytes(64)
      :ok = Cache.insert(model, "k", v1)
      :ok = Cache.insert(model, "k", v2)
      assert {:ok, ^v2} = Cache.lookup(model, "k")
    end
  end

  describe "ttl" do
    test "expired entry returns :miss" do
      model = unique()
      vec = :crypto.strong_rand_bytes(64)
      :ok = Cache.insert(model, "decay", vec, ttl_ms: 1)
      # Sleep past expiry.
      Process.sleep(15)
      assert Cache.lookup(model, "decay") == :miss
    end
  end

  describe "size/clear" do
    test "size reflects inserts; clear empties" do
      # Use unique keys to avoid coupling to other tests; size assertion
      # is on the SHARED table so we only assert monotonicity, not exact
      # counts, except after clear (where we own the table).
      before = Cache.size()

      :ok = Cache.insert(unique(), "x", :crypto.strong_rand_bytes(64))
      :ok = Cache.insert(unique(), "y", :crypto.strong_rand_bytes(64))

      assert Cache.size() >= before + 2

      :ok = Cache.clear()
      assert Cache.size() == 0
    end
  end
end
