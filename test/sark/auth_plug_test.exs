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
         @scoped => %{name: "kv-only", allowed: %{"kv" => :all}}
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

  # Bare /mcp = client URL missing the plugin segment. 404 + hint, even
  # with a valid token — a 401 would send the client down root-level
  # OAuth discovery that can only fail later with a worse error.
  test "bare /mcp → 404 with plugin-path hint" do
    conn =
      conn(:post, "/mcp")
      |> put_req_header("authorization", "Bearer #{@valid}")
      |> call()

    assert conn.status == 404
    assert conn.halted
    assert Jason.decode!(conn.resp_body)["error_description"] =~ "/<name>/mcp"
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

  test "synthesizes :sark_auth envelope from the token name" do
    conn =
      conn(:post, "/kv/mcp")
      |> put_req_header("authorization", "Bearer #{@valid}")
      |> call()

    assert %{
             "sub" => "token:default",
             "name" => "default",
             "iss" => "sark.bearer"
           } = Jason.decode!(conn.assigns.sark_auth)
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
      conn(:post, "/missing/mcp?token=#{@scoped}")
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

  test "401 on /<plugin>/mcp carries a WWW-Authenticate challenge pointing at metadata" do
    conn = call(conn(:post, "/kv/mcp"))
    assert conn.status == 401

    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~r/^Bearer resource_metadata=/
    assert challenge =~ "/kv/.well-known/oauth-protected-resource"
  end

  test "401 outside the /<plugin>/mcp shape omits the challenge (no plugin to advertise)" do
    conn = call(conn(:post, "/whatever"))
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == []
  end

  test "/<plugin>/.well-known/oauth-protected-resource is auth-exempt" do
    conn = call(conn(:get, "/kv/.well-known/oauth-protected-resource"))
    refute conn.halted
  end

  describe "auth: none" do
    setup do
      Application.put_env(:sark, :auth_none, true)
      on_exit(fn -> Application.delete_env(:sark, :auth_none) end)
      :ok
    end

    test "request without any token passes with the anon envelope" do
      conn = call(conn(:post, "/kv/mcp"))

      refute conn.halted
      assert conn.assigns.token_name == "anon"
      assert conn.assigns.plugin == "kv"
      assert conn.assigns.token_entry == %{name: "anon", allowed: :all}

      assert %{"sub" => "anon", "name" => "anon", "iss" => "sark.none"} =
               Jason.decode!(conn.assigns.sark_auth)
    end

    test "non-plugin-shaped path still 404s" do
      conn = call(conn(:post, "/whatever"))
      assert conn.status == 404
      assert conn.halted
    end

    test "bare /mcp still gets the plugin-path hint" do
      conn = call(conn(:post, "/mcp"))
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error_description"] =~ "/<name>/mcp"
    end
  end

  test "challenge URL honors the configured external url when set" do
    prior = Application.get_env(:sark, :url)
    Application.put_env(:sark, :url, "https://sark.example.com")
    on_exit(fn -> Application.put_env(:sark, :url, prior) end)

    conn = call(conn(:post, "/kv/mcp"))
    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "https://sark.example.com/kv/.well-known/oauth-protected-resource"
  end
end
