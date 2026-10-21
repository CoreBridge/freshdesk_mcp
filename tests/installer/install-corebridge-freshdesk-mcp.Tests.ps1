# Pester 5 tests for install-corebridge-freshdesk-mcp.ps1 (pure helpers only: nothing is installed,
# no network, no mcp.json is touched). Run: tests/installer/Invoke-InstallerChecks.ps1

BeforeAll {
    $script:Installer = Join-Path $PSScriptRoot "../../install-corebridge-freshdesk-mcp.ps1"
    # -GatewayUrl is mandatory, so pass one; the script returns right after defining its helpers.
    . $script:Installer -GatewayUrl "https://gw.example.azurewebsites.net"
    $script:Uvx = "C:\Users\me\.local\bin\uvx.exe"
    $script:Gateway = "https://gw.example.azurewebsites.net"

    function Get-InstallerParam([string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
        return $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }
    }

    function Get-ParameterAttributeArgs($Param) {
        # Named arguments of every [Parameter(...)] attribute on the parameter.
        $Param.Attributes | Where-Object { $_.TypeName.Name -eq "Parameter" } | ForEach-Object {
            $named = @{}
            foreach ($arg in $_.NamedArguments) { $named[$arg.ArgumentName] = $arg.Argument.Extent.Text.Trim('"') }
            $named
        }
    }
}

Describe "script defaults" {
    It "requires -GatewayUrl in gateway mode and gives it no default" {
        $p = Get-InstallerParam "GatewayUrl"
        $p.DefaultValue | Should -BeNullOrEmpty
        $attr = Get-ParameterAttributeArgs $p
        $attr.Mandatory | Should -Be '$true'
        $attr.ParameterSetName | Should -Be "Gateway"
        $attr.HelpMessage | Should -Not -BeNullOrEmpty
    }

    It "refuses to run without -GatewayUrl (non-interactive) before touching anything" {
        $shell = (Get-Process -Id $PID).Path
        $out = & $shell -NoProfile -NonInteractive -File $script:Installer 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match "GatewayUrl"
        $out | Should -Not -Match "Checking for uv"
    }

    It "does not require -GatewayUrl in API-key mode" {
        $attr = Get-ParameterAttributeArgs (Get-InstallerParam "ApiKeyMode")
        $attr.Mandatory | Should -Be '$true'
        $attr.ParameterSetName | Should -Be "ApiKey"
        $cmd = Get-Command $script:Installer
        $apiKeySet = $cmd.ParameterSets | Where-Object Name -eq "ApiKey"
        ($apiKeySet.Parameters | Where-Object Name -eq "GatewayUrl") | Should -BeNullOrEmpty
        ($cmd.ParameterSets | Where-Object IsDefault).Name | Should -Be "Gateway"
    }

    It "defaults the environment to prod and the client to the Freshdesk Gateway Client" {
        (Get-InstallerParam "GatewayEnv").DefaultValue.SafeGetValue() | Should -Be "prod"
        (Get-InstallerParam "ClientId").DefaultValue.SafeGetValue() | Should -Be "b00e08ff-9e23-42f4-97b2-da02455ae39b"
        (Get-InstallerParam "ApiKey").DefaultValue.SafeGetValue() | Should -Be ""
    }

    It "only accepts known gateway environments" {
        $validate = (Get-InstallerParam "GatewayEnv").Attributes | Where-Object { $_.TypeName.Name -eq "ValidateSet" }
        ($validate.PositionalArguments | ForEach-Object { $_.Value }) | Should -Be @("dev", "qa", "preview", "prod")
    }

    It "does not publish a deployed gateway hostname" {
        (Get-Content $script:Installer -Raw) | Should -Not -Match "azurewebsites\.net"
    }

    It "explains when to use test versus prod in the help" {
        $help = Get-Help $script:Installer -Full | Out-String -Width 200
        $help | Should -Match "CHOOSING TEST vs PROD"
        $help | Should -Match "dev/qa:\s+TEST"
        $help | Should -Match "prod:\s+LIVE"
        $help | Should -Match "preview: also LIVE"
    }
}

