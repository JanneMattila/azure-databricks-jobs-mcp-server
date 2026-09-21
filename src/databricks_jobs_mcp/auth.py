"""Entra ID token acquisition for Azure Databricks.

Delegated callers use On-Behalf-Of (OBO) to call Databricks as the user.
Machine callers use client credentials to call as the MCP server's own
app-registration service principal, never by forwarding the inbound token.
"""

from __future__ import annotations

import threading
from collections.abc import Callable

import msal

from .config import Settings

# Azure Databricks first-party application (resource) ID. The ``/.default`` scope
# requests a Databricks-audience access token for the selected authentication flow.
AZURE_DATABRICKS_RESOURCE_ID = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
DATABRICKS_SCOPE = f"{AZURE_DATABRICKS_RESOURCE_ID}/.default"

# Audience Entra expects in a federated identity credential (workload identity
# federation) assertion minted by a managed identity.
ENTRA_TOKEN_EXCHANGE_SCOPE = "api://AzureADTokenExchange/.default"


class OboError(RuntimeError):
    """Raised when authentication or either Databricks token acquisition flow fails."""


def build_managed_identity_assertion(settings: Settings) -> Callable[[], str]:
    """Return a no-arg callable that mints a federated-credential client assertion.

    The assertion is an access token issued to the app's managed identity for the
    Entra token-exchange audience. Entra trusts it via a federated identity
    credential configured on the app registration, so it replaces the static
    client secret. ``ManagedIdentityCredential`` caches and refreshes the token
    internally, so the callable is cheap to invoke repeatedly.
    """
    from azure.identity import ManagedIdentityCredential

    if settings.azure_managed_identity_client_id:
        credential = ManagedIdentityCredential(
            client_id=settings.azure_managed_identity_client_id
        )
    else:
        credential = ManagedIdentityCredential()

    def _assertion() -> str:
        return credential.get_token(ENTRA_TOKEN_EXCHANGE_SCOPE).token

    return _assertion


class DatabricksTokenProvider:
    """Acquires Databricks tokens using MSAL OBO or client credentials.

    A single MSAL ``ConfidentialClientApplication`` is reused so that MSAL's
    in-memory token cache can serve repeated user or server-SP token requests.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._lock = threading.Lock()
        self._app: msal.ConfidentialClientApplication | None = None

    def _get_app(self) -> msal.ConfidentialClientApplication:
        """Lazily create the MSAL app (avoids network/authority I/O at startup)."""
        if self._app is None:
            if self._settings.azure_use_managed_identity:
                # Federated identity credential: a managed identity mints the
                # client assertion used to authenticate this confidential client.
                client_credential: object = {
                    "client_assertion": build_managed_identity_assertion(self._settings)
                }
            else:
                client_credential = self._settings.azure_client_secret
            self._app = msal.ConfidentialClientApplication(
                client_id=self._settings.azure_client_id,
                client_credential=client_credential,
                authority=self._settings.authority,
            )
        return self._app

    def token_for_user(self, user_assertion: str) -> str:
        """Return a Databricks access token for the user behind ``user_assertion``.

        ``user_assertion`` is the raw JWT the MCP client presented to this server.
        """
        if not user_assertion:
            raise OboError("No user assertion token available for OBO exchange.")

        with self._lock:
            app = self._get_app()
            result = app.acquire_token_on_behalf_of(
                user_assertion=user_assertion,
                scopes=[DATABRICKS_SCOPE],
            )

        if "access_token" not in result:
            error = result.get("error", "unknown_error")
            description = result.get("error_description", "")
            raise OboError(f"OBO token exchange failed: {error}: {description}")

        return result["access_token"]

    def token_for_service_principal(self) -> str:
        """Return a Databricks access token minted for this server's own SP.

        Used by the machine (app-only) path: the inbound app-only token has no
        user principal, so instead of an OBO exchange a fresh Databricks-audience
        token is acquired via the client-credentials flow. MSAL caches the app
        token internally, so repeated calls are cheap.
        """
        with self._lock:
            app = self._get_app()
            result = app.acquire_token_for_client(scopes=[DATABRICKS_SCOPE])

        if "access_token" not in result:
            error = result.get("error", "unknown_error")
            description = result.get("error_description", "")
            raise OboError(
                f"Client-credentials token acquisition failed: {error}: {description}"
            )

        return result["access_token"]
