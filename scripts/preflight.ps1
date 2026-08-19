#!/usr/bin/env pwsh
# Catch, in seconds, the things that otherwise fail twenty minutes into an apply.
# Windows twin of preflight.sh — see that file for why each check exists (#14).
$ErrorActionPreference = 'Continue'
Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform')
$fail = 0
function Ok  ($m) { Write-Host "  OK    $m" }
function Bad ($m) { Write-Host "  FAIL  $m"; $script:fail = 1 }
function Warn($m) { Write-Host "  WARN  $m" }

Write-Host "preflight:"

foreach ($t in 'tofu','kubectl','oci','git') {
    if (Get-Command $t -ErrorAction SilentlyContinue) { Ok "$t installed" }
    else { Bad "$t not found. After winget, CLOSE THIS WINDOW and open a new one - PATH is only picked up by new shells." }
}

if (-not (Test-Path 'terraform.tfvars')) {
    Bad "terraform\terraform.tfvars does not exist. Copy terraform.tfvars.example to it."
} else {
    $out = tofu validate -no-color 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { Ok "terraform config and tfvars parse" }
    else {
        Bad "terraform will not parse:"
        Write-Host ($out -split "`n" | ForEach-Object { "        $_" } | Out-String)
        Write-Host "        NOTE: 'Function calls not allowed' means a .tfvars holds literal"
        Write-Host "        values only - paste the SSH key content, do not use file()."
    }
}

$profile = 'DEFAULT'
if (Test-Path 'terraform.tfvars') {
    $m = Select-String -Path 'terraform.tfvars' -Pattern '^\s*oci_config_profile\s*=\s*"(.*)"'
    if ($m) { $profile = $m.Matches[0].Groups[1].Value }
}
oci session validate --profile $profile *> $null
if ($LASTEXITCODE -eq 0) { Ok "OCI session for profile '$profile' is valid" }
else { Bad "OCI session for profile '$profile' is expired or missing. Fix: oci session refresh --profile $profile . An expired session fails PART WAY through an apply." }

if (Test-Path 'terraform.tfvars') {
    $tf = Get-Content 'terraform.tfvars' -Raw
    if ($tf -match 'enable_cloudflare\s*=\s*true' -and $tf -match 'access_allowed_emails') {
        $acct = if ($tf -match 'cf_account_id\s*=\s*"(.*)"') { $Matches[1] } else { $null }
        $tok  = if ($env:TF_VAR_cf_api_token) { $env:TF_VAR_cf_api_token }
                elseif ($tf -match 'cf_api_token\s*=\s*"(.*)"') { $Matches[1] } else { $null }
        if ($acct -and $tok) {
            try {
                $r = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$acct/access/apps" `
                        -Headers @{ Authorization = "Bearer $tok" } -ErrorAction Stop
                if ($r.success) { Ok "Cloudflare Access is enabled" }
            } catch {
                if ("$_" -match 'not_enabled') {
                    Bad "Cloudflare Access is NOT enabled on this account. Terraform cannot switch it on. Enable it once at https://one.dash.cloudflare.com, then apply."
                } else { Warn "could not confirm Cloudflare Access. Not blocking." }
            }
        } else { Warn "enable_cloudflare is on but account id / token not readable here - skipping the Access check." }
    }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ready: tofu apply" } else { Write-Host "fix the FAIL lines above before applying." }
Pop-Location
exit $fail
