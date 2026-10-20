<#
.SYNOPSIS
  Install / update Cursor Freshdesk MCP to the CoreBridge FD gateway (Entra + your API key).

.DESCRIPTION
  One-shot Windows installer for Support agents:

    1. Uses CoreBridge/freshdesk_mcp@entra-auth via uvx (not a local Node copy)
    2. Pins mcp[cli]>=1.3.0,<2 (mcp 2.x breaks FastMCP)
    3. Sets FRESHDESK_DOMAIN to the CoreBridge Freshdesk gateway host
       (auth.py adds /staff/fd; do not use supportdesk.corebridge.net for API)
    4. Sets FRESHDESK_GATEWAY_ENV=prod so live ticket data is available
    5. Keeps YOUR existing FRESHDESK_API_KEY from mcp.json, or prompts for yours
       (never ships someone else's key)
    6. Installs uv/uvx if missing
    7. Removes obsolete ~/.cursor/freshdesk-mcp Node folder if present
    8. Leaves every other MCP server in mcp.json untouched
    9. Optionally runs `freshdesk-mcp login` (Entra browser sign-in) and a live smoke test

  Gateway mode authenticates with your Microsoft Entra account (Bearer). Your personal
  Freshdesk API key is still stored in mcp.json for fallback / non-gateway use and must
  be yours, not a shared key.

.PARAMETER ApiKey
  Your personal Freshdesk API key (Profile Settings -> API Key).
  If omitted, the script keeps an existing key in mcp.json, or prompts.

.PARAMETER Domain
  Gateway host only (no https://, no /staff/fd). Default: CoreBridge prod gateway.

.PARAMETER GatewayEnv
  Value for FRESHDESK_GATEWAY_ENV / X-CB-Env. Default: prod.

.PARAMETER GitRef
  Git ref for uvx --from. Default: entra-auth.

.PARAMETER SkipVerify
  Skip the live API smoke test after install.

.PARAMETER SkipLogin
  Do not run interactive Entra login (you can run it later).

.PARAMETER Login
  Force interactive Entra login even if a prior sign-in record exists.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -ApiKey "YOUR_KEY_HERE"

.NOTES
  After it finishes: Cursor -> Command Palette -> "Developer: Reload Window"
  Repo: https://github.com/CoreBridge/freshdesk_mcp (branch entra-auth)
#>

[CmdletBinding()]
param(
    [string]$ApiKey = "",
    [string]$Domain = "cus-cb-fd-gateway-cjccdjf4gxg5dbhr.centralus-01.azurewebsites.net",
    [ValidateSet("dev", "qa", "preview", "prod")]
    [string]$GatewayEnv = "prod",
    [string]$GitRef = "entra-auth",
    [switch]$SkipVerify,
    [switch]$SkipLogin,
    [switch]$Login
)

$ErrorActionPreference = "Stop"

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

function Get-UvFromSpec {
    param([string]$Ref)
    return "git+https://github.com/CoreBridge/freshdesk_mcp@$Ref"
}

# Normalize domain: strip scheme, path, trailing slash
$Domain = $Domain.Trim()
$Domain = $Domain -replace '^https?://', ''
$Domain = ($Domain -split '/')[0]
$Domain = $Domain.TrimEnd('.')

$fromSpec = Get-UvFromSpec -Ref $GitRef

Write-Host "CoreBridge Freshdesk MCP installer (gateway)" -ForegroundColor Green
Write-Host "Repo: https://github.com/CoreBridge/freshdesk_mcp @$GitRef"
Write-Host "Gateway host: $Domain"
Write-Host "Gateway env:  $GatewayEnv"
Write-Host "Note: browser Freshdesk UI stays on supportdesk.corebridge.net; API goes through the gateway."
Write-Host "Note: your personal API key is kept in mcp.json; gateway calls use your Entra sign-in."

# ---------------------------------------------------------------------------
# 1) Ensure uv / uvx
# ---------------------------------------------------------------------------
Write-Step "Checking for uv / uvx"
$uvBin = Get-UvBinDir
$uvx = Join-Path $uvBin "uvx.exe"
$uv = Join-Path $uvBin "uv.exe"

if (-not (Test-Path $uvx)) {
    Write-Host "uvx not found. Installing uv..."
    powershell -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
    $uvBin = Get-UvBinDir
    $uvx = Join-Path $uvBin "uvx.exe"
    $uv = Join-Path $uvBin "uv.exe"
    if (-not (Test-Path $uvx)) {
        throw "uv installed but uvx.exe not found under $uvBin. Open a new terminal and re-run this script."
    }
}
$env:Path = "$uvBin;$env:Path"
Write-Host "Using uvx: $uvx"
& $uvx --version | Write-Host

# ---------------------------------------------------------------------------
# 2) Resolve API key (yours only; never overwrite with a shared key)
# ---------------------------------------------------------------------------
Write-Step "Resolving YOUR Freshdesk API key"
$mcpPath = Join-Path $env:USERPROFILE ".cursor\mcp.json"
$existingKey = $null
$existingEnv = $null
if (Test-Path $mcpPath) {
    try {
        $existing = Get-Content $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingEnv = $existing.mcpServers.'freshdesk-mcp'.env
        $existingKey = $existingEnv.FRESHDESK_API_KEY
    } catch {
        Write-Host "Could not parse existing mcp.json; will create/replace Freshdesk entry only if possible."
    }
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    if (-not [string]::IsNullOrWhiteSpace($existingKey) -and $existingKey -notmatch "PASTE_|YOUR_|changeme|REPLACE") {
        $ApiKey = $existingKey
        $tail = $ApiKey.Substring([Math]::Max(0, $ApiKey.Length - 4))
        Write-Host "Keeping YOUR existing FRESHDESK_API_KEY from mcp.json (ends with ...$tail)"
    } else {
        $secure = Read-Host "Paste YOUR Freshdesk API key (Profile Settings -> API Key)" -AsSecureString
        $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        )
    }
}

if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey.Length -lt 10) {
    throw "A real personal Freshdesk API key is required. Get it from Freshdesk -> Profile Settings -> API Key."
}

