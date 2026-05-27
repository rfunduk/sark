defmodule Sark.Auth.KeyStore do
  @moduledoc """
  Caches OIDC discovery + JWKS for the configured IdP.

  Lazy: nothing fetched until the first request for a key or endpoint.
  Concurrent reads arbitrated by the GenServer mailbox.

  Refresh-on-miss: if `fetch_key/1` is called with a `kid` not in the
  cached JWKS, re-fetch JWKS once (the IdP may have rotated keys).
  Still-missing kid → `{:error, :unknown_kid}`.

  Discovery is fetched by GETting `{issuer}/.well-known/openid-configuration`
  and reading `jwks_uri` + `authorization_endpoint` + `token_endpoint`
  from the response. The full discovery doc is cached so the broker
  endpoints can route OAuth proxy requests upstream.

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

  @doc """
  Look up an endpoint URL from the cached discovery doc. Common keys:
  `"authorization_endpoint"`, `"token_endpoint"`, `"userinfo_endpoint"`.
  """
  @spec fetch_endpoint(String.t()) ::
          {:ok, String.t()} | {:error, :not_advertised | {:discovery_failed, term}}
  def fetch_endpoint(name) when is_binary(name) do
    GenServer.call(@name, {:fetch_endpoint, name}, 10_000)
  end

  @impl true
  def init(%IdP{} = idp) do
    {:ok, %{idp: idp, discovery: nil, keys: nil}}
  end

  @impl true
  def handle_call({:fetch_key, kid}, _from, state) do
    with {:ok, state} <- ensure_discovery(state),
         {:ok, state} <- ensure_keys(state) do
      case Map.get(state.keys, kid) do
        nil ->
          # kid miss: refresh once (key rotation).
          case fetch_jwks(jwks_uri(state)) do
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

  def handle_call({:fetch_endpoint, name}, _from, state) do
    case ensure_discovery(state) do
      {:ok, state} ->
        case Map.get(state.discovery, name) do
          v when is_binary(v) and v != "" -> {:reply, {:ok, v}, state}
          _ -> {:reply, {:error, :not_advertised}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  defp ensure_discovery(%{discovery: %{} = _} = state), do: {:ok, state}

  defp ensure_discovery(%{idp: %IdP{issuer: issuer}} = state) do
    case fetch_discovery(issuer) do
      {:ok, doc} -> {:ok, %{state | discovery: doc}}
      {:error, reason} -> {:error, {:discovery_failed, reason}}
    end
  end

  defp ensure_keys(%{keys: keys} = state) when is_map(keys), do: {:ok, state}

  defp ensure_keys(state) do
    case fetch_jwks(jwks_uri(state)) do
      {:ok, keys} -> {:ok, %{state | keys: keys}}
      {:error, reason} -> {:error, {:jwks_failed, reason}}
    end
  end

  defp jwks_uri(%{discovery: %{"jwks_uri" => uri}}) when is_binary(uri), do: uri

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
