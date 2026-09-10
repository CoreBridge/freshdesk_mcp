<#
.SYNOPSIS
  Replace your Cursor Freshdesk MCP with CoreBridge/freshdesk_mcp (working Windows setup).

.DESCRIPTION
  One-shot installer that applies the known-good CoreBridge Freshdesk MCP config and
  skips the pitfalls we hit during rollout:

    1. Uses the CoreBridge GitHub repo via uvx (not the old local Node install)
    2. Pins mcp[cli]>=1.3.0,<2 (mcp 2.x breaks FastMCP / server will not start)
    3. Sets FRESHDESK_DOMAIN to atomology.freshdesk.com
       (supportdesk.corebridge.net is for browser login only; API calls there return 404)
    4. Installs uv/uvx if missing, using a full path so Cursor can find it
    5. Removes the obsolete ~/.cursor/freshdesk-mcp Node folder if present
    6. Keeps your other MCP servers in mcp.json untouched
    7. Optionally verifies the API key with /api/v2/agents/me

.PARAMETER ApiKey
  Your personal Freshdesk API key (Profile Settings -> API Key).
  If omitted, the script keeps an existing key in mcp.json, or prompts.

.PARAMETER Domain
  Freshdesk API host. Default: atomology.freshdesk.com (required for API; do not use the custom support URL).

.PARAMETER SkipVerify
  Skip the live API smoke test.

.EXAMPLE
  # Interactive (prompts for API key if needed)
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -ApiKey "YOUR_KEY_HERE"

.NOTES
  After it finishes: Cursor -> Command Palette -> "Developer: Reload Window"
  (or toggle the Freshdesk MCP off/on in Settings -> MCP).
  Repo: https://github.com/CoreBridge/freshdesk_mcp
#>

[CmdletBinding()]
param(
    [string]$ApiKey = "",
    [string]$Domain = "atomology.freshdesk.com",
    [switch]$SkipVerify
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

Write-Host "CoreBridge Freshdesk MCP installer" -ForegroundColor Green
Write-Host "Repo: https://github.com/CoreBridge/freshdesk_mcp"
Write-Host "API domain (required): $Domain"
Write-Host "Note: use atomology.freshdesk.com for API, not supportdesk.corebridge.net"

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
# 2) Resolve API key
# ---------------------------------------------------------------------------
Write-Step "Resolving Freshdesk API key"
$mcpPath = Join-Path $env:USERPROFILE ".cursor\mcp.json"
$existingKey = $null
if (Test-Path $mcpPath) {
    try {
        $existing = Get-Content $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingKey = $existing.mcpServers.'freshdesk-mcp'.env.FRESHDESK_API_KEY
    } catch {
        Write-Host "Could not parse existing mcp.json; will create/replace Freshdesk entry only if possible."
    }
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    if (-not [string]::IsNullOrWhiteSpace($existingKey) -and $existingKey -notmatch "PASTE_|YOUR_|changeme") {
        $ApiKey = $existingKey
        Write-Host "Keeping existing FRESHDESK_API_KEY from mcp.json (ends with ...$($ApiKey.Substring([Math]::Max(0,$ApiKey.Length-4))))"
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

# Build Freshdesk server block (known-good)
$uvxForward = ($uvx -replace '\\', '/')
$freshdeskBlock = [ordered]@{
    command = $uvxForward
    args    = @(
        "--from"
        "git+https://github.com/CoreBridge/freshdesk_mcp"
        "--with"
        "mcp[cli]>=1.3.0,<2"
        "freshdesk-mcp"
    )
    env     = [ordered]@{
        FRESHDESK_API_KEY = $ApiKey
        FRESHDESK_DOMAIN  = $Domain
    }
}

# ConvertTo-Json on nested PSCustomObject: set via hashtable merge
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
Write-Host "Wrote freshdesk-mcp -> $uvxForward (CoreBridge git + mcp<2 pin)"
Write-Host "FRESHDESK_DOMAIN=$Domain"

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
Write-Step "Pre-warming CoreBridge freshdesk-mcp package (first run can take a minute)"
$env:FRESHDESK_API_KEY = $ApiKey
$env:FRESHDESK_DOMAIN = $Domain
$prewarm = Start-Process -FilePath $uvx `
    -ArgumentList @(
        "--from", "git+https://github.com/CoreBridge/freshdesk_mcp",
        "--with", "mcp[cli]>=1.3.0,<2",
        "freshdesk-mcp"
    ) `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $env:TEMP "fd-mcp-prewarm.out") `
    -RedirectStandardError (Join-Path $env:TEMP "fd-mcp-prewarm.err")
Start-Sleep -Seconds 12
if (-not $prewarm.HasExited) {
    Stop-Process -Id $prewarm.Id -Force -ErrorAction SilentlyContinue
    Write-Host "Package start OK (stdio server launched; stopped after smoke start)"
} else {
    $err = Get-Content (Join-Path $env:TEMP "fd-mcp-prewarm.err") -ErrorAction SilentlyContinue
    $joined = ($err | Select-Object -First 15) -join "`n"
    if ($joined -match "Starting Freshdesk MCP server") {
        Write-Host "Package start OK"
    } elseif ($joined -match "FastMCP|mcp 2\.x") {
        throw "MCP dependency pin failed. Re-run this script. stderr:`n$joined"
    } else {
        Write-Host "Pre-warm exited; stderr preview:`n$joined"
    }
}

# ---------------------------------------------------------------------------
# 6) Optional live API verify
# ---------------------------------------------------------------------------
if (-not $SkipVerify) {
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
Write-Host "DONE. Freshdesk MCP is configured." -ForegroundColor Green
Write-Host ""
Write-Host "Required next step for YOU:"
Write-Host "  1. In Cursor: Command Palette -> Developer: Reload Window"
Write-Host "  2. Settings -> MCP -> confirm freshdesk-mcp is enabled / green"
Write-Host "  3. Ask the agent to call get_agents (page 1, per_page 1)"
Write-Host ""
Write-Host "Do NOT set FRESHDESK_DOMAIN to supportdesk.corebridge.net (browser only; API 404s)."
Write-Host "Do NOT remove the --with mcp[cli]>=1.3.0,<2 pin (mcp 2.x breaks the server)."