# ---------------------------------------------------------------------------
# 3) Update ~/.cursor/mcp.json (Freshdesk entry only)
# ---------------------------------------------------------------------------
Write-Step "Updating $mcpPath"

if (-not (Test-Path (Split-Path $mcpPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $mcpPath -Parent) -Force | Out-Null
}

$mcp = $null
if (Test-Path $mcpPath) {
    $backup = "$mcpPath.bak-freshdesk-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $mcpPath $backup -Force
    Write-Host "Backup: $backup"
    $mcp = Get-Content $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $mcp = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
}

if (-not $mcp.mcpServers) {
    $mcp | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
}

# Prefer bare `uvx` on PATH (Cursor inherits user PATH after reload). Fall back to full path.
$uvxCommand = "uvx"
if (-not (Get-Command uvx -ErrorAction SilentlyContinue)) {
    $uvxCommand = ($uvx -replace '\\', '/')
}

$freshdeskEnv = [ordered]@{
    FRESHDESK_API_KEY     = $ApiKey
    FRESHDESK_DOMAIN      = $Domain
    FRESHDESK_GATEWAY_ENV = $GatewayEnv
}

# Preserve optional cache TTLs the agent already tuned
foreach ($ttlName in @(
        "FRESHDESK_CACHE_TTL_TICKET_FIELDS",
        "FRESHDESK_CACHE_TTL_AGENT_ME",
        "FRESHDESK_CACHE_TTL_SEARCH"
    )) {
    if ($existingEnv -and $existingEnv.PSObject.Properties.Name -contains $ttlName) {
        $val = [string]$existingEnv.$ttlName
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $freshdeskEnv[$ttlName] = $val
        }
    }
}

$freshdeskBlock = [ordered]@{
    command = $uvxCommand
    args    = @(
        "--from"
        $fromSpec
        "--with"
        "mcp[cli]>=1.3.0,<2"
        "freshdesk-mcp"
    )
    env     = $freshdeskEnv
}

$serversHash = [ordered]@{}
foreach ($prop in $mcp.mcpServers.PSObject.Properties) {
    if ($prop.Name -ne "freshdesk-mcp") {
        $serversHash[$prop.Name] = $prop.Value
    }
}
$serversHash["freshdesk-mcp"] = $freshdeskBlock

$outObj = [ordered]@{ mcpServers = $serversHash }
$json = $outObj | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($mcpPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote freshdesk-mcp -> $uvxCommand ($fromSpec)"
Write-Host "FRESHDESK_DOMAIN=$Domain"
Write-Host "FRESHDESK_GATEWAY_ENV=$GatewayEnv"
Write-Host "FRESHDESK_API_KEY kept as YOUR key (not shared)"

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
# 5) Pre-warm package (downloads Python deps once)
# ---------------------------------------------------------------------------
Write-Step "Pre-warming freshdesk-mcp@$GitRef (first run can take a minute)"
$env:FRESHDESK_API_KEY = $ApiKey
$env:FRESHDESK_DOMAIN = $Domain
$env:FRESHDESK_GATEWAY_ENV = $GatewayEnv
$prewarmOut = Join-Path $env:TEMP "fd-mcp-prewarm.out"
$prewarmErr = Join-Path $env:TEMP "fd-mcp-prewarm.err"
$prewarm = Start-Process -FilePath $uvx `
    -ArgumentList @(
        "--from", $fromSpec,
        "--with", "mcp[cli]>=1.3.0,<2",
        "freshdesk-mcp"
    ) `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $prewarmOut `
    -RedirectStandardError $prewarmErr
Start-Sleep -Seconds 15
if (-not $prewarm.HasExited) {
    Stop-Process -Id $prewarm.Id -Force -ErrorAction SilentlyContinue
    Write-Host "Package start OK (stdio server launched; stopped after smoke start)"
} else {
    $err = Get-Content $prewarmErr -ErrorAction SilentlyContinue
    $joined = ($err | Select-Object -First 20) -join "`n"
    if ($joined -match "Starting Freshdesk MCP server|auth mode:\s*entra") {
        Write-Host "Package start OK"
    } elseif ($joined -match "FastMCP|mcp 2\.x") {
        throw "MCP dependency pin failed. Re-run this script. stderr:`n$joined"
    } else {
        Write-Host "Pre-warm exited; stderr preview:`n$joined"
    }
}

