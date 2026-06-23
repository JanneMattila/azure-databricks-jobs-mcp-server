"""Thin async HTTP client for the Azure Databricks Jobs REST API.

Only the endpoints needed by this MCP server are implemented:
list jobs, list runs, get run, get run output, and run-now.
"""

from __future__ import annotations

from typing import Any

import httpx

from .config import Settings


class DatabricksApiError(RuntimeError):
    """Raised when the Databricks REST API returns an error response."""

    def __init__(self, status_code: int, message: str) -> None:
        self.status_code = status_code
        super().__init__(f"Databricks API error {status_code}: {message}")


class DatabricksJobsClient:
    """Calls the Databricks Jobs API using a per-user bearer token."""

    def __init__(self, settings: Settings, *, timeout: float = 30.0) -> None:
        self._base = settings.databricks_jobs_base
        self._timeout = timeout

    async def _request(
        self,
        method: str,
        path: str,
        token: str,
        *,
        params: dict[str, Any] | None = None,
        json: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {token}"}
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            response = await client.request(
                method,
                f"{self._base}/{path.lstrip('/')}",
                headers=headers,
                params={k: v for k, v in (params or {}).items() if v is not None},
                json=json,
            )
        if response.status_code >= 400:
            raise DatabricksApiError(response.status_code, response.text)
        if not response.content:
            return {}
        return response.json()

    async def list_jobs(
        self,
        token: str,
        *,
        limit: int = 20,
        offset: int | None = None,
        name: str | None = None,
    ) -> dict[str, Any]:
        return await self._request(
            "GET",
            "list",
            token,
            params={"limit": limit, "offset": offset, "name": name},
        )

    async def list_runs(
        self,
        token: str,
        *,
        job_id: int | None = None,
        active_only: bool | None = None,
        completed_only: bool | None = None,
        limit: int = 20,
        offset: int | None = None,
    ) -> dict[str, Any]:
        return await self._request(
            "GET",
            "runs/list",
            token,
            params={
                "job_id": job_id,
                "active_only": active_only,
                "completed_only": completed_only,
                "limit": limit,
                "offset": offset,
            },
        )

    async def get_run(
        self,
        token: str,
        *,
        run_id: int,
        include_history: bool | None = None,
    ) -> dict[str, Any]:
        return await self._request(
            "GET",
            "runs/get",
            token,
            params={"run_id": run_id, "include_history": include_history},
        )

    async def get_run_output(self, token: str, *, run_id: int) -> dict[str, Any]:
        return await self._request(
            "GET",
            "runs/get-output",
            token,
            params={"run_id": run_id},
        )

    async def run_now(
        self,
        token: str,
        *,
        job_id: int,
        job_parameters: dict[str, Any] | None = None,
        notebook_params: dict[str, Any] | None = None,
        python_params: list[str] | None = None,
        idempotency_token: str | None = None,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"job_id": job_id}
        if job_parameters is not None:
            body["job_parameters"] = job_parameters
        if notebook_params is not None:
            body["notebook_params"] = notebook_params
        if python_params is not None:
            body["python_params"] = python_params
        if idempotency_token is not None:
            body["idempotency_token"] = idempotency_token
        return await self._request("POST", "run-now", token, json=body)
