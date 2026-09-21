#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '2.19.0' }
<#
.SYNOPSIS
Tests app-only authentication against the live MCP server with a read-only job listing.
.EXAMPLE
.\auth-app-only.ps1 -ClientId '<calling-service-principal-app-id>' -TenantId '<tenant-id>' -McpServerClientId '<mcp-server-client-id>' -McpEndpoint 'https://<container-app-fqdn>/mcp'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$ClientId,

    [securestring]$ClientSecret,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$McpServerClientId,

    [Parameter(Mandatory)]
    [ValidateScript({
        if (-not $_.IsAbsoluteUri -or $_.Scheme -ne 'https' -or $_.UserInfo -or $_.Fragment -or $_.Query) {
            throw 'McpEndpoint must be an absolute HTTPS URL without credentials, a query, or a fragment.'
        }
        $true
    })]
    [uri]$McpEndpoint,

    [ValidateRange(1, 100)]
    [int]$Limit = 5,

    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ClientSecret) {
    $ClientSecret = Read-Host "Client secret for calling service principal $ClientId" -AsSecureString
}
if ($ClientSecret.Length -eq 0) {
    throw 'A non-empty client secret is required.'
}
$credential = [pscredential]::new($ClientId.ToString(), $ClientSecret)
$resourceUrl = "api://$McpServerClientId"

Write-Host "Signing in as caller $ClientId to tenant $TenantId."
# A separate process with autosave disabled keeps the caller out of the user's Az context/cache.
$loginJob = Start-Job -ArgumentList $credential, $TenantId.ToString(), $resourceUrl -ScriptBlock {
    param($Credential, $TenantId, $ResourceUrl)
    $ErrorActionPreference = 'Stop'
    Import-Module Az.Accounts -MinimumVersion 2.19.0
    Disable-AzContextAutosave -Scope Process | Out-Null
    $profile = Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantId `
        -AuthScope $ResourceUrl -SkipContextPopulation -Scope Process
    Get-AzAccessToken -ResourceUrl $ResourceUrl -TenantId $TenantId -DefaultProfile $profile -AsSecureString
}
try {
    $accessToken = Receive-Job -Job $loginJob -Wait -ErrorAction Stop
    if ($accessToken.Token -isnot [securestring] -or $accessToken.Token.Length -eq 0) {
        throw 'Azure PowerShell did not return a secure access token.'
    }
}
finally {
    Remove-Job -Job $loginJob -Force
}

$headers = @{ Accept = 'application/json, text/event-stream' }

function Invoke-McpRequest {
    param(
        [string]$Method,
        [hashtable]$Parameters = @{},
        [int]$Id,
        [switch]$Notification
    )

    $body = @{ jsonrpc = '2.0'; method = $Method; params = $Parameters }
    if (-not $Notification) { $body.id = $Id }
    $response = Invoke-WebRequest -Uri $McpEndpoint -Method Post `
        -Authentication Bearer -Token $accessToken.Token -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body ($body | ConvertTo-Json -Depth 20 -Compress) `
        -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -SkipHttpErrorCheck

    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "MCP '$Method' returned HTTP $($response.StatusCode). Check tenant, MCP API audience, caller app-role consent, and server logs."
    }
    if ($response.Headers['Mcp-Session-Id']) {
        $headers['Mcp-Session-Id'] = $response.Headers['Mcp-Session-Id'] -join ''
    }
    if ($Notification) {
        if ($response.StatusCode -ne 202) {
            throw "MCP notification '$Method' expected HTTP 202, received $($response.StatusCode)."
        }
        return
    }

    $contentType = $response.Headers['Content-Type'] -join ';'
    $messages = @()
    if ($contentType -match '^application/json\b') {
        $messages = @($response.Content | ConvertFrom-Json -AsHashtable)
    }
    elseif ($contentType -match '^text/event-stream\b') {
        foreach ($event in ($response.Content -split '\r?\n\r?\n')) {
            $data = @(
                foreach ($line in ($event -split '\r?\n')) {
                    if ($line.StartsWith('data:')) { $line.Substring(5) -replace '^ ', '' }
                }
            )
            if ($data.Count -gt 0) {
                $messages += (($data -join "`n") | ConvertFrom-Json -AsHashtable)
            }
        }
    }
    else {
        throw "MCP '$Method' returned unsupported Content-Type '$contentType'."
    }

    $replies = @($messages | Where-Object { $_.ContainsKey('id') -and [string]$_.id -eq [string]$Id })
    if ($replies.Count -ne 1) {
        throw "MCP '$Method' expected one response with id $Id; received $($replies.Count)."
    }
    $reply = $replies[0]
    if ($reply.jsonrpc -ne '2.0') { throw "MCP '$Method' returned an invalid JSON-RPC version." }
    if ($reply.ContainsKey('error')) {
        throw "MCP '$Method' failed: $($reply.error | ConvertTo-Json -Depth 10 -Compress)"
    }
    if (-not $reply.ContainsKey('result')) { throw "MCP '$Method' returned no result." }
    return $reply.result
}

try {
    $initialize = Invoke-McpRequest -Method 'initialize' -Id 1 -Parameters @{
        protocolVersion = '2025-03-26'
        capabilities = @{}
        clientInfo = @{ name = 'databricks-jobs-powershell-demo'; version = '1.0.0' }
    }
    if ($initialize.protocolVersion -notin @('2025-03-26', '2025-06-18', '2025-11-25')) {
        throw "Unsupported negotiated MCP protocol '$($initialize.protocolVersion)'."
    }
    $headers['MCP-Protocol-Version'] = $initialize.protocolVersion
    Invoke-McpRequest -Method 'notifications/initialized' -Notification
    Write-Host "MCP initialized: $($initialize.serverInfo.name), protocol $($initialize.protocolVersion)."

    $tools = Invoke-McpRequest -Method 'tools/list' -Id 2
    Write-Host "Available tools: $(@($tools.tools | ForEach-Object { $_.name }) -join ', ')"
    if ('list_jobs' -notin @($tools.tools | ForEach-Object { $_.name })) {
        throw "The server did not advertise the read-only 'list_jobs' tool."
    }

    $result = Invoke-McpRequest -Method 'tools/call' -Id 3 -Parameters @{
        name = 'list_jobs'
        arguments = @{ limit = $Limit }
    }
    if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('content') -or $result.content -isnot [array]) {
        throw 'MCP list_jobs returned an invalid tool result (expected a content array).'
    }
    if ($result.isError) {
        throw "MCP list_jobs failed: $($result.content | ConvertTo-Json -Depth 20 -Compress)"
    }
    Write-Host 'App-only MCP call succeeded. Databricks was called as the MCP server service principal.'
    $result | ConvertTo-Json -Depth 50
}
finally {
    if ($headers.ContainsKey('Mcp-Session-Id')) {
        try {
            $close = Invoke-WebRequest -Uri $McpEndpoint -Method Delete `
                -Authentication Bearer -Token $accessToken.Token -Headers $headers `
                -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -SkipHttpErrorCheck
            # MCP servers may decline explicit session termination with 405.
            if ($close.StatusCode -notin @(200, 202, 204, 404, 405)) {
                Write-Warning "MCP session cleanup returned HTTP $($close.StatusCode)."
            }
        }
        catch {
            Write-Warning "MCP session cleanup failed: $($_.Exception.Message)"
        }
    }
}
