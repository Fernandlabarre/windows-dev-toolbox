# Un gestionnaire par projet, dans une console independante du lanceur.
param([string]$Project = (Get-Location).Path)
$ErrorActionPreference = 'Stop'

# Injecte la même barrière dans les commandes encodées des serveurs et tests.
# Le handle reste détenu par ProcessRunner jusqu'à la fin du processus.
$script:LocalStartGateCode = @'
$startGateName = $env:SCRIPTS_PERSO_START_GATE
Remove-Item Env:SCRIPTS_PERSO_START_GATE -ErrorAction SilentlyContinue
$startGate = $null
try {
    if ([string]::IsNullOrWhiteSpace($startGateName)) { throw 'Barriere de demarrage absente.' }
    $startGate = [Threading.EventWaitHandle]::OpenExisting($startGateName)
    if (-not $startGate.WaitOne(30000)) { throw 'Barriere de demarrage expiree.' }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($startGate) { $startGate.Dispose() }
}
'@

function Initialize-LocalServerRuntime {
    if (-not ('ScriptsPerso.ProcessRunner' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'Support\ScriptsPersoRunner.cs')
    }
    if ($null -eq [ScriptsPerso.ProcessRunner].GetField('MaxQueuedMessages')) {
        throw 'Rouvre une console PowerShell pour charger la nouvelle version du gestionnaire.'
    }
    [ScriptsPerso.ProcessRunner]::MaxQueuedMessages = 500
}

function Find-LocalServerExecutable([string[]]$names) {
    foreach ($name in $names) {
        foreach ($command in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            if ($command.Source -notmatch '(?i)[\\/]Microsoft[\\/]WindowsApps[\\/]') { return $command.Source }
        }
    }
    return $null
}

