#!/usr/bin/env pwsh
# Catch, in seconds, the things that otherwise fail twenty minutes into an apply.
# Windows twin of preflight.sh — see that file for why each check exists (#14).
$ErrorActionPreference = 'Continue'
Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform')
$fail = 0
# OpenTofu or Terraform — both are supported. Set $env:TF = 'terraform' to force it.
$TF = if ($env:TF) { $env:TF }
      elseif (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' }
      else { 'terraform' }
function Ok  ($m) { Write-Host "  OK    $m" }
function Bad ($m) { Write-Host "  FAIL  $m"; $script:fail = 1 }
function Warn($m) { Write-Host "  WARN  $m" }

Write-Host "preflight:"

foreach ($t in $TF,'kubectl','oci','git') {
    if (Get-Command $t -ErrorAction SilentlyContinue) { Ok "$t installed" }
    else { Bad "$t not found. After winget, CLOSE THIS WINDOW and open a new one - PATH is only picked up by new shells." }
}

if (-not (Test-Path 'terraform.tfvars')) {
    Bad "terraform\terraform.tfvars does not exist. Copy terraform.tfvars.example to it."
} else {
    $out = & $TF validate -no-color 2>&1 | Out-String
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
    # (?m)^\s* anchors each pattern to a line start, like the .sh twin's grep '^\s*...'.
    # Unanchored, the COMMENTED-OUT rung-2 example lines shipped in tfvars.example match
    # too, and this check fires with the placeholder "..." as an account id.
    if ($tf -match '(?m)^\s*enable_cloudflare\s*=\s*true' -and $tf -match '(?m)^\s*access_allowed_emails') {
        $acct = if ($tf -match '(?m)^\s*cf_account_id\s*=\s*"(.*)"') { $Matches[1] } else { $null }
        # CLOUDFLARE_API_TOKEN is the provider's own variable and what the docs recommend —
        # mirror the provider's order: the terraform variable first, then its native env var.
        $tok  = if ($env:TF_VAR_cf_api_token) { $env:TF_VAR_cf_api_token }
                elseif ($tf -match '(?m)^\s*cf_api_token\s*=\s*"(.*)"') { $Matches[1] }
                elseif ($env:CLOUDFLARE_API_TOKEN) { $env:CLOUDFLARE_API_TOKEN } else { $null }
        if ($acct -and $tok) {
            try {
                $r = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$acct/access/apps" `
                        -Headers @{ Authorization = "Bearer $tok" } -ErrorAction Stop
                if ($r.success) { Ok "Cloudflare Access is enabled" }
                else { Warn "could not confirm Cloudflare Access (token scope, or network). Not blocking." }
            } catch {
                # Windows PowerShell 5.1 puts the HTTP response body in ErrorDetails.Message,
                # not in the exception text — "$_" alone misses the not_enabled code there.
                $body = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { "$_" }
                if ($body -match 'not_enabled') {
                    Bad "Cloudflare Access is NOT enabled on this account. Terraform cannot switch it on. Enable it once at https://one.dash.cloudflare.com, then apply."
                } else { Warn "could not confirm Cloudflare Access. Not blocking." }
            }
        } else { Warn "enable_cloudflare is on but account id / token not readable here - skipping the Access check." }
    }
}

# A real fork's setup assistant invented terraform\.env for the Cloudflare token.
# Nothing reads it - terraform has no native .env support and no script here sources one.
if (Test-Path '.env') {
    Warn ".env exists but NOTHING reads it. Put the token in the environment for this session instead: `$env:CLOUDFLARE_API_TOKEN = '...' (or TF_VAR_cf_api_token) - and do not keep tokens in a file."
}

# gitops_repo_url moves the ROOT app, but the self-sourcing child Applications carry
# their own repoURL. If they disagree, edits to what they deploy never land (#13).
if (Test-Path 'terraform.tfvars') {
    $repoUrl = if ($tf -match '(?m)^\s*gitops_repo_url\s*=\s*"(.*)"') { $Matches[1] } else { $null }
    if ($repoUrl) {
        Get-ChildItem ..\kubernetes\applications\*.yaml, ..\kubernetes\optional\*.yaml -ErrorAction SilentlyContinue | ForEach-Object {
            $y = Get-Content $_.FullName -Raw
            if ($y -match '(?m)^\s*path: kubernetes/' -and $y -notmatch [regex]::Escape("repoURL: $repoUrl")) {
                Warn "$($_.Name) sources a different repo than gitops_repo_url. Run scripts/set-gitops-repo.sh (or edit its repoURL) and commit - otherwise your changes to it never deploy."
            }
        }
    }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ready: $TF apply" } else { Write-Host "fix the FAIL lines above before applying." }
Pop-Location
exit $fail
