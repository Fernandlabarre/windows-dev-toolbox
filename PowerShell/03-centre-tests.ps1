# Controles du projet, sans installation de dependances ni correction automatique.
param(
    [string]$Project = (Get-Location).Path,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
# Reutiliser la resolution npm, l'isolation des processus et le filtrage existants.
. (Join-Path $PSScriptRoot '02-gerer-serveurs-locaux.ps1') -Project $Project

function Get-LocalCheckOptions([string]$ProjectPath) {
    $manifest = Join-Path $ProjectPath 'package.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        $item = Get-Item -LiteralPath $manifest
        if ($item.Length -le 1048576 -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try {
                $package = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
                $fingerprint = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
                foreach ($entry in $package.scripts.PSObject.Properties) {
                    if ($entry.Name -cnotmatch '^(lint|check|typecheck|type-check|test|build)(:[a-zA-Z0-9_-]+)*$' -or
                        $entry.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Value)) { continue }
                    $blocked = ''
                    # Un --watch=false explicite reste un controle ponctuel.
                    $modeText = [regex]::Replace($entry.Value, '(?i)(^|\s)--watch(All)?(?:=|\s+)(false|0)(?=\s|$)', ' ')
                    if ($entry.Name -match '(^|:)(watch|ui|fix|write|update|headed)(:|$)' -or
                        $modeText -match '(?i)(^|\s)--(fix|write|updateSnapshot|update-snapshots|watch(All)?|ui|headed|interactive)([=\s]|$)' -or
                        $modeText -match '(?i)\b(vitest\s+(watch|dev)|nodemon)\b' -or
                        $modeText -match '(?i)\b(jest|vitest)\b[^;&|\r\n]*\s-u(\s|$)' -or
                        $modeText -match '(?i)\b(prettier|tsc|vitest)\b[^;&|\r\n]*\s-w(\s|$)') {
                        $blocked = 'Mode interactif, surveillance ou modification automatique'
                    }
                    if ($entry.Value -match '(?i)no test specified') { $blocked = 'Commande de test par defaut, sans vrais tests' }
                    [pscustomobject]@{ Id = 'npm:' + $entry.Name; Name = 'npm / ' + $entry.Name; Kind = 'npm'; Target = $entry.Name; Project = $ProjectPath; Source = $manifest; Fingerprint = $fingerprint; Blocked = $blocked }
                }
            }
            catch { Write-Host 'package.json non exploitable : controles npm non proposes.' -ForegroundColor Yellow }
        }
        else { Write-Host 'package.json trop volumineux ou lien symbolique : controles npm non proposes.' -ForegroundColor Yellow }
    }
    $seen = @{}
    foreach ($folderName in @('Tests', 'tests', 'test')) {
        $folder = Join-Path $ProjectPath $folderName
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        $directory = Get-Item -LiteralPath $folder
        if ($seen.ContainsKey($directory.FullName) -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $seen[$directory.FullName] = $true
        $files = @(Get-ChildItem -LiteralPath $directory.FullName -File)
        if (@($files | Where-Object { $_.Name -like 'test_*.py' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count -gt 0) {
            [pscustomobject]@{ Id = 'python:' + $directory.Name; Name = 'Python unittest / ' + $directory.Name; Kind = 'Python'; Target = $directory.FullName; Project = $ProjectPath; Source = ''; Fingerprint = ''; Blocked = '' }
        }
        foreach ($file in $files) {
            if ($file.Name -cmatch '^test-[a-zA-Z0-9_-]+\.ps1$' -and -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                [pscustomobject]@{ Id = 'ps:' + $directory.Name + '/' + $file.Name; Name = 'PowerShell / ' + $file.Name; Kind = 'PowerShell'; Target = $file.FullName; Project = $ProjectPath; Source = $file.FullName; Fingerprint = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; Blocked = '' }
            }
        }
    }
}

function Get-LocalCheckLaunch([object]$Check) {
    if ($Check.Blocked) { throw $Check.Blocked }
    if ($Check.Source -and ((Get-FileHash -LiteralPath $Check.Source -Algorithm SHA256).Hash -ne $Check.Fingerprint)) {
        throw 'La commande a change depuis la selection : relance la detection.'
    }
    switch ($Check.Kind) {
        'npm' { return Get-LocalNpmInvocation @('--silent', '--ignore-scripts', 'run', $Check.Target) }
        'Python' {
            $python = Find-LocalServerExecutable @('python.exe', 'python3.exe')
            if (-not $python) { throw 'Python est introuvable dans le PATH.' }
            return [pscustomobject]@{ Executable = $python; Arguments = @('-B', '-m', 'unittest', 'discover', '-s', $Check.Target, '-p', 'test_*.py', '-v') }
        }
        'PowerShell' { return [pscustomobject]@{ Executable = $Check.Target; Arguments = @() } }
        default { throw 'Type de controle inconnu.' }
    }
}

function Read-LocalCheckOutput([hashtable]$Capture, [switch]$Quiet) {
    [string]$message = $null
    while ([ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$message)) {
        $line = Protect-LocalServerLog $message.Substring(1) $Capture
        if ($null -eq $line) { continue }
        $testSummary = [regex]::Match($line, '^Ran (?<count>\d+) tests?\b')
        if ($testSummary.Success) { $Capture.TestCount = [int]$testSummary.Groups['count'].Value }
        if ($line -match '(?i)^NON VERIFIE\b|\bskipped=[1-9][0-9]*') { $Capture.Partial = $true }
        $Capture.Tail.Enqueue($line)
        while ($Capture.Tail.Count -gt 40) { $null = $Capture.Tail.Dequeue() }
        if (-not $Quiet) { Write-Host $line }
    }
}

function Invoke-LocalCheck {
    param([object]$Check, [ValidateRange(1, 3600)][int]$LimitSeconds = 300, [switch]$Quiet)
    $result = [pscustomobject]@{ Id = $Check.Id; Name = $Check.Name; Selected = $true; Status = 'Non execute'; Detail = ''; ExitCode = $null; Seconds = 0; Tail = @() }
    try { $launch = Get-LocalCheckLaunch $Check }
    catch { $result.Detail = $_.Exception.Message; return $result }
    Initialize-LocalServerRuntime
    $nativeArguments = @($launch.Arguments | ForEach-Object { ConvertTo-LocalServerLiteral ([string]$_) }) -join ' '
    $bootstrap = $script:LocalStartGateCode
    $bootstrap += @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$env:CI = 'true'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:FORCE_COLOR = '0'
$env:npm_config_yes = 'false'
$env:npm_config_update_notifier = 'false'
function global:Write-Host {
    [CmdletBinding()]
    param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Object,
          [object]$Separator = ' ', [ConsoleColor]$ForegroundColor,
          [ConsoleColor]$BackgroundColor, [switch]$NoNewline)
    [Console]::Out.WriteLine((@($Object) | ForEach-Object { [string]$_ }) -join [string]$Separator)
    [Console]::Out.Flush()
}
$global:LASTEXITCODE = 0
'@
    $bootstrap += "`ntry {`nSet-Location -LiteralPath " + (ConvertTo-LocalServerLiteral $Check.Project)
    if ($Check.Kind -eq 'PowerShell') {
        $bootstrap += "`n& " + (ConvertTo-LocalServerLiteral $launch.Executable)
    }
    else {
        # Windows PowerShell 5.1 traite stderr natif comme des ErrorRecord.
        # Les convertir en texte et se fier au code retour, y compris unittest.
        $bootstrap += "`n`$ErrorActionPreference = 'Continue'`n`$global:LASTEXITCODE = 127"
        $bootstrap += "`n& " + (ConvertTo-LocalServerLiteral $launch.Executable) + ' ' + $nativeArguments + ' 2>&1 | ForEach-Object { [Console]::Out.WriteLine([string]$_) }'
    }
    $bootstrap += "`nexit `$LASTEXITCODE`n} catch { [Console]::Error.WriteLine('Commande interrompue par une erreur PowerShell.'); exit 1 }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $capture = @{ SecretBlock = $false; TestCount = $null; Partial = $false; Tail = (New-Object 'System.Collections.Generic.Queue[string]') }
    $process = $null
    $timedOut = $false
    [string]$discard = $null
    while ([ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$discard)) { }
    [ScriptsPerso.ProcessRunner]::DroppedMessages = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [ScriptsPerso.ProcessRunner]::Launch((Join-Path $PSHOME $engineName), ('-NoProfile -NonInteractive -EncodedCommand ' + $encoded), $Check.Project)
        $process.StandardInput.Close()
        while ($true) {
            Read-LocalCheckOutput $capture -Quiet:$Quiet
            if ($process.HasExited) { break }
            if ($clock.Elapsed.TotalSeconds -ge $LimitSeconds) {
                $timedOut = $true
                [ScriptsPerso.ProcessRunner]::Stop($process)
                break
            }
            Start-Sleep -Milliseconds 50
        }
        [ScriptsPerso.ProcessRunner]::Release($process)
        if (-not $process.WaitForExit(5000)) { throw 'Fin du processus non confirmee.' }
        $process.WaitForExit()
        Read-LocalCheckOutput $capture -Quiet:$Quiet
        $result.ExitCode = $process.ExitCode
        if ($timedOut) { $result.Status = 'Echec'; $result.Detail = 'Delai maximal depasse : processus du controle arretes.' }
        elseif ($Check.Kind -eq 'Python' -and $capture.TestCount -eq 0 -and $null -ne $capture.TestCount) {
            $result.Status = 'Non execute'; $result.Detail = 'Aucun test unittest detecte.'
        }
        elseif ($process.ExitCode -ne 0) { $result.Status = 'Echec'; $result.Detail = 'Commande terminee en erreur.' }
        elseif ($Check.Kind -eq 'Python' -and $null -eq $capture.TestCount) { $result.Status = 'Partiel'; $result.Detail = 'Nombre de tests Python non confirme.' }
        elseif ($capture.Partial) { $result.Status = 'Partiel'; $result.Detail = 'La commande signale des controles non verifies ou ignores.' }
        else { $result.Status = 'Reussi'; $result.Detail = 'Commande terminee avec code 0.' }
        if ([ScriptsPerso.ProcessRunner]::DroppedMessages -gt 0 -and $result.Status -eq 'Reussi') {
            $result.Status = 'Partiel'; $result.Detail = 'Sorties tronquees : resultat detaille incomplet.'
        }
    }
    catch { $result.Status = 'Echec'; $result.Detail = 'Execution ou arret du controle impossible.' }
    finally {
        if ($process) { [ScriptsPerso.ProcessRunner]::Release($process); $process.Dispose() }
        $result.Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
        $result.Tail = @($capture.Tail.ToArray())
    }
    return $result
}

