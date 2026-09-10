#!/usr/bin/env pwsh
# Open an SSH tunnel to the cluster and launch k9s over it. Windows PowerShell / pwsh.
#
# ⚠ THE TUNNEL IS NOT A CONVENIENCE, IT IS THE ONLY WAY IN.
# The security list opens exactly one inbound port: SSH. The Kubernetes API on 6443 is NOT
# reachable from your laptop, deliberately. k9s (like kubectl) talks to 127.0.0.1:6443 and
# this script forwards that down the SSH connection.
#
# This is also why the kubeconfig is used AS FETCHED, keeping `server: https://127.0.0.1:6443`.
# An earlier version rewrote it to the public IP, which could not work: the port is closed,
# and k3s's API certificate carries a 127.0.0.1 SAN rather than the public address. (See #9.)
#
# One command, then quit k9s and the tunnel closes with it. If you also want the web UIs
# (Argo CD, Grafana, Homepage), run ../scripts/connect.ps1 instead.
param(
    [string]$IP,
    [string]$KubeconfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'kubeconfig'),
    [string]$SshUser = 'ubuntu',
    [string[]]$K9sArguments = @()
)

$ErrorActionPreference = 'Stop'

# OpenTofu or Terraform — both are supported. Set $env:TF = 'terraform' to force it.
$TF = if ($env:TF) { $env:TF }
      elseif (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' }
      else { 'terraform' }

if (-not $IP) {
    Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform')
    $IP = (& $TF output -raw public_ip)
    Pop-Location
}

# Length check, not just existence: an earlier failed fetch (k3s not up yet) must not
# leave an empty file behind that every later run trusts. Only write on a good fetch.
# Also detect a stale kubeconfig that points at the wrong server (not 127.0.0.1).
$stale = $false
if (-not (Test-Path $KubeconfigPath) -or (Get-Item $KubeconfigPath).Length -eq 0) {
    $stale = $true
} elseif (-not (Select-String -Path $KubeconfigPath -Pattern 'server: https://127\.0\.0\.1:6443' -Quiet)) {
    Write-Host "kubeconfig does not point at 127.0.0.1 (an old version rewrote these) - refetching"
    $stale = $true
}
if ($stale) {
    Write-Host "fetching kubeconfig from $IP"
    $kc = ssh "$SshUser@$IP" 'sudo cat /etc/rancher/k3s/k3s.yaml'
    if ($LASTEXITCODE -ne 0 -or -not $kc) {
        Write-Host ""
        Write-Host "could not fetch the kubeconfig - k3s is probably still installing."
        Write-Host "  watch it:   ssh $SshUser@$IP 'sudo journalctl -u k3s-starter-bootstrap -f'"
        Write-Host "  then re-run this script."
        exit 1
    }
    Set-Content -Path $KubeconfigPath -Value $kc -Encoding utf8
}
$env:KUBECONFIG = $KubeconfigPath

$tunnel = $null
try {
    Write-Host "opening SSH tunnel to the Kubernetes API (6443)"
    $tunnel = Start-Process -NoNewWindow -PassThru ssh `
        -ArgumentList '-N', '-L', '6443:127.0.0.1:6443', "$SshUser@$IP"

    # Wait for the tunnel instead of guessing at a sleep.
    $ready = $false
    foreach ($i in 1..30) {
        # Windows PowerShell 5.1 turns a native program's stderr into a terminating
        # NativeCommandError when ErrorActionPreference is Stop. cmd keeps an expected
        # connection refusal during tunnel startup from aborting this retry loop.
        cmd.exe /d /c "kubectl get --raw /readyz >nul 2>&1"
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }

    if (-not $ready) {
        Write-Host ""
        Write-Host "the cluster is not answering through the tunnel."
        Write-Host "  - is the box finished booting?  ssh $SshUser@$IP 'sudo journalctl -u k3s-starter-bootstrap -n 30'"
        Write-Host "  - see docs/troubleshooting.md"
        exit 1
    }

    kubectl get nodes

    # Use the executable directly: the PowerShell profile may define a `k9s` function that
    # calls this wrapper, so ordinary command lookup here would recurse back into the script.
    $k9sExe = Join-Path $env:LOCALAPPDATA 'Programs\k9s\k9s.exe'
    if (-not (Test-Path $k9sExe)) {
        $k9sCmd = Get-Command k9s -CommandType Application -ErrorAction SilentlyContinue
        if ($k9sCmd) { $k9sExe = $k9sCmd.Source }
    }
    if (-not $k9sExe) {
        Write-Host ""
        Write-Host "k9s is not installed. Get it with:"
        Write-Host "  winget install derailed.k9s        # or:"
        Write-Host "  scoop install k9s                 # or download k9s_Windows_amd64.zip from"
        Write-Host "  https://github.com/derailed/k9s/releases and put k9s.exe on your PATH"
        Write-Host "the tunnel is still open in the background - close this window to stop it."
        Wait-Process -Id $tunnel.Id
        return
    }

    Write-Host ""
    Write-Host "launching k9s (quit k9s to close the tunnel)"
    & $k9sExe @K9sArguments
}
finally {
    if ($tunnel) { Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue }
}
