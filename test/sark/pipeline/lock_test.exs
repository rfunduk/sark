defmodule Sark.Pipeline.LockTest do
  use ExUnit.Case, async: true

  alias Sark.Pipeline.Lock

  # Unique plugin name per test so the Lock's keyed-by-plugin state
  # never collides with a concurrent test. Lock itself is a singleton
  # GenServer started by the application supervisor.
  defp unique_plugin, do: "lock_test_#{System.unique_integer([:positive])}"

  describe "acquire/release" do
    test "first acquire returns :ok with a fresh run_id" do
      p = unique_plugin()
      assert {:ok, run_id} = Lock.acquire(p, :p1)
      assert is_binary(run_id)
      assert byte_size(run_id) > 0
      Lock.release(p, :p1)
    end

    test "second acquire of the same slot returns :busy with the existing run_id" do
      p = unique_plugin()
      {:ok, run_id} = Lock.acquire(p, :p1)
      assert {:busy, ^run_id} = Lock.acquire(p, :p1)
      Lock.release(p, :p1)
    end

    test "release frees the slot" do
      p = unique_plugin()
      {:ok, _} = Lock.acquire(p, :p1)
      :ok = Lock.release(p, :p1)
      assert {:ok, _new_run_id} = Lock.acquire(p, :p1)
      Lock.release(p, :p1)
    end

    test "release of unheld slot is a no-op" do
      p = unique_plugin()
      assert :ok = Lock.release(p, :ghost)
    end

    test "different pipelines on the same plugin acquire independently" do
      p = unique_plugin()
      {:ok, _} = Lock.acquire(p, :a)
      assert {:ok, _} = Lock.acquire(p, :b)
      Lock.release(p, :a)
      Lock.release(p, :b)
    end

    test "different plugins acquire independently for same pipeline name" do
      p1 = unique_plugin()
      p2 = unique_plugin()
      {:ok, _} = Lock.acquire(p1, :ingest)
      assert {:ok, _} = Lock.acquire(p2, :ingest)
      Lock.release(p1, :ingest)
      Lock.release(p2, :ingest)
    end
  end

  describe "register_run + monitor" do
    test "lock auto-releases when the registered pid dies" do
      p = unique_plugin()
      {:ok, _} = Lock.acquire(p, :crashy)

      pid =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      :ok = Lock.register_run(p, :crashy, pid)

      # Slot is held while pid lives.
      assert {:busy, _} = Lock.acquire(p, :crashy)

      # Killing the pid should free the slot via Lock's monitor.
      send(pid, :die)

      # Wait for monitor message to arrive in Lock. Poll `in_flight/0`
      # so we don't consume the slot ourselves while checking.
      wait_until(fn -> not Enum.any?(Lock.in_flight(), &match?({^p, :crashy, _}, &1)) end, 500)

      assert {:ok, _new_id} = Lock.acquire(p, :crashy)
      Lock.release(p, :crashy)
    end

    test "register_run on an unheld slot is a safe no-op" do
      p = unique_plugin()
      pid = spawn(fn -> :ok end)
      assert :ok = Lock.register_run(p, :nope, pid)
    end
  end

  describe "in_flight/0" do
    test "lists currently held slots" do
      p = unique_plugin()
      {:ok, _} = Lock.acquire(p, :a)
      {:ok, _} = Lock.acquire(p, :b)

      slots = Lock.in_flight()
      held = Enum.filter(slots, &match?({^p, _, _}, &1))
      names = Enum.map(held, fn {_p, name, _} -> name end) |> Enum.sort()
      assert names == [:a, :b]

      Lock.release(p, :a)
      Lock.release(p, :b)
    end
  end

  defp wait_until(fun, total_ms, step_ms \\ 10)

  defp wait_until(_fun, total_ms, _step_ms) when total_ms <= 0,
    do: flunk("condition never became true")

  defp wait_until(fun, total_ms, step_ms) do
    if fun.() do
      :ok
    else
      Process.sleep(step_ms)
      wait_until(fun, total_ms - step_ms, step_ms)
    end
  end
end
