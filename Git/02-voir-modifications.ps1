
# ==========================================
# OUTIL PERSONNEL - MODIFICATIONS GIT
# ==========================================
# Visualiser les changements avant un commit
# Lecture seule - aucune modification
# ==========================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== MODIFICATIONS DU PROJET ===" -ForegroundColor Cyan

# Identifier le depot Git courant
$projectPath = (Get-Location).Path

$repoRoot = & git -C $projectPath rev-parse --show-toplevel 2>$null

if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    Write-Host "Aucun depot Git detecte." -ForegroundColor Red
    exit 1
}

$repoRoot = ($repoRoot | Select-Object -First 1).Trim()

Write-Host ""
Write-Host "Projet : $repoRoot" -ForegroundColor Yellow

# 1. Statut general
Write-Host ""
Write-Host "=== FICHIERS MODIFIES ===" -ForegroundColor Cyan

& git -C $repoRoot status --short

# 2. Changements non prepares
Write-Host ""
Write-Host "=== MODIFICATIONS NON PREPAREES ===" -ForegroundColor Cyan

& git -C $repoRoot diff --stat

# 3. Changements prepares
Write-Host ""
Write-Host "=== MODIFICATIONS PREPAREES ===" -ForegroundColor Cyan

& git -C $repoRoot diff --cached --stat

# 4. Nouveaux fichiers non suivis
Write-Host ""
Write-Host "=== NOUVEAUX FICHIERS ===" -ForegroundColor Cyan

& git -C $repoRoot ls-files --others --exclude-standard

# 5. Verification des differences
Write-Host ""
Write-Host "=== VERIFICATION DU FORMAT ===" -ForegroundColor Cyan

& git -C $repoRoot diff --check
$workingCheck = $LASTEXITCODE

& git -C $repoRoot diff --cached --check
$stagedCheck = $LASTEXITCODE

if ($workingCheck -eq 0 -and $stagedCheck -eq 0) {
    Write-Host "Aucune erreur de format detectee." -ForegroundColor Green
}
else {
    Write-Host "Attention : anomalies de format detectees." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== ANALYSE TERMINEE ===" -ForegroundColor Green
Write-Host "Aucune modification effectuee." -ForegroundColor Gray
