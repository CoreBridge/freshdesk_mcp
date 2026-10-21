<#
.SYNOPSIS
  Install / update the CoreBridge Freshdesk MCP for Cursor on Windows.

.DESCRIPTION
  One-shot installer for CoreBridge/freshdesk_mcp in Cursor (~/.cursor/mcp.json).

  DEFAULT: gateway mode. No Freshdesk API key is needed.
    - Freshdesk is reached through the CoreBridge Freshdesk gateway (https://<gateway>/staff/fd).
      -GatewayUrl is REQUIRED in this mode: there is no built-in default, so you always choose
      which gateway (and, with -GatewayEnv, which data) you are pointing Cursor at.
    - You sign in with your CoreBridge Microsoft (Entra ID) account through the
      "Freshdesk Gateway Client" app. A browser window opens once; the token is cached
      (encrypted with Windows DPAPI) and refreshed silently afterwards.
    - The gateway environment defaults to prod (live Freshdesk data). It is sent as X-CB-Env.

  OPTIONAL: -ApiKeyMode keeps the old direct mode (Freshdesk API with your personal API key).

  CHOOSING TEST vs PROD (-GatewayUrl + -GatewayEnv)
    One deployed gateway serves every environment; the URL picks WHICH GATEWAY, and -GatewayEnv
    picks WHICH DATA you get from it. Ask the support lead / platform team for the deployed
    gateway URL (it is not published in this repo).

      Goal                                   -GatewayUrl                    -GatewayEnv
      -------------------------------------  -----------------------------  -----------
      Day-to-day support work (real tickets) the deployed gateway URL       prod
      Try the MCP safely / demo / training   the deployed gateway URL       dev  (or qa)
      Work against a gateway you run locally http://localhost:<port>        dev
      Preview environment                    the deployed gateway URL       preview

    - prod:    LIVE Freshdesk. Lists, searches and WRITES (replies, notes, updates) are real
               and visible to customers.
    - dev/qa:  TEST. A cache-only copy of production ticket data: requests the cache can answer
               work, anything it cannot answer is refused (403/404), and every write is refused
               (403 env_restricted). Nothing you do reaches Freshdesk, so it is safe to experiment.
    - preview: also LIVE. Preview serves real customers on the same Freshdesk account, so
               treat it like prod, not like a sandbox.
    - A local gateway (http://localhost or http://127.0.0.1 only) is for gateway developers.
      Plain http is refused for any other host, because an Entra token is sent to it.

  In both modes the installer also:
    1. Uses the CoreBridge GitHub repo via uvx (not the old local Node install)
    2. Pins mcp[cli]>=1.3.0,<2 (mcp 2.x breaks FastMCP / server will not start)
    3. Installs uv/uvx if missing, using a full path so Cursor can find it
    4. Removes the obsolete ~/.cursor/freshdesk-mcp Node folder if present
    5. Keeps your other MCP servers in mcp.json untouched (and backs the file up first)

.PARAMETER GatewayUrl
  REQUIRED in gateway mode. Freshdesk gateway base URL, e.g. https://<gateway-host> (a bare host is
  accepted and https is assumed), or http://localhost:<port> for a locally run gateway.
  A *.freshdesk.com host is refused. See "CHOOSING TEST vs PROD" above.

.PARAMETER GatewayEnv
  Gateway environment sent as X-CB-Env: dev, qa, preview or prod. Default: prod (live).
  Use dev or qa to test safely (cache-only, writes refused). See "CHOOSING TEST vs PROD" above.

.PARAMETER DeviceCode
  Sign in with a device code (URL + one-time code) instead of a browser window.

.PARAMETER ClientId
  Entra public client app id. Default: "Freshdesk Gateway Client" (b00e08ff-9e23-42f4-97b2-da02455ae39b).

.PARAMETER ApiKeyMode
  Use the legacy direct mode: call the Freshdesk API with your personal API key.

.PARAMETER ApiKey
  (ApiKeyMode only) Your personal Freshdesk API key (Profile Settings -> API Key).
  If omitted, the script keeps an existing key in mcp.json, or prompts.

.PARAMETER Domain
  (ApiKeyMode only) Freshdesk API host. Default: atomology.freshdesk.com
  (do not use supportdesk.corebridge.net; it is for browser login only and the API 404s there).

.PARAMETER Ref
  Optional git branch/tag/commit of CoreBridge/freshdesk_mcp to install (default: the default branch).

.PARAMETER SkipVerify
  Gateway mode: skip the sign-in step (you are asked to sign in on the first tool call instead).
  ApiKeyMode: skip the live API key check.

.EXAMPLE
  # Day-to-day support work: production gateway, live data
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -GatewayUrl https://<gateway-host>

.EXAMPLE
  # Try it out safely: same gateway, cache-only test data, writes refused
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -GatewayUrl https://<gateway-host> -GatewayEnv dev

.EXAMPLE
  # Gateway developers: a gateway running locally, signing in with a device code
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -GatewayUrl http://localhost:5000 -GatewayEnv dev -DeviceCode

.EXAMPLE
  # Legacy direct mode with a Freshdesk API key (no -GatewayUrl needed)
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -ApiKeyMode -ApiKey "YOUR_KEY_HERE"

.NOTES
  After it finishes: Cursor -> Command Palette -> "Developer: Reload Window"
  (or toggle the Freshdesk MCP off/on in Settings -> MCP).
  Repo: https://github.com/CoreBridge/freshdesk_mcp
#>

[CmdletBinding(DefaultParameterSetName = "Gateway")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Gateway",
        HelpMessage = "Freshdesk gateway URL, e.g. https://<gateway-host> (ask the support lead), or http://localhost:<port> for a local gateway.")]
    [ValidateNotNullOrEmpty()]
    [string]$GatewayUrl,
    [Parameter(ParameterSetName = "Gateway")]
    [ValidateSet("dev", "qa", "preview", "prod")]
    [string]$GatewayEnv = "prod",
    [Parameter(ParameterSetName = "Gateway")]
    [switch]$DeviceCode,
    [Parameter(ParameterSetName = "Gateway")]
    [string]$ClientId = "b00e08ff-9e23-42f4-97b2-da02455ae39b",
    [Parameter(Mandatory = $true, ParameterSetName = "ApiKey")]
    [switch]$ApiKeyMode,
    [Parameter(ParameterSetName = "ApiKey")]
    [string]$ApiKey = "",
    [Parameter(ParameterSetName = "ApiKey")]
    [string]$Domain = "atomology.freshdesk.com",
    [string]$Ref = "",
    [Alias("SkipSignIn")]
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"

