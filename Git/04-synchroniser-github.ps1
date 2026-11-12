
# ==========================================
# OUTIL PERSONNEL - SYNCHRONISATION GITHUB
# ==========================================
# Fetch, pull et push securises
# Pas de force push ni de merge automatique
# ==========================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== SYNCHRONISATION GIT / GITHUB ===" -ForegroundColor Cyan

# 1. Verifier Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git est introuvable."
}

# 2. Identifier le depot
$repoRoot = & git rev-parse --show-toplevel 2>$null

if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    throw "Aucun depot Git detecte."
}

$repoRoot = ($repoRoot | Select-Object -First 1).Trim()

# 3. Verifier la branche
$branch = & git -C $repoRoot branch --show-current

if ($LASTEXITCODE -ne 0 -or -not $branch) {
    throw "Aucune branche active. HEAD detache ?"
}

$branch = $branch.Trim()

# 4. Verifier le depot distant
& git -C $repoRoot remote get-url origin

if ($LASTEXITCODE -ne 0) {
    throw "Aucun depot distant origin configure."
}

# 5. Verifier la branche suivie
$upstream = & git -C $repoRoot rev-parse `
    --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null

if ($LASTEXITCODE -ne 0 -or -not $upstream) {
    throw "Aucune branche distante suivie. Configuration manuelle necessaire."
}

$upstream = $upstream.Trim()

if ($upstream -ne "origin/$branch") {
    throw "Branche suivie inattendue : $upstream. Verification manuelle necessaire."
}

Write-Host ""
Write-Host "Projet : $repoRoot" -ForegroundColor Yellow
Write-Host "Branche : $branch"
Write-Host "Suivi : $upstream"

# 6. Verifier les modifications locales
$changes = @(& git -C $repoRoot status --porcelain)

if ($LASTEXITCODE -ne 0) {
    throw "Impossible de lire les modifications locales."
}

$dirty = $changes.Count -gt 0

if ($dirty) {
    Write-Host ""
    Write-Host "ATTENTION : modifications non commitees." -ForegroundColor Yellow
    $changes | ForEach-Object { Write-Host $_ }
    Write-Host "Elles ne seront pas incluses dans un push."
}

# 7. Actualiser les informations distantes
Write-Host ""
Write-Host "=== RECUPERATION DES INFORMATIONS ===" -ForegroundColor Cyan

& git -C $repoRoot fetch origin

if ($LASTEXITCODE -ne 0) {
    throw "Echec du fetch. Connexion ou authentification a verifier."
}

# 8. Comparer les commits
$counts = & git -C $repoRoot rev-list `
    --left-right --count 'HEAD...@{upstream}'

if ($LASTEXITCODE -ne 0) {
    throw "Impossible de comparer les branches."
}

$parts = $counts.Trim() -split '\s+'

$ahead = [int]$parts[0]
$behind = [int]$parts[1]

Write-Host ""
Write-Host "=== ETAT DE SYNCHRONISATION ===" -ForegroundColor Cyan
Write-Host "Commits locaux a envoyer : $ahead"
Write-Host "Commits distants a recuperer : $behind"

# 9. Divergence
if ($ahead -gt 0 -and $behind -gt 0) {
    Write-Host ""
    Write-Host "Branches divergentes !" -ForegroundColor Red
    Write-Host "Intervention manuelle necessaire."
    Write-Host "Aucune synchronisation effectuee."
    exit 1
}

# 10. Depot deja synchronise
if ($ahead -eq 0 -and $behind -eq 0) {
    Write-Host ""
    Write-Host "Git et GitHub sont synchronises." -ForegroundColor Green

    if ($dirty) {
        Write-Host "Des modifications locales restent a commiter." -ForegroundColor Yellow
    }

    exit 0
}

# 11. Recuperer les commits distants
if ($behind -gt 0) {
    if ($dirty) {
        Write-Host ""
        Write-Host "Pull refuse : modifications locales presentes." -ForegroundColor Red
        Write-Host "Commite ou mets de cote tes changements avant."
        exit 1
    }

    Write-Host ""
    $confirm = Read-Host "Effectuer un pull fast-forward ? (O/N)"

    if ($confirm.Trim().ToUpperInvariant() -ne "O") {
        Write-Host "Pull annule."
        exit 0
    }

    & git -C $repoRoot pull --ff-only origin $branch

    if ($LASTEXITCODE -ne 0) {
        throw "Pull impossible. Verifie le depot."
    }

    Write-Host "Pull effectue avec succes." -ForegroundColor Green
}

# 12. Envoyer les commits locaux
if ($ahead -gt 0) {
    Write-Host ""
    Write-Host "=== COMMITS A ENVOYER ===" -ForegroundColor Cyan

    & git -C $repoRoot log --oneline '@{upstream}..HEAD'

    Write-Host ""
    $confirm = Read-Host "Envoyer ces commits sur GitHub ? (O/N)"

    if ($confirm.Trim().ToUpperInvariant() -ne "O") {
        Write-Host "Push annule."
        exit 0
    }

    & git -C $repoRoot push origin $branch

    if ($LASTEXITCODE -ne 0) {
        throw "Echec du push."
    }

    Write-Host "Push effectue avec succes." -ForegroundColor Green
}

# 13. Verification finale
Write-Host ""
Write-Host "=== STATUT FINAL ===" -ForegroundColor Cyan

& git -C $repoRoot status --short --branch

Write-Host ""
Write-Host "Operation terminee !" -ForegroundColor Green
