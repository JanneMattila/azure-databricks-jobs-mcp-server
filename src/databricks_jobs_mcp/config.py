"""Application configuration loaded from environment / .env file."""

from __future__ import annotations

from typing import Annotated

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    """Settings for the Databricks Jobs MCP server.

    Values are read from environment variables or a local ``.env`` file.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- Microsoft Entra ID (Azure AD) ---
    azure_tenant_id: str = Field(..., description="Entra tenant (directory) ID.")
    azure_client_id: str = Field(..., description="App registration (client) ID of the MCP server.")
    azure_client_secret: str | None = Field(
        default=None,
        description="Client secret of the MCP server app registration. "
        "Required unless AZURE_USE_MANAGED_IDENTITY is true.",
    )
    azure_use_managed_identity: bool = Field(
        default=False,
        description="Authenticate to Entra with a managed identity federated credential "
        "instead of a client secret. Recommended when deployed to Azure.",
    )
    azure_managed_identity_client_id: str | None = Field(
        default=None,
        description="Client ID of the user-assigned managed identity. "
        "Omit to use the system-assigned managed identity.",
    )

    # --- MCP server / FastMCP ---
    mcp_base_url: str = Field(
        default="http://localhost:8000",
        description="Public base URL of this MCP server. Published in the Protected "
        "Resource Metadata (RFC 9728) so clients know the resource identifier.",
    )
    mcp_port: int = Field(default=8000, description="Port the HTTP transport listens on.")
    mcp_host: str = Field(default="127.0.0.1", description="Interface the HTTP transport binds to.")
    mcp_required_scopes: Annotated[list[str], NoDecode] = Field(
        default_factory=lambda: ["jobs"],
        description="Custom API scope name(s) exposed by the app registration (comma separated).",
    )

    # --- Diagnostics ---
    log_level: str = Field(
        default="INFO",
        description="Logging verbosity (DEBUG, INFO, WARNING, ERROR, CRITICAL). Set to "
        "DEBUG to surface the detailed reason the auth layer rejects a token "
        "(issuer/audience/scope mismatch, signature/JWKS failures).",
    )

    # --- Hosting platform (auto-injected) ---
    container_app_name: str | None = Field(
        default=None,
        description="Container App name injected by Azure Container Apps. Combined "
        "with CONTAINER_APP_ENV_DNS_SUFFIX to auto-derive MCP_BASE_URL when it is "
        "not set explicitly.",
    )
    container_app_env_dns_suffix: str | None = Field(
        default=None,
        description="Container Apps environment DNS suffix injected by Azure "
        "Container Apps. Combined with CONTAINER_APP_NAME to auto-derive MCP_BASE_URL.",
    )

    # --- Azure Databricks ---
    databricks_host: str = Field(
        ...,
        description="Databricks workspace URL, e.g. https://adb-1234567890.12.azuredatabricks.net",
    )
    databricks_api_version: str = Field(
        default="2.2",
        description="Databricks Jobs REST API version.",
    )

    @field_validator("mcp_required_scopes", mode="before")
    @classmethod
    def _split_scopes(cls, value: object) -> object:
        """Allow comma/space separated scope strings from the environment."""
        if isinstance(value, str):
            return [s.strip() for s in value.replace(",", " ").split() if s.strip()]
        return value

    @field_validator("log_level", mode="before")
    @classmethod
    def _normalize_log_level(cls, value: object) -> object:
        """Accept case-insensitive log level names from the environment."""
        if isinstance(value, str):
            return value.strip().upper()
        return value

    @field_validator("databricks_host", "mcp_base_url")
    @classmethod
    def _strip_trailing_slash(cls, value: str) -> str:
        return value.rstrip("/")

    @model_validator(mode="after")
    def _derive_base_url(self) -> "Settings":
        """Auto-derive the public base URL from the Container Apps FQDN.

        When MCP_BASE_URL is left at its localhost default but the platform
        injects CONTAINER_APP_NAME and CONTAINER_APP_ENV_DNS_SUFFIX, combine them
        into the stable app FQDN so the published resource identifier matches the
        deployed host without setting MCP_BASE_URL explicitly. Note:
        CONTAINER_APP_HOSTNAME is revision-specific and must not be used here.
        """
        if (
            self.mcp_base_url == "http://localhost:8000"
            and self.container_app_name
            and self.container_app_env_dns_suffix
        ):
            fqdn = f"{self.container_app_name}.{self.container_app_env_dns_suffix}"
            self.mcp_base_url = f"https://{fqdn}"
        return self

    @model_validator(mode="after")
    def _check_credentials(self) -> "Settings":
        """Ensure a usable server credential is configured."""
        if not self.azure_use_managed_identity and not self.azure_client_secret:
            raise ValueError(
                "AZURE_CLIENT_SECRET is required unless AZURE_USE_MANAGED_IDENTITY is true."
            )
        return self

    @property
    def authority(self) -> str:
        """Entra authority URL for this tenant."""
        return f"https://login.microsoftonline.com/{self.azure_tenant_id}"

    @property
    def entra_issuer(self) -> str:
        """Expected ``iss`` claim and advertised authorization server (v2 endpoint)."""
        return f"https://login.microsoftonline.com/{self.azure_tenant_id}/v2.0"

    @property
    def entra_jwks_uri(self) -> str:
        """JWKS endpoint used to verify inbound access-token signatures."""
        return f"https://login.microsoftonline.com/{self.azure_tenant_id}/discovery/v2.0/keys"

    @property
    def identifier_uri(self) -> str:
        """Application ID URI of the exposed API (token audience)."""
        return f"api://{self.azure_client_id}"

    @property
    def token_audiences(self) -> list[str]:
        """Accepted ``aud`` claim values for inbound access tokens."""
        return [self.azure_client_id, self.identifier_uri]

    @property
    def supported_scopes(self) -> list[str]:
        """Fully-qualified scopes clients request, advertised in resource metadata."""
        return [f"{self.identifier_uri}/{scope}" for scope in self.mcp_required_scopes]

    @property
    def databricks_jobs_base(self) -> str:
        """Base URL for Jobs API calls, e.g. https://host/api/2.2/jobs."""
        return f"{self.databricks_host}/api/{self.databricks_api_version}/jobs"


def get_settings() -> Settings:
    """Load settings (separate function keeps import side effects out of module load)."""
    return Settings()  # type: ignore[call-arg]