function Get-LocalServerOptions([string]$ProjectPath) {
    $manifest = Join-Path $ProjectPath 'package.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        $item = Get-Item -LiteralPath $manifest
        if ($item.Length -le 1048576 -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try {
                $package = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
                $fingerprint = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
                foreach ($entry in $package.scripts.PSObject.Properties) {
                    if ($entry.Name -cmatch '^(dev|start|serve|preview)(:[a-zA-Z0-9_-]+)*$' -and
                        $entry.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($entry.Value)) {
                        [pscustomobject]@{ Kind = 'npm'; Name = $entry.Name; Project = $ProjectPath; Directory = ''; Fingerprint = $fingerprint }
                    }
                }
            }
            catch { Write-Host 'package.json non exploitable : commandes npm non proposees.' -ForegroundColor Yellow }
        }
    }
    foreach ($folderName in @('public', 'dist', 'build')) {
        $folder = Join-Path $ProjectPath $folderName
        if ((Test-Path -LiteralPath $folder -PathType Container) -and
            -not ((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            [pscustomobject]@{ Kind = 'Python'; Name = $folderName; Project = $ProjectPath; Directory = $folder; Fingerprint = '' }
        }
    }
}

function New-LocalServerState([string]$ProjectPath) {
    @{ Project = $ProjectPath; Process = $null; Name = ''; Url = ''; LastExitCode = $null; StopRequested = $false;
       Logs = (New-Object 'System.Collections.Generic.Queue[object]'); Sequence = 0; SecretBlock = $false }
}

function Protect-LocalServerLog([string]$line, [hashtable]$State) {
    $line = [regex]::Replace($line, '\x1b\][^\x07]*(?:\x07|\x1b\\)', '')
    $line = [regex]::Replace($line, '\x1b\[[0-?]*[ -/]*[@-~]', '')
    $line = [regex]::Replace($line, '[\x00-\x1f\x7f]', '')
    if ($line -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') { $State.SecretBlock = $true; return '[CLE PRIVEE MASQUEE]' }
    if ($State.SecretBlock) {
        if ($line -match '-----END [A-Z ]*PRIVATE KEY-----') { $State.SecretBlock = $false }
        return $null
    }
    $line = [regex]::Replace($line, '(?i)\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b', '[JETON MASQUE]')
    $line = [regex]::Replace($line, '\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[JETON MASQUE]')
    $line = [regex]::Replace($line, '(?i)\b(Bearer|Basic)\s+[A-Za-z0-9+/=._-]+', '$1 [MASQUE]')
    $line = [regex]::Replace($line, '(?i)\b((?:https?|postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://)[^/\s@]+@', '$1[IDENTIFIANTS MASQUES]@')
    $line = [regex]::Replace($line, '(?i)([?&](?:token|access_token|api_key|password|secret|key)=)[^&#\s]+', '$1[MASQUE]')
    # Masquer toute la fin d'une ligne d'affectation sensible, y compris tronquee.
    $line = [regex]::Replace($line, '(?i)(["'']?\b[A-Za-z0-9_]*(?:password|passwd|api[_-]?key|access[_-]?token|client[_-]?secret|authorization|token|secret)[A-Za-z0-9_]*["'']?\s*[:=]\s*).*', '$1[MASQUE]')
    return $line
}

function Update-LocalServerState([hashtable]$State) {
    if ($State.Process -and $State.Process.HasExited) {
        [ScriptsPerso.ProcessRunner]::Release($State.Process)
        $State.Process.WaitForExit()
        $State.LastExitCode = $State.Process.ExitCode
        $State.Process.Dispose()
        $State.Process = $null
    }
    [string]$message = $null
    while ([ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$message)) {
        $safeLine = Protect-LocalServerLog $message.Substring(1) $State
        if ($null -eq $safeLine) { continue }
        $State.Sequence++
        $State.Logs.Enqueue([pscustomobject]@{ Sequence = $State.Sequence; Text = $safeLine })
        while ($State.Logs.Count -gt 200) { $null = $State.Logs.Dequeue() }
        $address = [regex]::Match($safeLine, 'https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d{1,5}(?=[/\s]|$)')
        if ($address.Success) { $State.Url = $address.Value + '/' }
    }
}

function ConvertTo-LocalServerLiteral([string]$value) { return "'" + $value.Replace("'", "''") + "'" }

function Get-LocalNpmInvocation([string[]]$CommandArguments) {
    $executable = Find-LocalServerExecutable @('npm.exe', 'npm.cmd')
    if (-not $executable) { throw 'npm est introuvable dans le PATH.' }
    $nativeArguments = $CommandArguments
    if ([IO.Path]::GetExtension($executable) -ieq '.cmd') {
        $npmRoot = [IO.Path]::GetDirectoryName($executable)
        $cli = Join-Path $npmRoot 'node_modules\npm\bin\npm-cli.js'
        $node = Join-Path $npmRoot 'node.exe'
        if (-not (Test-Path -LiteralPath $node -PathType Leaf)) { $node = Find-LocalServerExecutable @('node.exe') }
        if (-not $node -or -not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'Installation npm non prise en charge : point d entree Node introuvable.' }
        $executable = $node
        $nativeArguments = @($cli) + $CommandArguments
    }
    [pscustomobject]@{ Executable = $executable; Arguments = $nativeArguments }
}

function Get-LocalServerLaunch([object]$Option, [int]$Port = 8000) {
    if ($Option.Kind -eq 'npm') {
        $manifest = Join-Path $Option.Project 'package.json'
        if ($Option.Name -cnotmatch '^(dev|start|serve|preview)(:[a-zA-Z0-9_-]+)*$' -or
            (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash -ne $Option.Fingerprint) {
            throw 'package.json a change : choisis a nouveau une commande.'
        }
        return Get-LocalNpmInvocation @('--silent', '--ignore-scripts', 'run', $Option.Name)
    }
    elseif ($Option.Kind -eq 'Python') {
        $executable = Find-LocalServerExecutable @('python.exe', 'python3.exe')
        if (-not $executable) { throw 'Python est introuvable dans le PATH.' }
        $backend = Join-Path ([IO.Directory]::GetParent($PSScriptRoot).FullName) 'Python\02-serveur-local.py'
        $commandArgs = @('-B', '-u', $backend, '--project', $Option.Project, '--directory', $Option.Directory, '--port', [string]$Port)
    }
    else { throw 'Type de serveur non pris en charge.' }
    [pscustomobject]@{ Executable = $executable; Arguments = $commandArgs }
}

function Start-LocalManagedServer([hashtable]$State, [object]$Option, [int]$Port = 8000) {
    Update-LocalServerState $State
    if ($State.Process) { throw 'Arrete le serveur actuel avant un nouveau demarrage.' }
    if ($Option.Project -ne $State.Project) { throw 'La commande ne correspond pas au projet actif.' }
    $launch = Get-LocalServerLaunch $Option $Port
    $nativeArguments = @($launch.Arguments | ForEach-Object { ConvertTo-LocalServerLiteral ([string]$_) }) -join ' '
    $bootstrap = $script:LocalStartGateCode
    $bootstrap += @'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$env:PYTHONIOENCODING = 'utf-8'
$env:NO_COLOR = '1'
$env:FORCE_COLOR = '0'
$env:npm_config_yes = 'false'
$env:npm_config_update_notifier = 'false'
'@
    $bootstrap += "`nSet-Location -LiteralPath " + (ConvertTo-LocalServerLiteral $State.Project)
    $bootstrap += "`n& " + (ConvertTo-LocalServerLiteral $launch.Executable) + ' ' + $nativeArguments
    $bootstrap += "`nexit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $State.Logs.Clear()
    $State.Url = ''
    $State.LastExitCode = $null
    $State.StopRequested = $false
    $State.SecretBlock = $false
    [string]$discard = $null
    while ([ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$discard)) { }
    [ScriptsPerso.ProcessRunner]::DroppedMessages = 0
    $State.Process = [ScriptsPerso.ProcessRunner]::Launch((Join-Path $PSHOME $engineName), ('-NoProfile -EncodedCommand ' + $encoded), $State.Project)
    $State.Name = $Option.Kind + ' / ' + $Option.Name
}

function Stop-LocalManagedServer([hashtable]$State) {
    Update-LocalServerState $State
    if ($State.Process) {
        $State.StopRequested = $true
        [ScriptsPerso.ProcessRunner]::Stop($State.Process)
        if (-not $State.Process.WaitForExit(5000)) { throw 'Arret du serveur non confirme.' }
        Update-LocalServerState $State
    }
}

function Show-LocalServerLogs([hashtable]$State) {
    Update-LocalServerState $State
    foreach ($entry in $State.Logs) { Write-Host $entry.Text }
    if ([ScriptsPerso.ProcessRunner]::DroppedMessages -gt 0) { Write-Host 'Journaux tronques : seules les dernieres lignes sont conservees.' }
    if ([Console]::IsInputRedirected -or -not $State.Process) { return }
    Write-Host 'Suivi des journaux : Q pour revenir au menu.'
    $lastSequence = $State.Sequence
    while ($State.Process) {
        Update-LocalServerState $State
        foreach ($entry in $State.Logs) {
            if ($entry.Sequence -gt $lastSequence) { Write-Host $entry.Text; $lastSequence = $entry.Sequence }
        }
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) { break }
        }
        Start-Sleep -Milliseconds 150
    }
}

function Invoke-LocalServerManager([string]$ProjectPath) {
    $projectItem = Get-Item -LiteralPath $ProjectPath
    if (-not $projectItem.PSIsContainer -or $projectItem.PSProvider.Name -ne 'FileSystem') { throw 'Choisis un dossier de projet.' }
    $root = $projectItem.FullName
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))).Replace('-', '') }
    finally { $hasher.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\ScriptsPerso.Servers.' + $key))
    $ownsMutex = $false
    $state = $null
    try {
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'Un gestionnaire est deja ouvert pour ce projet.' }
        Initialize-LocalServerRuntime
        $state = New-LocalServerState $root
        while ($true) {
            Update-LocalServerState $state
            Write-Host "`n=== SERVEURS LOCAUX ===" -ForegroundColor Cyan
            Write-Host ('Projet : ' + $root)
            if ($state.Process) { Write-Host ('Processus actif : ' + $state.Name + ' (PID ' + $state.Process.Id + ')') }
            elseif ($state.StopRequested) { Write-Host 'Serveur arrete par le gestionnaire.' }
            elseif ($null -ne $state.LastExitCode) { Write-Host ('Serveur termine, code ' + $state.LastExitCode) }
            else { Write-Host 'Aucun serveur lance par ce gestionnaire.' }
            if ($state.Url) { Write-Host ('Adresse annoncee : ' + $state.Url) }
            Write-Host '1. Demarrer un serveur'
            Write-Host '2. Voir les journaux filtres'
            Write-Host '3. Actualiser l etat'
            Write-Host '4. Arreter le serveur gere'
            Write-Host 'Q. Fermer le gestionnaire'
            $choice = Read-Host 'Votre choix'
            if ($choice -ieq 'Q') {
                if ($state.Process -and (Read-Host 'Arreter le serveur et fermer ? (O/N)') -ine 'O') { continue }
                break
            }
            try {
                switch ($choice) {
                    '1' {
                        if ($state.Process) { throw 'Un serveur est deja actif dans ce gestionnaire.' }
                        $options = @(Get-LocalServerOptions $root)
                        if ($options.Count -eq 0) { throw 'Aucun script npm dev/start/serve/preview ni dossier public/dist/build trouve.' }
                        for ($index = 0; $index -lt $options.Count; $index++) { Write-Host ('{0}. {1} / {2}' -f ($index + 1), $options[$index].Kind, $options[$index].Name) }
                        $selection = Read-Host 'Numero (Q pour revenir)'
                        if ($selection -ieq 'Q') { continue }
                        $number = 0
                        if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $options.Count) { throw 'Selection invalide.' }
                        $option = $options[$number - 1]
                        $portNumber = 8000
                        if ($option.Kind -eq 'Python') {
                            $answer = Read-Host 'Port TCP (Entree = 8000)'
                            if ($answer -and (-not [int]::TryParse($answer, [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535)) { throw 'Port invalide.' }
                        }
                        Write-Host ('Commande : ' + $option.Kind + ' / ' + $option.Name)
                        if ($option.Kind -eq 'npm') { Write-Host 'Code du projet execute. Hooks pre/post desactives ; configuration reseau definie par le projet.' }
                        if ((Read-Host 'Demarrer cette commande de confiance ? (O/N)') -ine 'O') { continue }
                        Start-LocalManagedServer $state $option $portNumber
                        Start-Sleep -Milliseconds 400
                        Update-LocalServerState $state
                    }
                    '2' { Show-LocalServerLogs $state }
                    '3' { }
                    '4' { if ($state.Process -and (Read-Host 'Arreter uniquement le serveur gere ? (O/N)') -ieq 'O') { Stop-LocalManagedServer $state } }
                    default { Write-Host 'Choix invalide.' }
                }
            }
            catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
        }
    }
    finally {
        if ($state) { Stop-LocalManagedServer $state }
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-LocalServerManager $Project }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        if (-not [Console]::IsInputRedirected) { $null = Read-Host 'Entree pour fermer cette console' }
    }
}