# ---------------------------------------------------------------------------
# 6) Entra login (gateway Bearer token)
# ---------------------------------------------------------------------------
$didLogin = $false
if (-not $SkipLogin) {
    $recordPath = Join-Path $env:USERPROFILE ".freshdesk-mcp\entra_auth_record.json"
    $needLogin = $Login -or -not (Test-Path $recordPath)
    if ($needLogin) {
        Write-Step "Entra sign-in for the Freshdesk gateway (browser will open)"
        Write-Host "Sign in with YOUR CoreBridge Microsoft account."
        & $uvx --from $fromSpec --with "mcp[cli]>=1.3.0,<2" freshdesk-mcp login
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Entra login failed (exit $LASTEXITCODE). Re-run with -Login after fixing sign-in." -ForegroundColor Yellow
        } else {
            $didLogin = $true
            Write-Host "Entra login OK" -ForegroundColor Green
        }
    } else {
        Write-Host "Existing Entra auth record found at $recordPath (use -Login to refresh)."
        $didLogin = $true
    }
}

# ---------------------------------------------------------------------------
# 7) Optional live API verify (gateway + Entra, not Basic API-key against Azure)
# ---------------------------------------------------------------------------
if (-not $SkipVerify) {
    Write-Step "Verifying gateway access (Entra Bearer -> /staff/fd/api/v2/agents/me)"
    if (-not $didLogin -and -not (Test-Path (Join-Path $env:USERPROFILE ".freshdesk-mcp\entra_auth_record.json"))) {
        Write-Host "Skipping live verify: no Entra sign-in yet. Run with -Login, then retry." -ForegroundColor Yellow
    } else {
        $verifyPy = @'
import asyncio, json, os, sys
from freshdesk_mcp.auth import FreshdeskAuth, load_settings
import httpx

async def main() -> int:
    settings = load_settings()
    if settings.error:
        print("CONFIG_ERROR:", settings.error)
        return 2
    print("mode:", settings.mode)
    print("api_base:", settings.api_base)
    print("gateway_env:", settings.gateway_env or "(unset)")
    auth = FreshdeskAuth(settings)
    async with httpx.AsyncClient(auth=auth, headers=settings.extra_headers, timeout=30.0) as client:
        r = await client.get(f"{settings.api_base}/agents/me")
        print("http:", r.status_code)
        if r.status_code >= 400:
            print(r.text[:500])
            return 1
        data = r.json()
        contact = data.get("contact") or {}
        print("API OK:", contact.get("name"), "<" + str(contact.get("email") or "") + ">")
        return 0

sys.exit(asyncio.run(main()))
'@
        $verifyPath = Join-Path $env:TEMP "fd-mcp-gateway-verify.py"
        Set-Content -Path $verifyPath -Value $verifyPy -Encoding UTF8
        $env:FRESHDESK_API_KEY = $ApiKey
        $env:FRESHDESK_DOMAIN = $Domain
        $env:FRESHDESK_GATEWAY_ENV = $GatewayEnv
        # Run inside the same package env uvx uses (imports freshdesk_mcp.auth).
        & $uv run --isolated `
            --with $fromSpec `
            --with "mcp[cli]>=1.3.0,<2" `
            python $verifyPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Live verify did not succeed (exit $LASTEXITCODE). Config is still written." -ForegroundColor Yellow
            Write-Host "Try: uvx --from $fromSpec freshdesk-mcp login" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "DONE. Freshdesk MCP is configured for the CoreBridge gateway." -ForegroundColor Green
Write-Host ""
Write-Host "Required next steps:"
Write-Host "  1. Cursor -> Command Palette -> Developer: Reload Window"
Write-Host "  2. Settings -> MCP -> confirm freshdesk-mcp is enabled / green"
Write-Host "  3. If tools fail with auth errors, run:"
Write-Host "       uvx --from $fromSpec freshdesk-mcp login"
Write-Host "  4. Ask the agent to call get_agents (page 1, per_page 1)"
Write-Host ""
Write-Host "Do NOT set FRESHDESK_DOMAIN to supportdesk.corebridge.net (browser only)."
Write-Host "Do NOT share or paste someone else's FRESHDESK_API_KEY; use your own."
Write-Host "Do NOT remove the --with mcp[cli]>=1.3.0,<2 pin (mcp 2.x breaks the server)."
Write-Host "FRESHDESK_GATEWAY_ENV=$GatewayEnv is required for live data (not cache-only)."
