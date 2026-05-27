defmodule Sark.Auth.JWT do
  @moduledoc """
  Verify an incoming bearer token as a JWT against the configured IdP.

  Validates:

    * Signature (via JWKS — key resolved from token header's `kid`)
    * `exp` — not expired
    * `nbf` — not used before its time (when present)
    * `iss` — matches `idp.issuer`
    * `aud` — equals or contains `idp.audience`

  Returns the claims map on success. Caller (Sark.AuthPlug) treats the
  decoded claims as the `:sark_auth` envelope passthrough.

  Error classification keeps causes distinguishable for logging without
  leaking JWT internals to the agent's 401 response.
  """

  alias Sark.Auth.KeyStore
  alias Sark.Config.IdP

  @type error ::
          :bad_format
          | :missing_kid
          | :unknown_kid
          | :bad_signature
          | :expired
          | :not_yet_valid
          | :wrong_issuer
          | :wrong_audience
          | {:discovery_failed, term}
          | {:jwks_failed, term}
          | {:malformed_claims, term}

  @spec verify(String.t(), IdP.t()) :: {:ok, map} | {:error, error}
  def verify(token, %IdP{} = idp) when is_binary(token) do
    with {:ok, header} <- peek_header(token),
         {:ok, kid} <- fetch_kid(header),
         {:ok, jwk} <- KeyStore.fetch_key(kid),
         {:ok, signer} <- build_signer(header, jwk),
         {:ok, claims} <- verify_signature(token, signer),
         :ok <- check_temporal(claims),
         :ok <- check_issuer(claims, idp.issuer),
         :ok <- check_audience(claims, idp.audience) do
      {:ok, claims}
    end
  end

  defp peek_header(token) do
    case Joken.peek_header(token) do
      {:ok, %{} = header} -> {:ok, header}
      _ -> {:error, :bad_format}
    end
  rescue
    _ -> {:error, :bad_format}
  end

  defp fetch_kid(%{"kid" => kid}) when is_binary(kid), do: {:ok, kid}
  defp fetch_kid(_), do: {:error, :missing_kid}

  defp build_signer(%{"alg" => alg}, jwk) when is_binary(alg) do
    {:ok, Joken.Signer.create(alg, jwk)}
  rescue
    _ -> {:error, :bad_signature}
  end

  defp build_signer(_, _), do: {:error, :bad_signature}

  defp verify_signature(token, signer) do
    case Joken.verify(token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, _} -> {:error, :bad_signature}
    end
  end

  defp check_temporal(claims) do
    now = System.system_time(:second)

    cond do
      is_integer(claims["exp"]) and claims["exp"] < now -> {:error, :expired}
      is_integer(claims["nbf"]) and claims["nbf"] > now -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp check_issuer(%{"iss" => iss}, expected) when iss == expected, do: :ok
  defp check_issuer(_, _), do: {:error, :wrong_issuer}

  defp check_audience(%{"aud" => aud}, expected) when aud == expected, do: :ok

  defp check_audience(%{"aud" => list}, expected) when is_list(list) do
    if expected in list, do: :ok, else: {:error, :wrong_audience}
  end

  defp check_audience(_, _), do: {:error, :wrong_audience}
end
