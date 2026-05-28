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
    * `scope` — extra OAuth scope values to append. Sark always sends
      `openid email profile` (required for OIDC + meaningful claims);
      this field tacks additional scopes on top. Typical use:
      `[offline_access]` for spec-clean IdPs (Okta, Auth0, Keycloak,
      Authelia, PocketID) to obtain refresh tokens. Google doesn't use
      `offline_access` — sark always injects `access_type=offline` for
      that, no scope addition needed.
    * `rules` — claim-driven plugin scope. List of
      `%{match: %{path, op, value} | nil, plugins: parsed_allowed}`.
      Evaluated additively (`Sark.Auth.Rules.eval/2`); every matching
      rule contributes to a unioned allow-list. Absent / empty (`[]`)
      ⇒ no rule can ever match ⇒ default deny. Opt into open access
      with an unconditional rule:
      `{ match: true, plugins: ["*"] }` (or omit `match:` entirely).
  """

  @baseline_scope ["openid", "email", "profile"]

  @enforce_keys [:issuer, :audience]
  defstruct [
    :issuer,
    :audience,
    :client_id,
    :client_secret,
    scope: [],
    rules: []
  ]

  @type t :: %__MODULE__{
          issuer: String.t(),
          audience: String.t(),
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          scope: [String.t()],
          rules: Sark.Auth.Rules.t()
        }

  @doc "Baseline scope sark always sends."
  def baseline_scope, do: @baseline_scope

  @doc "Effective scope = baseline ++ operator extras, deduped."
  def effective_scope(%__MODULE__{scope: extras}) do
    (@baseline_scope ++ extras) |> Enum.uniq()
  end
end
