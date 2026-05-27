defmodule Sark.Config.IdP do
  @moduledoc """
  Parsed `auth.idp:` block — OAuth/OIDC identity provider config.

  Fields:

    * `issuer` — `iss` claim sark requires on incoming JWTs. Also the
      base for OIDC discovery (`{issuer}/.well-known/openid-configuration`,
      which yields the JWKS URI).
    * `audience` — `aud` claim sark requires on incoming JWTs. This is
      sark's identifier with the IdP (e.g. the client_id / API id).
  """

  @enforce_keys [:issuer, :audience]
  defstruct [:issuer, :audience]

  @type t :: %__MODULE__{
          issuer: String.t(),
          audience: String.t()
        }
end
