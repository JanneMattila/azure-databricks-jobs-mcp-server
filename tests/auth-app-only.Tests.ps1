#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
#Requires -Modules Az.Accounts

BeforeAll {
    $script:demoScript = Join-Path $PSScriptRoot '..\scripts\auth-app-only.ps1'
    # Never launch an authentication process from the unit tests.
    function Start-Job {
        [CmdletBinding()]
        param($ArgumentList, $ScriptBlock)
        throw 'Unmocked Start-Job.'
    }
    function Receive-Job {
        [CmdletBinding()]
        param($Job, [switch]$Wait)
        throw 'Unmocked Receive-Job.'
    }
    function Remove-Job {
        [CmdletBinding()]
        param($Job, [switch]$Force)
        throw 'Unmocked Remove-Job.'
    }
}

Describe 'auth-app-only.ps1' {
    BeforeEach {
        $script:callerId = '11111111-1111-1111-1111-111111111111'
        $script:demoParameters = @{
            TenantId = '22222222-2222-2222-2222-222222222222'
            McpServerClientId = '33333333-3333-3333-3333-333333333333'
            McpEndpoint = 'https://mcp.example.com/mcp'
        }
        $script:secret = ConvertTo-SecureString 'test-only-secret' -AsPlainText -Force
        $script:token = ConvertTo-SecureString 'test-only-token' -AsPlainText -Force
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:useSse = $false
        $script:useSession = $true
        $script:toolError = $false
        $script:rpcError = $false
        $script:httpStatus = 200
        $script:protocolVersion = '2025-03-26'
        $script:wrongId = $false
        $script:invalidToolResult = $false

        Mock Read-Host { $script:secret }
        Mock Start-Job {
            $script:loginBlock = $ScriptBlock
            $script:loginArguments = $ArgumentList
            @{ Id = 1 }
        }
        Mock Receive-Job { & $script:loginBlock @script:loginArguments }
        Mock Remove-Job {}
        Mock Disable-AzContextAutosave {}
        Mock Connect-AzAccount { [Microsoft.Azure.Commands.Common.Authentication.Models.AzureRmProfile]::new() }
        Mock Get-AzAccessToken { @{ Token = $script:token } }

        Mock Invoke-WebRequest {
            $request = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }
            $script:requests.Add(@{ HttpMethod = $Method; Body = $request; Headers = $Headers.Clone() })
            if ($Method -eq 'Delete') {
                return @{ StatusCode = 204; Headers = @{}; Content = '' }
            }
            if ($request.method -eq 'notifications/initialized') {
                return @{ StatusCode = 202; Headers = @{}; Content = '' }
            }
            $result = switch ($request.method) {
                'initialize' { @{ protocolVersion = $script:protocolVersion; serverInfo = @{ name = 'Test MCP' } } }
                'tools/list' { @{ tools = @(@{ name = 'list_jobs' }) } }
                'tools/call' { @{ isError = $script:toolError; content = @(@{ type = 'text'; text = '{"jobs":[]}' }) } }
                default { throw "Unexpected MCP method $($request.method)." }
            }
            $reply = @{ jsonrpc = '2.0'; id = $request.id; result = $result }
            if ($script:invalidToolResult -and $request.method -eq 'tools/call') { $reply.result = @{} }
            if ($script:wrongId) { $reply.id = 999 }
            if ($script:rpcError) {
                $reply.Remove('result')
                $reply.error = @{ code = -32603; message = 'Test RPC failure' }
            }
            $responseHeaders = @{ 'Content-Type' = 'application/json' }
            if ($request.method -eq 'initialize' -and $script:useSession) {
                $responseHeaders['Mcp-Session-Id'] = @('test-session')
            }
            $content = $reply | ConvertTo-Json -Depth 15 -Compress
            if ($script:useSse) {
                $responseHeaders['Content-Type'] = 'text/event-stream; charset=utf-8'
                $content = ": keepalive`r`n`r`nevent: message`r`ndata: {`r`ndata: `"jsonrpc`": `"2.0`", `"method`": `"notifications/message`"}`r`n`r`nevent: message`r`ndata: $content`r`n`r`n"
            }
            @{ StatusCode = $script:httpStatus; Headers = $responseHeaders; Content = $content }
        }
    }

    It 'logs in as the caller and makes a read-only call with the MCP API token' {
        $result = . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret -Limit 10
        ($result | ConvertFrom-Json).isError | Should -BeFalse
        Should -Invoke Disable-AzContextAutosave -Times 1 -Exactly -ParameterFilter { $Scope -eq 'Process' }
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal -and $Credential.UserName -eq $script:callerId -and
            $Credential.Password -is [securestring] -and $SkipContextPopulation -and $Scope -eq 'Process' -and
            $Tenant -eq $script:demoParameters.TenantId
        }
        Should -Invoke Get-AzAccessToken -Times 1 -Exactly -ParameterFilter {
            $ResourceUrl -eq "api://$($script:demoParameters.McpServerClientId)" -and $AsSecureString -and $null -ne $DefaultProfile
        }
        Should -Invoke Invoke-WebRequest -Times 5 -Exactly -ParameterFilter {
            $Authentication -eq 'Bearer' -and $Token -is [securestring] -and $MaximumRedirection -eq 0 -and
            $Uri -eq $script:demoParameters.McpEndpoint
        }
        ($script:requests | Where-Object HttpMethod -EQ Post | ForEach-Object { $_.Body.method }) -join ',' |
            Should -Be 'initialize,notifications/initialized,tools/list,tools/call'
        $script:requests[1].Body.ContainsKey('id') | Should -BeFalse
        $script:requests[1].Headers['Mcp-Session-Id'] | Should -Be 'test-session'
        $script:requests[1].Headers['MCP-Protocol-Version'] | Should -Be '2025-03-26'
        $script:requests[3].Body.params.name | Should -Be 'list_jobs'
        $script:requests[3].Body.params.arguments.limit | Should -Be 10
        $script:requests[4].HttpMethod | Should -Be 'Delete'
        Should -Invoke Remove-Job -Times 1 -Exactly
    }

    It 'prompts securely if no secret was supplied' {
        . $script:demoScript @demoParameters -ClientId $script:callerId | Out-Null
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $AsSecureString }
    }

    It 'supports SSE including multiline data and notifications before the response' {
        $script:useSse = $true
        $result = . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret
        ($result | ConvertFrom-Json).content[0].text | Should -Be '{"jobs":[]}'
    }

    It 'supports stateless servers without sending a session DELETE' {
        $script:useSession = $false
        . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret | Out-Null
        @($script:requests | Where-Object HttpMethod -EQ Delete).Count | Should -Be 0
    }

    It 'reports authentication failures without attempting tool calls' {
        $script:httpStatus = 401
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } | Should -Throw '*HTTP 401*'
        $script:requests.Count | Should -Be 1
    }

    It 'reports JSON-RPC errors and still closes an initialized session' {
        $script:rpcError = $true
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } | Should -Throw '*Test RPC failure*'
        $script:requests[-1].HttpMethod | Should -Be 'Delete'
    }

    It 'does not report success for a tool error in an HTTP 200 response' {
        $script:toolError = $true
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } | Should -Throw '*MCP list_jobs failed*'
        $script:requests[-1].HttpMethod | Should -Be 'Delete'
    }

    It 'rejects a malformed tool result rather than reporting success' {
        $script:invalidToolResult = $true
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } | Should -Throw '*invalid tool result*'
    }

    It 'rejects mismatched JSON-RPC response IDs' {
        $script:wrongId = $true
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } | Should -Throw '*expected one response with id 1*'
    }

    It 'rejects an unsupported negotiated protocol' {
        $script:protocolVersion = 'unknown'
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } | Should -Throw '*Unsupported negotiated MCP protocol*'
    }

    It 'cleans up the authentication job on a login failure' {
        Mock Connect-AzAccount { throw 'Test invalid client secret' }
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } | Should -Throw '*Test invalid client secret*'
        Should -Invoke Remove-Job -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects HTTP endpoints before authentication' {
        $script:demoParameters.McpEndpoint = 'http://example.com/mcp'
        { . $script:demoScript @demoParameters -ClientId $script:callerId -ClientSecret $script:secret } |
            Should -Throw '*absolute HTTPS URL*'
        Should -Invoke Start-Job -Times 0 -Exactly
    }

    It 'requires explicit identity and endpoint parameters without defaults' {
        $command = Get-Command $script:demoScript
        foreach ($name in @('ClientId', 'TenantId', 'McpServerClientId', 'McpEndpoint')) {
            $attribute = $command.Parameters[$name].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attribute.Mandatory | Should -BeTrue
            $parameter = $command.ScriptBlock.Ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter.DefaultValue | Should -BeNullOrEmpty
        }
    }
}
