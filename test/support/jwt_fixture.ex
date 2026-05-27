defmodule Sark.Test.JWTFixture do
  @moduledoc """
  Helpers for issuing signed JWTs and serving a matching JWKS doc in
  tests. Generates an RSA keypair per-call (or per-fixture) so tests
  never depend on an external IdP.
  """

  @kid "test-key-1"

  @doc """
  Returns `{jwk_private, jwk_public, kid}`. `jwk_private` signs tokens;
  `jwk_public` (a JOSE.JWK with public fields only) is what JWKS
  publishes.
  """
  def keypair do
    private = JOSE.JWK.generate_key({:rsa, 2048})
    {_meta, public_map} = JOSE.JWK.to_public_map(private)
    public_map = Map.merge(public_map, %{"kid" => @kid, "use" => "sig", "alg" => "RS256"})
    {private, public_map, @kid}
  end

  @doc """
  Serialize the public key as a one-entry JWKS document.
  """
  def jwks(public_map), do: %{"keys" => [public_map]}

  @doc """
  Sign a JWT with the given private JWK. Claims override the defaults.
  The JWT header includes the matching `kid` so KeyStore can resolve
  the verifying key.
  """
  def sign(private, claims) do
    sign_with_kid(claims, private)
  end

  @doc """
  Backwards-compatible alias. Accepts either the private JWK directly or
  a previously-built signer tuple.
  """
  def sign_with_kid(claims, %JOSE.JWK{} = private) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    {_meta, compact} = private |> JOSE.JWT.sign(jws, claims) |> JOSE.JWS.compact()
    compact
  end

  @doc """
  Returns the private JWK — used as a stable handle in tests, mirroring
  the old `signer/1` API.
  """
  def signer(private), do: private
end