function Get-LocalCheckSelection([string]$Answer, [object[]]$Checks) {
    if ($Answer.Trim() -ieq 'Q') { return @() }
    if ($Answer.Trim() -ieq 'T') { return @($Checks | Where-Object { -not $_.Blocked }) }
    $selected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($part in ($Answer -split '[,;\s]+')) {
        $number = 0
        if (-not [int]::TryParse($part, [ref]$number) -or $number -lt 1 -or $number -gt $Checks.Count) { throw 'Selection invalide : aucun controle lance.' }
        $check = $Checks[$number - 1]
        if ($check.Blocked) { throw ('Controle indisponible : ' + $check.Name + '. ' + $check.Blocked) }
        if (-not $selected.Contains($check)) { $selected.Add($check) }
    }
    return $selected.ToArray()
}

function Invoke-LocalCheckPlan {
    param([object[]]$Checks, [string[]]$SelectedIds, [int]$LimitSeconds = 300, [switch]$Quiet)
    $results = @(
        foreach ($check in $Checks) {
            if ($check.Id -in $SelectedIds -and -not $check.Blocked) {
                if (-not $Quiet) { Write-Host ("`n=== " + $check.Name + ' ===') -ForegroundColor Cyan }
                Invoke-LocalCheck -Check $check -LimitSeconds $LimitSeconds -Quiet:$Quiet
            }
            else {
                $detail = if ($check.Blocked) { $check.Blocked } else { 'Non selectionne' }
                [pscustomobject]@{ Id = $check.Id; Name = $check.Name; Selected = ($check.Id -in $SelectedIds); Status = 'Non execute'; Detail = $detail; ExitCode = $null; Seconds = 0; Tail = @() }
            }
        }
    )
    $selected = @($results | Where-Object { $_.Selected })
    $code = if (@($selected | Where-Object { $_.Status -eq 'Echec' }).Count -gt 0) { 1 }
            elseif ($selected.Count -eq 0 -or @($selected | Where-Object { $_.Status -ne 'Reussi' }).Count -gt 0) { 2 }
            else { 0 }
    [pscustomobject]@{ Results = $results; ExitCode = $code }
}

