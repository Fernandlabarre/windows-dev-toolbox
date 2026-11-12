
# ==========================================
# OUTIL PERSONNEL - ANALYSE GIT
# ==========================================
# Analyse le depot Git du dossier courant
# Sans modifier le projet
# ==========================================

Write-Host ""
Write-Host "=== ANALYSE DU DEPOT GIT ===" -ForegroundColor Cyan

# Verifier Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERREUR : Git est introuvable." -ForegroundColor Red
    exit 1
}

# Detecter le projet courant
$projectPath = (Get-Location).Path

Write-Host ""
Write-Host "Dossier courant : $projectPath" -ForegroundColor Yellow

# Verifier la presence d'un depot Git
$repoRoot = & git rev-parse --show-toplevel 2>$null

if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    Write-Host ""
    Write-Host "Aucun depot Git detecte ici." -ForegroundColor Red
    exit 1
}

Write-Host "Depot Git : $repoRoot" -ForegroundColor Green

# Etat du depot
Write-Host ""
Write-Host "=== BRANCHE ET MODIFICATIONS ===" -ForegroundColor Cyan

& git -C $repoRoot status --short --branch

if ($LASTEXITCODE -ne 0) {
    Write-Host "Impossible de lire le statut Git." -ForegroundColor Red
    exit 1
}

# Dernier commit
Write-Host ""
Write-Host "=== DERNIER COMMIT ===" -ForegroundColor Cyan

& git -C $repoRoot log -1 --format="%h - %s"

if ($LASTEXITCODE -ne 0) {
    Write-Host "Aucun commit disponible." -ForegroundColor Yellow
}

# Depots distants
Write-Host ""
Write-Host "=== DEPOTS DISTANTS ===" -ForegroundColor Cyan

$remotes = @(& git -C $repoRoot remote -v)

if ($remotes.Count -eq 0) {
    Write-Host "Aucun depot distant configure." -ForegroundColor Yellow
}
else {
    $remotes | ForEach-Object {
        Write-Host $_
    }
}

Write-Host ""
Write-Host "=== ANALYSE TERMINEE ===" -ForegroundColor Green
