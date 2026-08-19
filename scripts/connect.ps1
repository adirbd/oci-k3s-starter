#!/usr/bin/env pwsh
# Open an SSH tunnel to the cluster, then every UI at once. Windows PowerShell / pwsh.
#
# ⚠ THE TUNNEL IS NOT A CONVENIENCE, IT IS THE ONLY WAY IN.
# The security list opens exactly one inbound port: SSH. The Kubernetes API on 6443 is NOT
# reachable from your laptop, deliberately. kubectl talks to 127.0.0.1:6443 and this script
# forwards that down the SSH connection.
#
# The kubeconfig is therefore used AS FETCHED, keeping `server: https://127.0.0.1:6443`. An
# earlier version rewrote it to the public IP, which could not work: the port is closed, and
# k3s's API certificate carries a 127.0.0.1 SAN rather than the public address. (See #9.)
#
# Windows note: `ssh` ships with Windows 10/11 (OpenSSH client). If it is missing:
#   Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
param(
    [string]$IP,
    [string]$KubeconfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'kubeconfig'),
    [string]$SshUser = 'ubuntu'
)

$ErrorActionPreference = 'Stop'

if (-not $IP) {
    Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform')
    $IP = (tofu output -raw public_ip)
    Pop-Location
}

if (-not (Test-Path $KubeconfigPath)) {
    Write-Host "fetching kubeconfig from $IP"
    # No rewriting: 127.0.0.1 is correct, because everything goes through the tunnel below.
    ssh "$SshUser@$IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' |
        Set-Content -Path $KubeconfigPath -Encoding utf8
}
$env:KUBECONFIG = $KubeconfigPath

$procs = @()
try {
    Write-Host "opening SSH tunnel to the Kubernetes API (6443)"
    $procs += Start-Process -NoNewWindow -PassThru ssh `
        -ArgumentList '-N', '-L', '6443:127.0.0.1:6443', "$SshUser@$IP"

    # Wait for the tunnel instead of guessing at a sleep.
    $ready = $false
    foreach ($i in 1..30) {
        kubectl get --raw /readyz *> $null
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

    Write-Host ""
    Write-Host "opening port-forwards (close this window to stop them):"
    Write-Host "  Homepage   http://localhost:3000"
    Write-Host "  Argo CD    https://localhost:8080   (user: admin)"
    Write-Host "  Grafana    http://localhost:3001    (admin/admin)"
    Write-Host "  podinfo    http://localhost:9898"
    Write-Host ""

    # There is no `base64` on Windows; .NET does the decode.
    $b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>$null
    if ($b64) {
        Write-Host "Argo CD password: $([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)))"
    } else {
        Write-Host "Argo CD password: (secret not created yet)"
    }
    Write-Host ""

    $procs += @(
        @{ ns = 'homepage';      svc = 'svc/homepage';         ports = '3000:3000' },
        @{ ns = 'argocd';        svc = 'svc/argocd-server';    ports = '8080:443'  },
        @{ ns = 'observability'; svc = 'svc/vm-stack-grafana'; ports = '3001:80'   },
        @{ ns = 'sample';        svc = 'svc/sample-podinfo';   ports = '9898:9898' }
    ) | ForEach-Object {
        Start-Process -NoNewWindow -PassThru kubectl `
            -ArgumentList "-n", $_.ns, "port-forward", $_.svc, $_.ports
    }

    Wait-Process -Id ($procs | ForEach-Object { $_.Id })
}
finally {
    $procs | ForEach-Object { Stop-Process -Id $_.Id -ErrorAction SilentlyContinue }
}
