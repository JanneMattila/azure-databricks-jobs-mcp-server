"""MCP tool definitions for Azure Databricks Jobs.

Each tool reads the inbound user token from the request context, exchanges it
for a Databricks token via the On-Behalf-Of flow, and calls the Jobs API as the
signed-in user.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastmcp import FastMCP
from fastmcp.server.dependencies import get_access_token
from pydantic import Field

from .auth import DatabricksTokenProvider, OboError
from .databricks_client import DatabricksApiError, DatabricksJobsClient


def _user_assertion() -> str:
    """Return the raw inbound user JWT, used as the OBO assertion."""
    token = get_access_token()
    if token is None or not token.token:
        raise OboError("Request is not authenticated; no user token present.")
    return token.token


def register_tools(
    mcp: FastMCP,
    token_provider: DatabricksTokenProvider,
    client: DatabricksJobsClient,
) -> None:
    """Register the Databricks Jobs tools on the given FastMCP instance."""

    async def _databricks_token() -> str:
        return token_provider.token_for_user(_user_assertion())

    @mcp.tool(
        annotations={"readOnlyHint": True, "title": "List Databricks jobs"},
    )
    async def list_jobs(
        limit: Annotated[int, Field(ge=1, le=100, description="Max jobs to return.")] = 20,
        offset: Annotated[int | None, Field(ge=0, description="Number of jobs to skip.")] = None,
        name: Annotated[str | None, Field(description="Filter by exact job name.")] = None,
    ) -> dict[str, Any]:
        """List jobs defined in the Databricks workspace, as the signed-in user."""
        token = await _databricks_token()
        return await client.list_jobs(token, limit=limit, offset=offset, name=name)

    @mcp.tool(
        annotations={"readOnlyHint": True, "title": "List job runs"},
    )
    async def list_runs(
        job_id: Annotated[int | None, Field(description="Only list runs of this job.")] = None,
        active_only: Annotated[bool | None, Field(description="Only currently active runs.")] = None,
        completed_only: Annotated[bool | None, Field(description="Only completed runs.")] = None,
        limit: Annotated[int, Field(ge=1, le=25, description="Max runs to return.")] = 20,
        offset: Annotated[int | None, Field(ge=0, description="Number of runs to skip.")] = None,
    ) -> dict[str, Any]:
        """List job runs, optionally filtered by job and run state."""
        token = await _databricks_token()
        return await client.list_runs(
            token,
            job_id=job_id,
            active_only=active_only,
            completed_only=completed_only,
            limit=limit,
            offset=offset,
        )

    @mcp.tool(
        annotations={"readOnlyHint": True, "title": "Get job run details"},
    )
    async def get_run(
        run_id: Annotated[int, Field(description="The canonical run identifier.")],
        include_history: Annotated[
            bool | None, Field(description="Include repair history for the run.")
        ] = None,
    ) -> dict[str, Any]:
        """Get metadata and status for a single job run."""
        token = await _databricks_token()
        return await client.get_run(token, run_id=run_id, include_history=include_history)

    @mcp.tool(
        annotations={"readOnlyHint": True, "title": "Get job run output"},
    )
    async def get_run_output(
        run_id: Annotated[
            int,
            Field(
                description=(
                    "The individual task run ID whose output to fetch. This must be a "
                    "single task run, not a multi-task parent (job) run ID — the "
                    "Databricks API rejects multi-task run IDs here. Use get_run to "
                    "list a job run's tasks and read each task's run_id."
                )
            ),
        ],
    ) -> dict[str, Any]:
        """Get the output and metadata of a single task run.

        Pass the run_id of an individual task, not the parent job run. For a
        multi-task run, call get_run first to obtain the per-task run_ids.
        """
        token = await _databricks_token()
        return await client.get_run_output(token, run_id=run_id)

    @mcp.tool(
        annotations={"readOnlyHint": False, "title": "Trigger a job run"},
    )
    async def run_now(
        job_id: Annotated[int, Field(description="The job to trigger.")],
        job_parameters: Annotated[
            dict[str, Any] | None,
            Field(description="Job-level parameters as key/value pairs."),
        ] = None,
        notebook_params: Annotated[
            dict[str, Any] | None,
            Field(description="Notebook task parameters as key/value pairs."),
        ] = None,
        python_params: Annotated[
            list[str] | None,
            Field(description="Parameters passed to Python-based tasks."),
        ] = None,
        idempotency_token: Annotated[
            str | None,
            Field(description="Token to guarantee at-most-once triggering."),
        ] = None,
    ) -> dict[str, Any]:
        """Trigger a new run of an existing job and return its run_id."""
        token = await _databricks_token()
        return await client.run_now(
            token,
            job_id=job_id,
            job_parameters=job_parameters,
            notebook_params=notebook_params,
            python_params=python_params,
            idempotency_token=idempotency_token,
        )

    # Reference the names so linters don't flag the closures as unused.
    _ = (list_jobs, list_runs, get_run, get_run_output, run_now, DatabricksApiError)
