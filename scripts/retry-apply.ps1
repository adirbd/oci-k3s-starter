#!/usr/bin/env pwsh
# Keep asking Oracle for the instance until a machine is free. Windows twin of
# retry-apply.sh — see that file for the full reasoning.
#
# "Out of host capacity" is the NORMAL first answer when asking for a free Ampere A1. It is
# transient, there is no queue and no notification, and the only mechanism Oracle offers is
# asking again.
#
# Rotates availability domains, because capacity is tracked per-AD and retrying the same one
# is asking the same full rack repeatedly. Backs off exponentially on 429 specifically —
# Oracle throttles LaunchInstance on purpose. Stops on anything that is not a capacity or
# throttle failure, so a bad variable or an expired session is not buried in a retry loop.
#
#   ./scripts/retry-apply.ps1
#   $env:INTERVAL=600; ./scripts/retry-apply.ps1
#   ./scripts/retry-apply.ps1 -ExtraArgs @('-var','ocpus=1','-var','memory_gb=6')
param(
    [int]$Interval    = $(if ($env:INTERVAL)     { [int]$env:INTERVAL }     else { 300 }),
    [int]$MaxAttempts = $(if ($env:MAX_ATTEMPTS) { [int]$env:MAX_ATTEMPTS } else { 0 }),
    [string]$Tf       = $(if ($env:TF)           { $env:TF }                else { 'tofu' }),
    [string[]]$ExtraArgs = @()
)

Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform')
try {
    $attempt = 0
    $throttleBackoff = $Interval

    while ($true) {
        $attempt++
        $ad = ($attempt - 1) % 3

        Write-Host "-- attempt $attempt (availability domain index $ad) -- $(Get-Date -Format HH:mm:ss)"

        $out = & $Tf apply -auto-approve -input=false -var "availability_domain_index=$ad" @ExtraArgs 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "instance created on attempt $attempt."
            Write-Host "Next: ./scripts/connect.ps1   (k3s may take a few more minutes)"
            exit 0
        }

        if ($out -imatch 'out of host capacity|OutOfHostCapacity') {
            Write-Host "   no capacity in that AD - retrying in $Interval s"
            $throttleBackoff = $Interval
            Start-Sleep -Seconds $Interval
        }
        elseif ($out -imatch '429|TooManyRequests|rate limit') {
            $throttleBackoff = [Math]::Min($throttleBackoff * 2, 3600)
            Write-Host "   throttled by Oracle - backing off $throttleBackoff s"
            Start-Sleep -Seconds $throttleBackoff
        }
        else {
            Write-Host ""
            Write-Host "This is not a capacity failure - stopping so you can read it:"
            Write-Host ($out -split "`n" | Select-Object -Last 30 | Out-String)
            exit 1
        }

        if ($MaxAttempts -gt 0 -and $attempt -ge $MaxAttempts) {
            Write-Host "reached MaxAttempts=$MaxAttempts without success."
            exit 1
        }
    }
}
finally { Pop-Location }
