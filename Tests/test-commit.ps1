# Depots Git factices uniquement ; aucun commit et aucun push.
$ErrorActionPreference = 'Stop'

function Assert-CommitTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Write-CommitFixture([string]$Path, [string]$Content) {
    $parent = [IO.Directory]::GetParent($Path)
    if ($parent -and -not $parent.Exists) { [void][IO.Directory]::CreateDirectory($parent.FullName) }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Start-CommitFixtureProcess([Diagnostics.ProcessStartInfo]$Start) {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $inputEncoding = $Start.GetType().GetProperty('StandardInputEncoding')
    if ($inputEncoding) {
        $inputEncoding.SetValue($Start, $utf8, $null)
        return [Diagnostics.Process]::Start($Start)
    }

    $previous = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = $utf8
        return [Diagnostics.Process]::Start($Start)
    }
    finally { [Console]::InputEncoding = $previous }
}

function Invoke-CommitFixture([string]$Project, [string]$Selection, [string[]]$ExpectedPaths, [int]$ExtraFileCount = 0) {
    [void][IO.Directory]::CreateDirectory($Project)
    & git -C $Project init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Initialisation Git factice impossible.' }

    Write-CommitFixture (Join-Path $Project 'alpha.txt') 'alpha'
    Write-CommitFixture (Join-Path $Project 'beta.txt') 'beta'
    Write-CommitFixture (Join-Path $Project 'dossier\fichier avec espaces.txt') 'gamma'
    for ($number = 1; $number -le $ExtraFileCount; $number++) {
        Write-CommitFixture (Join-Path $Project ('lot\fichier-{0:D3}.txt' -f $number)) ('extra-' + $number)
    }

    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $engine = Join-Path $PSHOME $engineName
    $scriptPath = Join-Path ([IO.Directory]::GetParent($PSScriptRoot).FullName) 'Git\03-creer-commit.ps1'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $engine
    $start.Arguments = '-NoProfile -File "' + $scriptPath + '"'
    $start.WorkingDirectory = $Project
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = Start-CommitFixtureProcess $start
    try {
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        foreach ($answer in @($Selection, 'O', 'N', 'test(commit): verifier la selection', 'N')) {
            $process.StandardInput.WriteLine($answer)
        }
        $process.StandardInput.Close()
        Assert-CommitTest ($process.WaitForExit(30000)) 'L assistant de commit factice ne termine pas.'
        $output = $outputTask.GetAwaiter().GetResult()
        $errors = $errorTask.GetAwaiter().GetResult()
        Assert-CommitTest ($process.ExitCode -eq 0) ('Echec de l assistant de commit : ' + $errors + $output)
    }
    finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }

    $staged = @(& git -c core.quotepath=false -C $Project diff --cached --name-only | Sort-Object)
    Assert-CommitTest ($LASTEXITCODE -eq 0) 'Lecture de l index Git factice impossible.'
    Assert-CommitTest (($staged -join "`n") -ceq (@($ExpectedPaths | Sort-Object) -join "`n")) ('Mauvaise selection preparee : ' + ($staged -join ', '))
    return $output
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git est requis pour ce test.' }
$testTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testTempParent ('scripts-perso-commit-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $extraPaths = @(1..202 | ForEach-Object { 'lot/fichier-{0:D3}.txt' -f $_ })
    $allPaths = @('alpha.txt', 'beta.txt', 'dossier/fichier avec espaces.txt') + $extraPaths
    $allOutput = Invoke-CommitFixture (Join-Path $testRoot 'tous') 't' $allPaths 202
    Assert-CommitTest ($allOutput.Contains('Tous les 205 fichiers detectes sont selectionnes.')) 'La confirmation de selection totale est absente.'
    Write-Host 'OK : T selectionne et prepare 205 fichiers en une seule saisie.'

    $partialOutput = Invoke-CommitFixture (Join-Path $testRoot 'partiel') '1,3' @('alpha.txt', 'dossier/fichier avec espaces.txt')
    Assert-CommitTest (-not $partialOutput.Contains('Tous les 3 fichiers detectes sont selectionnes.')) 'Une selection partielle est annoncee comme totale.'
    Write-Host 'OK : la selection partielle par numeros reste disponible.'
    Write-Host ('SUCCES - Assistant de commit / PowerShell ' + $PSVersionTable.PSVersion)
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Directory]::GetParent($resolvedRoot).FullName -ne $testTempParent -or
        -not [IO.Path]::GetFileName($resolvedRoot).StartsWith('scripts-perso-commit-')) { throw 'Nettoyage hors du dossier temporaire refuse.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
