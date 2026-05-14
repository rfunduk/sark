defmodule Sark.AuthPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Sark.AuthPlug
  alias Sark.AuthRegistry

  @valid "good-token"
  @scoped "kv-only-token"

  setup do
    if pid = Process.whereis(AuthRegistry) do
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal, 5_000)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    start_supervised!(
      {AuthRegistry,
       %{
         @valid => %{name: "default", allowed: :all},
         @scoped => %{name: "kv-only", allowed: MapSet.new(["kv"])}
       }}
    )

    :ok
  end

  defp call(conn), do: AuthPlug.call(conn, AuthPlug.init([]))

  test "health is exempt" do
    conn = call(conn(:get, "/health"))
    refute conn.halted
  end

  test "missing token → 401" do
    conn = call(conn(:post, "/kv/mcp"))
    assert conn.status == 401
    assert conn.halted
  end

  test "bearer header passes" do
    conn =
      conn(:post, "/kv/mcp")
      |> put_req_header("authorization", "Bearer #{@valid}")
      |> call()

    refute conn.halted
    assert conn.assigns.token_name == "default"
    assert conn.assigns.plugin == "kv"
  end

  test "query string `?token=` passes when no header" do
    conn =
      conn(:post, "/kv/mcp?token=#{@valid}")
      |> call()

    refute conn.halted
    assert conn.assigns.token_name == "default"
    assert conn.assigns.plugin == "kv"
  end

  test "query string scoped token honours plugin allowlist" do
    conn =
      conn(:post, "/kv/mcp?token=#{@scoped}")
      |> call()

    refute conn.halted
    assert conn.assigns.plugin == "kv"
  end

  test "query string scoped token rejected for out-of-scope plugin → 404" do
    conn =
      conn(:post, "/jot/mcp?token=#{@scoped}")
      |> call()

    assert conn.status == 404
    assert conn.halted
  end

  test "bad query string token → 401" do
    conn =
      conn(:post, "/kv/mcp?token=nope")
      |> call()

    assert conn.status == 401
  end

  test "header takes precedence over query string" do
    conn =
      conn(:post, "/kv/mcp?token=nope")
      |> put_req_header("authorization", "Bearer #{@valid}")
      |> call()

    refute conn.halted
    assert conn.assigns.token_name == "default"
  end

  test "empty ?token= falls through to unauthorized" do
    conn = call(conn(:post, "/kv/mcp?token="))
    assert conn.status == 401
  end
end
