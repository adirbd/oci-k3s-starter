#!/usr/bin/env pwsh
# Fetch the kubeconfig and open every UI at once. Windows PowerShell / pwsh.
#
# The PowerShell twin of connect.sh. It exists because the obvious translations of the
# shell one are wrong on Windows: there is no `sed`, `base64 -d` is not a command, and
# `export FOO=bar` is `$env:FOO = 'bar'`.
param(
    [string]$IP,
    [string]$KubeconfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'kubeconfig')
)

$ErrorActionPreference = 'Stop'

if (-not $IP) {
    Push-Location (Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform')
    $IP = (tofu output -raw public_ip)
    Pop-Location
}

if (-not (Test-Path $KubeconfigPath)) {
    Write-Host "fetching kubeconfig from $IP"
    # 127.0.0.1 is correct on the box and useless from here. -replace is PowerShell's sed.
    (ssh "ubuntu@$IP" 'sudo cat /etc/rancher/k3s/k3s.yaml') -replace '127\.0\.0\.1', $IP |
        Set-Content -Path $KubeconfigPath -Encoding utf8
}
$env:KUBECONFIG = $KubeconfigPath

kubectl get nodes
if ($LASTEXITCODE -ne 0) {
    Write-Error "cluster not reachable yet — see docs/troubleshooting.md"
    exit 1
}

Write-Host ""
Write-Host "opening port-forwards (close this window to stop them):"
Write-Host "  Homepage   http://localhost:3000"
Write-Host "  Argo CD    https://localhost:8080   (user: admin)"
Write-Host "  Grafana    http://localhost:3001    (admin/admin)"
Write-Host "  podinfo    http://localhost:9898"
Write-Host ""

# base64 -d does not exist on Windows; .NET does the decode.
$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>$null
if ($b64) {
    $pw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    Write-Host "Argo CD password: $pw"
} else {
    Write-Host "Argo CD password: (secret not created yet)"
}
Write-Host ""

$jobs = @(
    @{ ns = 'homepage';      svc = 'svc/homepage';            ports = '3000:3000' },
    @{ ns = 'argocd';        svc = 'svc/argocd-server';       ports = '8080:443'  },
    @{ ns = 'observability'; svc = 'svc/vm-stack-grafana';    ports = '3001:80'   },
    @{ ns = 'sample';        svc = 'svc/sample-podinfo';      ports = '9898:9898' }
) | ForEach-Object {
    Start-Process -NoNewWindow -PassThru kubectl `
        -ArgumentList "-n", $_.ns, "port-forward", $_.svc, $_.ports
}

try   { Wait-Process -Id $jobs.Id }
finally { $jobs | ForEach-Object { Stop-Process -Id $_.Id -ErrorAction SilentlyContinue } }
