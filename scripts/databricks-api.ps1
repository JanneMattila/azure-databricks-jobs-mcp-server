#Requires -Version 7.0
<#
.SYNOPSIS
Gets Azure Databricks job runs started within a recent time window.
.DESCRIPTION
Uses Azure CLI to acquire an Azure Databricks access token, calls the
Databricks Jobs REST API directly, and retrieves full run and job-definition
details for runs whose result state is FAILED.
.EXAMPLE
.\databricks-api.ps1 -WorkspaceUrl https://adb-1234567890123456.7.azuredatabricks.net
.EXAMPLE
.\databricks-api.ps1 -WorkspaceUrl https://adb-1234567890123456.7.azuredatabricks.net -Hours 24
.EXAMPLE
.\databricks-api.ps1 -WorkspaceUrl https://adb-1234567890123456.7.azuredatabricks.net -OutputDirectory .\output
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceUrl,

    [ValidateRange(1, 8760)]
    [int]$Hours = 12,

    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = 'databricks-jobs'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$databricksResourceId = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot $OutputDirectory
}

function Invoke-DatabricksApi {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [hashtable]$Query = @{}
    )

    $queryString = @(
        foreach ($entry in $Query.GetEnumerator()) {
            '{0}={1}' -f
                [uri]::EscapeDataString([string]$entry.Key),
                [uri]::EscapeDataString([string]$entry.Value)
        }
    ) -join '&'

    $uri = "$WorkspaceUrl$Path"
    if ($queryString) {
        $uri += "?$queryString"
    }

    Invoke-RestMethod -Method Get -Uri $uri -Headers @{
        Authorization = "Bearer $accessToken"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it and sign in with az login before running this script.'
}

$parsedWorkspaceUrl = $null
if (-not [uri]::TryCreate($WorkspaceUrl, [UriKind]::Absolute, [ref]$parsedWorkspaceUrl) -or
    $parsedWorkspaceUrl.Scheme -ne 'https' -or
    -not $parsedWorkspaceUrl.Host -or
    $parsedWorkspaceUrl.AbsolutePath -ne '/' -or
    $parsedWorkspaceUrl.Query -or
    $parsedWorkspaceUrl.Fragment) {
    throw 'WorkspaceUrl must be an absolute HTTPS workspace root URL without a path, query string, or fragment.'
}
$WorkspaceUrl = $WorkspaceUrl.TrimEnd('/')

$accessToken = & az account get-access-token `
    --resource $databricksResourceId `
    --query accessToken `
    --output tsv `
    --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI could not acquire an Azure Databricks access token (exit code $LASTEXITCODE). Run 'az login' and try again."
}
$accessToken = ([string]$accessToken).Trim()
if ([string]::IsNullOrWhiteSpace($accessToken)) {
    throw 'Azure CLI returned an empty Azure Databricks access token.'
}

$startTime = [DateTimeOffset]::UtcNow.AddHours(-$Hours)
$startTimeMilliseconds = $startTime.ToUnixTimeMilliseconds()
$runs = [System.Collections.Generic.List[object]]::new()
$pageToken = $null

do {
    $query = @{
        start_time_from = $startTimeMilliseconds
        limit           = 25
        expand_tasks    = 'true'
    }
    if ($pageToken) {
        $query.page_token = $pageToken
    }

    $page = Invoke-DatabricksApi -Path '/api/2.2/jobs/runs/list' -Query $query
    $runsProperty = $page.PSObject.Properties['runs']
    $pageRuns = if ($null -ne $runsProperty) {
        @($page.runs)
    }
    else {
        @()
    }
    foreach ($run in $pageRuns) {
        $runs.Add($run)
    }

    $nextPageTokenProperty = $page.PSObject.Properties['next_page_token']
    $pageToken = if ($null -ne $nextPageTokenProperty) {
        $page.next_page_token
    }
    else {
        $null
    }
} while ($pageToken)

$jobDetailsById = @{}
$outputFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

foreach ($run in $runs) {
    $isFailed = $run.state.result_state -eq 'FAILED'
    $runDetails = $null
    $jobDetails = $null

    if ($isFailed) {
        $runDetails = Invoke-DatabricksApi -Path '/api/2.2/jobs/runs/get' -Query @{
            run_id = $run.run_id
        }

        $jobId = [string]$run.job_id
        if (-not $jobDetailsById.ContainsKey($jobId)) {
            $jobDetailsById[$jobId] = Invoke-DatabricksApi -Path '/api/2.2/jobs/get' -Query @{
                job_id = $run.job_id
            }
        }
        $jobDetails = $jobDetailsById[$jobId]
    }

    $jobOutput = [pscustomobject]@{
        RetrievedAtUtc = [DateTimeOffset]::UtcNow
        WindowStartUtc = $startTime
        IsFailed   = $isFailed
        Run        = $run
        RunDetails = $runDetails
        JobDetails = $jobDetails
    }

    $fileName = 'job-{0}-run-{1}.json' -f $run.job_id, $run.run_id
    $filePath = Join-Path $OutputDirectory $fileName
    $jobOutput |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $filePath -Encoding utf8
    $outputFiles.Add((Get-Item -LiteralPath $filePath))
}

Write-Host "Wrote $($outputFiles.Count) job run file(s) to '$OutputDirectory'."
$outputFiles
