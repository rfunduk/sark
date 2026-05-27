defmodule Sark.Config.IdP do
  @moduledoc """
  Parsed `auth.idp:` block — OAuth/OIDC identity provider config.

  Fields:

    * `issuer` — `iss` claim sark requires on incoming JWTs. Also the
      base for OIDC discovery (`{issuer}/.well-known/openid-configuration`,
      which yields JWKS + authorization + token endpoints).
    * `audience` — `aud` claim sark requires on incoming JWTs. Defaults
      to `client_id` when set, else `"sark"`.
    * `client_id` — OAuth client identifier registered w/ the upstream
      IdP. Sark proxies clients' `/oauth/authorize` + `/oauth/token`
      using this id.
    * `client_secret` — paired secret. Sark holds it; never exposed to
      MCP clients.
  """

  @enforce_keys [:issuer, :audience]
  defstruct [:issuer, :audience, :client_id, :client_secret]

  @type t :: %__MODULE__{
          issuer: String.t(),
          audience: String.t(),
          client_id: String.t() | nil,
          client_secret: String.t() | nil
        }
end