if ($MyInvocation.InvocationName -ne '.') {
    $checkReport = $null
    $locationPushed = $false
    try {
        $projectItem = Get-Item -LiteralPath $Project
        if (-not $projectItem.PSIsContainer -or $projectItem.PSProvider.Name -ne 'FileSystem') { throw 'Choisis un dossier de projet.' }
        Push-Location -LiteralPath $projectItem.FullName
        $locationPushed = $true
        Write-Host "`n=== CENTRE DE TESTS ===" -ForegroundColor Cyan
        Write-Host ('Projet : ' + $projectItem.FullName)
        $checks = @(Get-LocalCheckOptions $projectItem.FullName)
        if ($checks.Count -eq 0) { Write-Host 'Aucun controle detecte : aucune validation effectuee.' }
        for ($index = 0; $index -lt $checks.Count; $index++) {
            $note = if ($checks[$index].Blocked) { ' [NON PROPOSE : ' + $checks[$index].Blocked + ']' } else { '' }
            Write-Host ('{0}. {1}{2}' -f ($index + 1), $checks[$index].Name, $note)
        }
        $selection = @()
        if (@($checks | Where-Object { -not $_.Blocked }).Count -gt 0) {
            $selection = @(Get-LocalCheckSelection (Read-Host 'Numeros separes par virgules, T pour tous, Q pour annuler') $checks)
            if ($selection.Count -gt 0) {
                Write-Host 'Commandes du projet executees en mode non interactif, sans hooks npm pre/post.'
                Write-Host 'Les tests et builds peuvent produire des fichiers. Aucune dependance n est installee.'
                if ((Read-Host 'Lancer ces controles de confiance ? (O/N)').Trim() -ine 'O') { $selection = @() }
            }
        }
        $checkReport = Invoke-LocalCheckPlan -Checks $checks -SelectedIds @($selection | ForEach-Object { $_.Id }) -LimitSeconds $TimeoutSeconds
        Write-Host "`n=== BILAN DES CONTROLES ===" -ForegroundColor Cyan
        foreach ($row in $checkReport.Results) {
            $codeText = if ($null -eq $row.ExitCode) { '-' } else { [string]$row.ExitCode }
            Write-Host ('{0} : {1} (code {2}, {3}s) - {4}' -f $row.Name, $row.Status, $codeText, $row.Seconds, $row.Detail)
        }
        if ($checkReport.ExitCode -eq 0) { Write-Host 'Les controles selectionnes ont reussi. Les controles non executes restent non valides.' -ForegroundColor Green }
        elseif ($checkReport.ExitCode -eq 1) { Write-Host 'Au moins un controle a echoue.' -ForegroundColor Yellow }
        else { Write-Host 'Bilan partiel ou aucun controle execute : validation incomplete.' -ForegroundColor Yellow }
        if ($PassThru) { $checkReport }
    }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    finally { if ($locationPushed) { Pop-Location } }
    if (-not $PassThru) {
        if ($null -eq $checkReport) { exit 1 }
        exit $checkReport.ExitCode
    }
}
