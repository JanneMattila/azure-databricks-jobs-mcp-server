"""FastMCP server for Azure Databricks Jobs, secured with Entra ID (OBO).

The server is an OAuth 2.0 protected resource (RFC 9728): it validates Entra-issued
access tokens locally and advertises Entra as its authorization server. Each tool
then exchanges the inbound user token for a Databricks token via the On-Behalf-Of
flow and calls the Jobs API as the signed-in user.
"""

from __future__ import annotations

import base64
import binascii
import json
import logging

from fastmcp import FastMCP
from fastmcp.server.auth import AccessToken, RemoteAuthProvider
from fastmcp.server.auth.providers.jwt import JWTVerifier
from fastmcp.utilities.logging import configure_logging
from pydantic import AnyHttpUrl

from .auth import DatabricksTokenProvider
from .config import Settings, get_settings
from .databricks_client import DatabricksJobsClient
from .tools import register_tools

logger = logging.getLogger(__name__)


def _decode_jwt_segment(segment: str) -> dict[str, object]:
    """Base64url-decode a single JWT segment into its JSON object (no verification)."""
    padding = "=" * (-len(segment) % 4)
    raw = base64.urlsafe_b64decode(segment + padding)
    return json.loads(raw)


def _unverified_token_summary(token: str) -> str:
    """Summarize a token's header and key claims WITHOUT verifying its signature.

    Used only for DEBUG diagnostics when a token is rejected, to reveal *why* an
    Entra token fails signature validation (e.g. a ``nonce`` header on a
    Microsoft-first-party "nonce-protected" token, a v1.0 token, or a wrong
    audience). This never grants access — it runs only after the real verifier
    has already rejected the token.
    """
    parts = token.split(".")
    if len(parts) != 3:
        return (
            f"not a well-formed JWS: {len(parts)} segment(s), expected 3 "
            f"(token length={len(token)})"
        )
    try:
        header = _decode_jwt_segment(parts[0])
        claims = _decode_jwt_segment(parts[1])
    except (ValueError, binascii.Error, json.JSONDecodeError) as exc:
        return f"could not base64/JSON-decode token for diagnostics: {exc!r}"

    return (
        "header={alg=%r, kid=%r, typ=%r, nonce=%s} "
        "claims={iss=%r, aud=%r, appid/azp=%r/%r, ver=%r, scp=%r, exp=%r}"
        % (
            header.get("alg"),
            header.get("kid"),
            header.get("typ"),
            "PRESENT (nonce-protected token — not validatable; wrong audience/resource)"
            if "nonce" in header
            else "absent",
            claims.get("iss"),
            claims.get("aud"),
            claims.get("appid"),
            claims.get("azp"),
            claims.get("ver"),
            claims.get("scp"),
            claims.get("exp"),
        )
    )


class DiagnosticJWTVerifier(JWTVerifier):
    """``JWTVerifier`` that logs why a rejected token failed, at DEBUG level.

    Verification behaviour is unchanged; on a rejection it additionally decodes
    the (already-rejected) token's header and claims without verifying the
    signature and logs the salient fields, so a 401 can be diagnosed from the
    container logs without capturing the bearer token by hand.
    """

    async def verify_token(self, token: str) -> AccessToken | None:
        result = await super().verify_token(token)
        if result is None and logger.isEnabledFor(logging.DEBUG):
            logger.debug("Rejected bearer token: %s", _unverified_token_summary(token))
        return result


def configure_diagnostics(settings: Settings) -> None:
    """Apply the configured log level so auth-layer details become visible.

    FastMCP's ``JWTVerifier`` logs the precise reason a bearer token is rejected
    (issuer/audience/scope mismatch at WARNING; signature, JWKS and format
    failures at DEBUG) on the ``fastmcp`` logger. Routing that logger and our own
    package logger through the configured level makes ``LOG_LEVEL=DEBUG`` surface
    those messages in the container logs.
    """
    level = settings.log_level
    # Configure FastMCP's own logger (covers the JWTVerifier auth messages).
    configure_logging(level)
    # Configure our package logger to emit to stderr at the same level.
    logging.basicConfig(level=level)
    logging.getLogger("databricks_jobs_mcp").setLevel(level)




def build_server(settings: Settings | None = None) -> FastMCP:
    """Construct the FastMCP server with Entra auth and Databricks Jobs tools."""
    settings = settings or get_settings()

    # Log the values the inbound token is validated against. Comparing these with
    # the token's actual iss/aud/scp claims is the fastest way to explain a 401.
    logger.debug(
        "Auth config: base_url=%s issuer=%s audiences=%s required_scopes=%s "
        "jwks_uri=%s",
        settings.mcp_base_url,
        settings.entra_issuer,
        settings.token_audiences,
        settings.mcp_required_scopes,
        settings.entra_jwks_uri,
    )

    # Validate inbound access tokens against Entra's published signing keys.
    token_verifier = DiagnosticJWTVerifier(
        jwks_uri=settings.entra_jwks_uri,
        issuer=settings.entra_issuer,
        audience=settings.token_audiences,
        algorithm="RS256",
        required_scopes=settings.mcp_required_scopes,
    )

    # Advertise this server as a protected resource and point clients at Entra
    # as the authorization server they must obtain tokens from.
    auth_provider = RemoteAuthProvider(
        token_verifier=token_verifier,
        authorization_servers=[AnyHttpUrl(settings.entra_issuer)],
        base_url=settings.mcp_base_url,
        scopes_supported=settings.supported_scopes,
        resource_name="Azure Databricks Jobs",
    )

    mcp = FastMCP(name="Azure Databricks Jobs", auth=auth_provider)

    token_provider = DatabricksTokenProvider(settings)
    client = DatabricksJobsClient(settings)
    register_tools(mcp, token_provider, client)

    return mcp


def main() -> None:
    """Console entry point: run the server over Streamable HTTP."""
    settings = get_settings()
    configure_diagnostics(settings)
    mcp = build_server(settings)
    mcp.run(transport="http", host=settings.mcp_host, port=settings.mcp_port)


if __name__ == "__main__":
    main()
