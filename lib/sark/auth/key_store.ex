defmodule Sark.Auth.KeyStore do
  @moduledoc """
  Caches OIDC discovery + JWKS for the configured IdP.

  Lazy: nothing fetched until the first `fetch_key/1` request. Result is
  cached in process state; concurrent reads are arbitrated by the
  GenServer mailbox.

  Refresh-on-miss: if `fetch_key/1` is called with a `kid` not in the
  cached JWKS, re-fetch JWKS once (the IdP may have rotated keys).
  Still-missing kid → `{:error, :unknown_kid}`.

  Discovery is fetched by GETting `{issuer}/.well-known/openid-configuration`
  and reading `jwks_uri` from the response.

  Only started when `auth.idp:` is configured (see `Sark.Application`).
  """

  use GenServer

  alias Sark.Config.IdP

  require Logger

  @name __MODULE__

  @spec start_link(IdP.t()) :: GenServer.on_start()
  def start_link(%IdP{} = idp) do
    GenServer.start_link(__MODULE__, idp, name: @name)
  end

  @doc """
  Look up a signing key by `kid`. Returns the JWK as a map.

      {:ok, %{"kty" => "RSA", ...}}
      {:error, :unknown_kid}
      {:error, {:discovery_failed, term}}
      {:error, {:jwks_failed, term}}
  """
  @spec fetch_key(String.t()) ::
          {:ok, map}
          | {:error, :unknown_kid | {:discovery_failed, term} | {:jwks_failed, term}}
  def fetch_key(kid) when is_binary(kid) do
    GenServer.call(@name, {:fetch_key, kid}, 10_000)
  end

  @impl true
  def init(%IdP{} = idp) do
    {:ok, %{idp: idp, jwks_uri: nil, keys: nil}}
  end

  @impl true
  def handle_call({:fetch_key, kid}, _from, state) do
    with {:ok, state} <- ensure_jwks_uri(state),
         {:ok, state} <- ensure_keys(state) do
      case Map.get(state.keys, kid) do
        nil ->
          # kid miss: refresh once (key rotation).
          case fetch_jwks(state.jwks_uri) do
            {:ok, keys} ->
              state = %{state | keys: keys}

              case Map.get(keys, kid) do
                nil -> {:reply, {:error, :unknown_kid}, state}
                key -> {:reply, {:ok, key}, state}
              end

            {:error, reason} ->
              {:reply, {:error, {:jwks_failed, reason}}, state}
          end

        key ->
          {:reply, {:ok, key}, state}
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  defp ensure_jwks_uri(%{jwks_uri: uri} = state) when is_binary(uri), do: {:ok, state}

  defp ensure_jwks_uri(%{idp: %IdP{issuer: issuer}} = state) do
    case fetch_discovery(issuer) do
      {:ok, %{"jwks_uri" => uri}} when is_binary(uri) ->
        {:ok, %{state | jwks_uri: uri}}

      {:ok, _doc} ->
        {:error, {:discovery_failed, :missing_jwks_uri}}

      {:error, reason} ->
        {:error, {:discovery_failed, reason}}
    end
  end

  defp ensure_keys(%{keys: keys} = state) when is_map(keys), do: {:ok, state}

  defp ensure_keys(%{jwks_uri: uri} = state) do
    case fetch_jwks(uri) do
      {:ok, keys} -> {:ok, %{state | keys: keys}}
      {:error, reason} -> {:error, {:jwks_failed, reason}}
    end
  end

  defp fetch_discovery(issuer) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"
    get_json(url)
  end

  defp fetch_jwks(uri) do
    with {:ok, %{"keys" => keys}} when is_list(keys) <- get_json(uri) do
      by_kid =
        keys
        |> Enum.filter(&is_map/1)
        |> Map.new(fn k -> {Map.get(k, "kid"), k} end)

      {:ok, by_kid}
    else
      {:ok, _} -> {:error, :malformed_jwks}
      {:error, _} = e -> e
    end
  end

  defp get_json(url) do
    case Req.get(req(), url: url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} = e -> e
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Test seam: `Application.put_env(:sark, :req_plug, {plug, opts})` to
  # stub HTTP. Default = live Req client.
  defp req do
    case Application.get_env(:sark, :req_plug) do
      nil -> Req.new()
      plug -> Req.new(plug: plug)
    end
  end
end