$ServerName = "freshdesk-mcp"
$RepoUrl = "git+https://github.com/CoreBridge/freshdesk_mcp"
$McpPin = "mcp[cli]>=1.3.0,<2"

# ---------------------------------------------------------------------------
# Pure helpers (dot-source this script to test them; see tests/installer/)
# ---------------------------------------------------------------------------

function Get-FreshdeskPackageSpec {
    param([string]$Ref = "")
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $RepoUrl }
    return "$RepoUrl@$($Ref.Trim())"
}

function Get-NormalizedGatewayUrl {
    <# Returns https://host[:port] for a gateway URL or bare host; throws on anything unsafe. #>
    param([Parameter(Mandatory = $true)][string]$GatewayUrl)
    $text = $GatewayUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw "GatewayUrl is empty." }
    if ($text -notmatch "://") { $text = "https://$text" }
    $uri = $null
    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) {
        throw "GatewayUrl '$GatewayUrl' is not a valid URL."
    }
    if ($uri.Scheme -ne "https") {
        # Plain http only for a gateway running on this machine (gateway development).
        $loopback = @("localhost", "127.0.0.1", "[::1]", "::1")
        if (-not ($uri.Scheme -eq "http" -and $loopback -contains $uri.Host.ToLowerInvariant())) {
            throw "GatewayUrl must use https (an Entra token is sent to it); plain http is allowed only for localhost: '$GatewayUrl'."
        }
    }
    if ($uri.Host -match "(^|\.)freshdesk\.com$") {
        throw "GatewayUrl points at Freshdesk ($($uri.Host)), not the CoreBridge gateway. Use -ApiKeyMode for direct Freshdesk access."
    }
    $port = ""
    if (-not $uri.IsDefaultPort) { $port = ":$($uri.Port)" }
    return "$($uri.Scheme)://$($uri.Host)$port"
}