Describe "New-FreshdeskMcpEntry (gateway mode)" {
    It "writes the gateway env and no Freshdesk API key" {
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -GatewayUrl $script:Gateway -GatewayEnv prod `
            -ClientId "b00e08ff-9e23-42f4-97b2-da02455ae39b"
        $entry.env["FRESHDESK_AUTH_MODE"] | Should -Be "entra"
        $entry.env["FRESHDESK_DOMAIN"] | Should -Be $script:Gateway
        $entry.env["FRESHDESK_GATEWAY_ENV"] | Should -Be "prod"
        $entry.env["FRESHDESK_ENTRA_CLIENT_ID"] | Should -Be "b00e08ff-9e23-42f4-97b2-da02455ae39b"
        $entry.env.Contains("FRESHDESK_API_KEY") | Should -BeFalse
        $entry.env.Contains("FRESHDESK_ENTRA_FLOW") | Should -BeFalse
    }

    It "ignores an API key passed in gateway mode" {
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -GatewayUrl $script:Gateway -ApiKey "should-not-appear"
        ($entry | ConvertTo-Json -Depth 5) | Should -Not -Match "should-not-appear"
    }

    It "uses the configured environment and device-code flow" {
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -GatewayUrl $script:Gateway -GatewayEnv preview -DeviceCode
        $entry.env["FRESHDESK_GATEWAY_ENV"] | Should -Be "preview"
        $entry.env["FRESHDESK_ENTRA_FLOW"] | Should -Be "device_code"
    }

    It "launches the CoreBridge package through uvx with the mcp<2 pin" {
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -GatewayUrl $script:Gateway
        $entry.command | Should -Be "C:/Users/me/.local/bin/uvx.exe"
        $entry.args | Should -Be @("--from", "git+https://github.com/CoreBridge/freshdesk_mcp", "--with", "mcp[cli]>=1.3.0,<2", "freshdesk-mcp")
    }

    It "pins a git ref when one is given" {
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -GatewayUrl $script:Gateway -Ref "END-71098"
        $entry.args[1] | Should -Be "git+https://github.com/CoreBridge/freshdesk_mcp@END-71098"
    }
}

Describe "Get-NormalizedGatewayUrl" {
    It "normalizes a bare host and strips paths" {
        Get-NormalizedGatewayUrl -GatewayUrl "gw.example.azurewebsites.net" | Should -Be "https://gw.example.azurewebsites.net"
        Get-NormalizedGatewayUrl -GatewayUrl "https://gw.example.net/staff/fd/" | Should -Be "https://gw.example.net"
        Get-NormalizedGatewayUrl -GatewayUrl "https://gw.example.net:8443" | Should -Be "https://gw.example.net:8443"
    }

    It "refuses plain http (a bearer token would travel unencrypted)" {
        { Get-NormalizedGatewayUrl -GatewayUrl "http://gw.example.net" } | Should -Throw "*https*"
    }

    It "allows plain http only for a gateway on this machine" {
        Get-NormalizedGatewayUrl -GatewayUrl "http://localhost:5000" | Should -Be "http://localhost:5000"
        Get-NormalizedGatewayUrl -GatewayUrl "http://127.0.0.1:5000/" | Should -Be "http://127.0.0.1:5000"
        { Get-NormalizedGatewayUrl -GatewayUrl "http://localhost.evil.example" } | Should -Throw "*https*"
    }

    It "refuses a Freshdesk host (an Entra token must never go to Freshdesk)" {
        { Get-NormalizedGatewayUrl -GatewayUrl "atomology.freshdesk.com" } | Should -Throw "*Freshdesk*"
    }
}

Describe "New-FreshdeskMcpEntry (API-key mode)" {
    It "writes the key and the Freshdesk domain" {
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -Mode apikey -ApiKey "k-1234567890" -Domain "atomology.freshdesk.com"
        $entry.env["FRESHDESK_AUTH_MODE"] | Should -Be "apikey"
        $entry.env["FRESHDESK_API_KEY"] | Should -Be "k-1234567890"
        $entry.env["FRESHDESK_DOMAIN"] | Should -Be "atomology.freshdesk.com"
        $entry.env.Contains("FRESHDESK_GATEWAY_ENV") | Should -BeFalse
    }

    It "requires a key" {
        { New-FreshdeskMcpEntry -UvxPath $script:Uvx -Mode apikey -Domain "atomology.freshdesk.com" } | Should -Throw
    }
}

Describe "Merge-McpServerEntry" {
    It "replaces only the freshdesk entry and keeps every other server" {
        $existing = '{"mcpServers":{"other":{"command":"x"},"freshdesk-mcp":{"command":"old","env":{"FRESHDESK_API_KEY":"old-key"}}}}' | ConvertFrom-Json
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -GatewayUrl $script:Gateway
        $merged = Merge-McpServerEntry -Existing $existing -Name "freshdesk-mcp" -Entry $entry
        $json = $merged | ConvertTo-Json -Depth 12
        $roundTrip = $json | ConvertFrom-Json
        $roundTrip.mcpServers.other.command | Should -Be "x"
        $roundTrip.mcpServers.'freshdesk-mcp'.env.FRESHDESK_AUTH_MODE | Should -Be "entra"
        $json | Should -Not -Match "old-key"
    }

    It "creates the servers object when there is no mcp.json yet" {
        $entry = New-FreshdeskMcpEntry -UvxPath $script:Uvx -GatewayUrl $script:Gateway
        $merged = Merge-McpServerEntry -Existing $null -Name "freshdesk-mcp" -Entry $entry
        @($merged.mcpServers.Keys) | Should -Be @("freshdesk-mcp")
    }
}
