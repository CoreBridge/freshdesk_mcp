# Parse + lint + Pester checks for the Windows installer.
#   pwsh -NoProfile -File tests/installer/Invoke-InstallerChecks.ps1
# Works on Windows PowerShell 5.1 and PowerShell 7+. Installs Pester 5 and PSScriptAnalyzer for the
# current user if they are missing (needs PSGallery access). Exits non-zero on any failure.

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$installer = Join-Path $root "install-corebridge-freshdesk-mcp.ps1"
$failed = $false

Write-Host "== Parse: $installer"
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "PARSE ERROR line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    $failed = $true
} else {
    Write-Host "Parse OK ($($tokens.Count) tokens)"
}

foreach ($module in @(@{ Name = "PSScriptAnalyzer"; Min = "1.21.0" }, @{ Name = "Pester"; Min = "5.5.0" })) {
    if (-not (Get-Module -ListAvailable -Name $module.Name | Where-Object { $_.Version -ge [version]$module.Min })) {
        Install-Module $module.Name -MinimumVersion $module.Min -Scope CurrentUser -Force -SkipPublisherCheck
    }
}

Write-Host "== PSScriptAnalyzer (Error + Warning)"
Import-Module PSScriptAnalyzer
# Write-Host is the installer's UI; the global-var/ShouldProcess rules do not fit a one-shot script.
$excluded = @("PSAvoidUsingWriteHost", "PSUseShouldProcessForStateChangingFunctions", "PSAvoidUsingInvokeExpression")
$findings = Invoke-ScriptAnalyzer -Path $installer -Severity Error, Warning -ExcludeRule $excluded
if ($findings) {
    $findings | Format-Table -AutoSize RuleName, Severity, Line, Message | Out-String -Width 200 | Write-Host
    $failed = $true
} else {
    Write-Host "PSScriptAnalyzer: no findings"
}

Write-Host "== Pester"
Import-Module Pester -MinimumVersion 5.5.0
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root "tests/installer"
$config.Run.PassThru = $true
$config.Output.Verbosity = "Detailed"
$result = Invoke-Pester -Configuration $config
Write-Host "Pester: $($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped"
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { $failed = $true }

if ($failed) { exit 1 }
Write-Host "All installer checks passed." -ForegroundColor Green