function New-FreshdeskMcpEntry {
    <# Builds the mcp.json server block. Gateway mode never carries a Freshdesk API key. #>
    param(
        [Parameter(Mandatory = $true)][string]$UvxPath,
        [ValidateSet("gateway", "apikey")][string]$Mode = "gateway",
        [string]$GatewayUrl = "",
        [string]$GatewayEnv = "prod",
        [switch]$DeviceCode,
        [string]$ClientId = "",
        [string]$ApiKey = "",
        [string]$Domain = "",
        [string]$Ref = ""
    )

    $envBlock = [ordered]@{}
    if ($Mode -eq "gateway") {
        $envBlock["FRESHDESK_AUTH_MODE"] = "entra"
        $envBlock["FRESHDESK_DOMAIN"] = (Get-NormalizedGatewayUrl -GatewayUrl $GatewayUrl)
        $envBlock["FRESHDESK_GATEWAY_ENV"] = $GatewayEnv
        if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
            $envBlock["FRESHDESK_ENTRA_CLIENT_ID"] = $ClientId
        }
        if ($DeviceCode) { $envBlock["FRESHDESK_ENTRA_FLOW"] = "device_code" }
    } else {
        if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "ApiKeyMode needs a Freshdesk API key." }
        $envBlock["FRESHDESK_AUTH_MODE"] = "apikey"
        $envBlock["FRESHDESK_API_KEY"] = $ApiKey
        $envBlock["FRESHDESK_DOMAIN"] = $Domain
    }

    return [ordered]@{
        command = ($UvxPath -replace '\\', '/')
        args    = @("--from", (Get-FreshdeskPackageSpec -Ref $Ref), "--with", $McpPin, $ServerName)
        env     = $envBlock
    }
}

function Merge-McpServerEntry {
    <# Returns the whole mcp.json object with only $Name replaced; every other server is kept. #>
    param(
        $Existing,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Entry
    )
    $servers = [ordered]@{}
    if ($null -ne $Existing -and $null -ne $Existing.mcpServers) {
        foreach ($prop in $Existing.mcpServers.PSObject.Properties) {
            if ($prop.Name -ne $Name) { $servers[$prop.Name] = $prop.Value }
        }
    }
    $servers[$Name] = $Entry
    return [ordered]@{ mcpServers = $servers }
}

# Dot-sourced (tests): stop here, after the helpers are defined.
if ($MyInvocation.InvocationName -eq ".") { return }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-UvBinDir {
    $candidates = @(
        (Join-Path $env:USERPROFILE ".local\bin"),
        (Join-Path $env:LOCALAPPDATA "uv\bin")
    )
    foreach ($dir in $candidates) {
        if (Test-Path (Join-Path $dir "uvx.exe")) { return $dir }
    }
    return $candidates[0]
}

$Mode = "gateway"
if ($ApiKeyMode) { $Mode = "apikey" }

Write-Host "CoreBridge Freshdesk MCP installer" -ForegroundColor Green
$refNote = ""
if ($Ref) { $refNote = " (ref $Ref)" }
Write-Host "Repo: https://github.com/CoreBridge/freshdesk_mcp$refNote"
if ($Mode -eq "gateway") {
    $GatewayUrl = Get-NormalizedGatewayUrl -GatewayUrl $GatewayUrl
    Write-Host "Mode: gateway (Entra sign-in, no Freshdesk API key)"
    Write-Host "Gateway: $GatewayUrl   environment: $GatewayEnv"
} else {
    Write-Host "Mode: API key (direct to $Domain)"
    Write-Host "Note: use atomology.freshdesk.com for API, not supportdesk.corebridge.net"
}

# ---------------------------------------------------------------------------
# 1) Ensure uv / uvx
# ---------------------------------------------------------------------------
Write-Step "Checking for uv / uvx"
$uvBin = Get-UvBinDir
$uvx = Join-Path $uvBin "uvx.exe"

if (-not (Test-Path $uvx)) {
    Write-Host "uvx not found. Installing uv..."
    powershell -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
    $uvBin = Get-UvBinDir
    $uvx = Join-Path $uvBin "uvx.exe"
    if (-not (Test-Path $uvx)) {
        throw "uv installed but uvx.exe not found under $uvBin. Open a new terminal and re-run this script."
    }
}
$env:Path = "$uvBin;$env:Path"
Write-Host "Using uvx: $uvx"
& $uvx --version | Write-Host

# ---------------------------------------------------------------------------
# 2) Read existing mcp.json; resolve the API key (ApiKeyMode only)
# ---------------------------------------------------------------------------
$mcpPath = Join-Path $env:USERPROFILE ".cursor\mcp.json"
$existing = $null
if (Test-Path $mcpPath) {
    try {
        $existing = Get-Content $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Could not parse $mcpPath ($($_.Exception.Message)). Fix or move it, then re-run."
    }
}

if ($Mode -eq "apikey") {
    Write-Step "Resolving Freshdesk API key"
    $existingKey = $null
    if ($null -ne $existing -and $null -ne $existing.mcpServers -and $null -ne $existing.mcpServers.$ServerName) {
        $existingKey = $existing.mcpServers.$ServerName.env.FRESHDESK_API_KEY
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        if (-not [string]::IsNullOrWhiteSpace($existingKey) -and $existingKey -notmatch "PASTE_|YOUR_|changeme") {
            $ApiKey = $existingKey
            Write-Host "Keeping existing FRESHDESK_API_KEY from mcp.json"
        } else {
            $secure = Read-Host "Paste your Freshdesk API key" -AsSecureString
            $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            )
        }
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey.Length -lt 10) {
        throw "A real Freshdesk API key is required. Get it from Freshdesk -> Profile Settings -> API Key."
    }
}

