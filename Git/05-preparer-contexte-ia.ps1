# ==========================================
# OUTIL PERSONNEL - PREPARATION CONTEXTE IA
# ==========================================
# Decouper les diffs Git pour Ollama
# Lecture seule - aucun commit ou push
# ==========================================

param(
    [string]$RevisionRange = "",

    [ValidateRange(1000, 12000)]
    [int]$MaxChars = 6000,

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

# 1. Identifier le depot Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git est introuvable."
}

$repoRoot = & git rev-parse --show-toplevel 2>$null

if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    throw "Aucun depot Git detecte."
}

$repoRoot = ($repoRoot | Select-Object -First 1).Trim()

# 2. Choisir la source des modifications
if ([string]::IsNullOrWhiteSpace($RevisionRange)) {
    $selection = @("--cached")
    $sourceLabel = "Fichiers prepares"
}
else {
    $selection = @($RevisionRange)
    $sourceLabel = $RevisionRange
}

$common = @(
    "-c", "core.quotepath=false",
    "-C", $repoRoot,
    "diff",
    "--no-ext-diff",
    "--no-textconv",
    "--no-renames",
    "--unified=2"
)

# 3. Recuperer les fichiers
$listArgs = $common + @("--name-only") + $selection

$paths = @(& git @listArgs)

if ($LASTEXITCODE -ne 0) {
    throw "Impossible de recuperer les fichiers."
}

Write-Host ""
Write-Host "=== PREPARATION DU CONTEXTE IA ===" -ForegroundColor Cyan
Write-Host "Depot : $repoRoot"
Write-Host "Source : $sourceLabel"
Write-Host "Maximum par segment : $MaxChars caracteres"

if ($paths.Count -eq 0) {
    Write-Host "Aucune modification a analyser." -ForegroundColor Yellow
    return
}

# 4. Initialiser les resultats
$allParts = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()

$totalChars = 0
$diffArgs = $common + $selection

foreach ($path in $paths) {

    # Recuperer le diff du fichier
    $lines = @(& git @diffArgs -- $path)

    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de lire le diff : $path"
    }

    # Detecter les diffs binaires
    $binaryMarkers = @(
        $lines | Where-Object {
            $_ -match '^(Binary files |GIT binary patch)'
        }
    )

    if ($binaryMarkers.Count -gt 0) {
        Write-Warning "Fichier binaire non analyse : $path"
        [void]$skipped.Add($path)
        continue
    }

    # Detecter les lignes trop longues
    $longLines = @(
        $lines | Where-Object {
            $_.Length -gt $MaxChars
        }
    )

    if ($longLines.Count -gt 0) {
        Write-Warning "Ligne trop longue : $path"
        [void]$skipped.Add($path)
        continue
    }

    $fileText = $lines -join "`n"
    $totalChars += $fileText.Length

    # 5. Decouper le diff sans perdre de lignes
    $parts = [System.Collections.Generic.List[string]]::new()
    $current = [System.Collections.Generic.List[string]]::new()

    $currentLength = 0

    foreach ($line in $lines) {

        $lineLength = $line.Length

        if ($current.Count -gt 0) {
            $lineLength++
        }

        if (
            $current.Count -gt 0 -and
            ($currentLength + $lineLength) -gt $MaxChars
        ) {
            [void]$parts.Add(($current -join "`n"))
            $current.Clear()
            $currentLength = 0
        }

        [void]$current.Add($line)

        $currentLength += $line.Length

        if ($current.Count -gt 1) {
            $currentLength++
        }
    }

    if ($current.Count -gt 0) {
        [void]$parts.Add(($current -join "`n"))
    }

    # Verifier que le decoupage conserve le texte
    $reconstructed = $parts -join "`n"

    if ($reconstructed -cne $fileText) {
        throw "Perte de contenu detectee : $path"
    }

    # 6. Enregistrer les segments
    for ($i = 0; $i -lt $parts.Count; $i++) {

        [void]$allParts.Add([pscustomobject]@{
            Path       = $path
            Part       = $i + 1
            TotalParts = $parts.Count
            Characters = $parts[$i].Length
            Diff       = $parts[$i]
        })
    }

    Write-Host ""
    Write-Host "Fichier : $path" -ForegroundColor Yellow
    Write-Host "Taille : $($fileText.Length) caracteres"
    Write-Host "Segments : $($parts.Count)"
}

# 7. Resume final
Write-Host ""
Write-Host "=== RESUME ===" -ForegroundColor Cyan

Write-Host "Fichiers detectes : $($paths.Count)"
Write-Host "Segments prepares : $($allParts.Count)"
Write-Host "Caracteres analyses : $totalChars"
Write-Host "Fichiers non analyses : $($skipped.Count)"

if ($skipped.Count -gt 0) {
    Write-Warning "Certains fichiers n'ont pas ete analyses."
}

Write-Host ""
Write-Host "Aucun fichier modifie." -ForegroundColor Green
Write-Host "Aucune requete Ollama effectuee." -ForegroundColor Green

# 8. Retourner les resultats si demande
if ($PassThru) {
    [pscustomobject]@{
        Repository   = $repoRoot
        Source       = $sourceLabel
        Segments     = $allParts.ToArray()
        SkippedFiles = $skipped.ToArray()
        TotalChars   = $totalChars
    }
}