# ---------------------------------------------------------------------------
# 3) Update ~/.cursor/mcp.json (Freshdesk entry only)
# ---------------------------------------------------------------------------
Write-Step "Updating $mcpPath"
if (-not (Test-Path (Split-Path $mcpPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $mcpPath -Parent) -Force | Out-Null
}
if (Test-Path $mcpPath) {
    $backup = "$mcpPath.bak-freshdesk-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $mcpPath $backup -Force
    Write-Host "Backup: $backup"
}

$entry = New-FreshdeskMcpEntry -UvxPath $uvx -Mode $Mode -GatewayUrl $GatewayUrl -GatewayEnv $GatewayEnv `
    -DeviceCode:$DeviceCode -ClientId $ClientId -ApiKey $ApiKey -Domain $Domain -Ref $Ref
$outObj = Merge-McpServerEntry -Existing $existing -Name $ServerName -Entry $entry
$json = $outObj | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($mcpPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $ServerName ($Mode mode) -> $($entry.command)"

# ---------------------------------------------------------------------------
# 4) Remove obsolete Node install
# ---------------------------------------------------------------------------
Write-Step "Removing obsolete local Node Freshdesk MCP (if present)"
$oldNode = Join-Path $env:USERPROFILE ".cursor\freshdesk-mcp"
if (Test-Path $oldNode) {
    Remove-Item $oldNode -Recurse -Force
    Write-Host "Removed $oldNode"
} else {
    Write-Host "No old Node install found (OK)"
}

# ---------------------------------------------------------------------------
# 5) Sign in (gateway) or verify the API key (apikey)
# ---------------------------------------------------------------------------
$uvxArgs = @("--from", (Get-FreshdeskPackageSpec -Ref $Ref), "--with", $McpPin, $ServerName)

if ($Mode -eq "gateway") {
    if ($SkipVerify) {
        Write-Host "Skipping sign-in; Cursor will prompt on the first Freshdesk tool call."
    } else {
        Write-Step "Signing in to the Freshdesk gateway (first run downloads the package; a browser window opens)"
        foreach ($name in @($entry.env.Keys)) { Set-Item -Path "Env:$name" -Value $entry.env[$name] }
        Remove-Item Env:FRESHDESK_API_KEY -ErrorAction SilentlyContinue
        & $uvx @uvxArgs login
        if ($LASTEXITCODE -ne 0) {
            throw "Sign-in failed (exit $LASTEXITCODE). The config is written; re-run with -DeviceCode, or sign in on the first tool call."
        }
        Write-Host "Signed in. The token is cached for this Windows user." -ForegroundColor Green
    }
} elseif (-not $SkipVerify) {
    Write-Step "Verifying API key against https://$Domain/api/v2/agents/me"
    $pair = "${ApiKey}:X"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    try {
        $resp = Invoke-WebRequest -Uri "https://$Domain/api/v2/agents/me" `
            -Headers @{ Authorization = "Basic $b64" } `
            -UseBasicParsing -TimeoutSec 30
        $agent = $resp.Content | ConvertFrom-Json
        Write-Host "API OK: $($agent.contact.name) <$($agent.contact.email)>" -ForegroundColor Green
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 429) {
            Write-Host "API rate-limited (429). Config is still written; wait a few minutes and retry in Cursor." -ForegroundColor Yellow
        } elseif ($status -eq 401 -or $status -eq 403) {
            Write-Host "API rejected the key (HTTP $status). Check the key in Freshdesk Profile Settings." -ForegroundColor Red
        } elseif ($status -eq 404) {
            Write-Host "HTTP 404 from $Domain. Do not use supportdesk.corebridge.net for FRESHDESK_DOMAIN." -ForegroundColor Red
            throw "Wrong Freshdesk API domain."
        } else {
            Write-Host "API verify failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "DONE. Freshdesk MCP is configured ($Mode mode)." -ForegroundColor Green
Write-Host ""
Write-Host "Required next step for YOU:"
Write-Host "  1. In Cursor: Command Palette -> Developer: Reload Window"
Write-Host "  2. Settings -> MCP -> confirm $ServerName is enabled / green"
Write-Host "  3. Ask the agent to get one ticket (get_ticket) or list a few (get_tickets, per_page 3)"
Write-Host ""
Write-Host "Do NOT remove the --with mcp[cli]>=1.3.0,<2 pin (mcp 2.x breaks the server)."
