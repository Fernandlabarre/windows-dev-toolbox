# Serveurs et projets factices uniquement ; aucune installation de dependances.
$ErrorActionPreference = 'Stop'
$serverTestRepo = [IO.Directory]::GetParent($PSScriptRoot).FullName
. (Join-Path $serverTestRepo 'PowerShell\02-gerer-serveurs-locaux.ps1')
Initialize-LocalServerRuntime
$serverTestParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$serverTestRoot = Join-Path $serverTestParent ('scripts-perso-servers-' + [Guid]::NewGuid().ToString('N'))
$serverTestProject = Join-Path $serverTestRoot "Projet avec espaces [1] et l'apostrophe"
[void][IO.Directory]::CreateDirectory((Join-Path $serverTestProject 'public'))
$serverTestState = New-LocalServerState $serverTestProject

function Assert-Server([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Write-ServerFixture([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }
function Wait-ServerAddress([hashtable]$State) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        Update-LocalServerState $State
        if ($State.Url) { return }
        if (-not $State.Process) { throw ('Le serveur de test a quitte : code ' + $State.LastExitCode) }
        Start-Sleep -Milliseconds 30
    }
    throw 'Adresse du serveur de test non recue.'
}

try {
    $manifest = Join-Path $serverTestProject 'package.json'
    Write-ServerFixture $manifest '{"scripts":{"dev":"node server.cjs","test":"exit 1","build":"exit 1","dev:api":"node server.cjs","start;unsafe":"exit 1"}}'
    Write-ServerFixture (Join-Path $serverTestProject 'public\index.html') 'PYTHON_TEST_OK'
    $options = @(Get-LocalServerOptions $serverTestProject)
    Assert-Server (@($options | Where-Object { $_.Kind -eq 'npm' }).Count -eq 2) 'Mauvaise selection des scripts npm.'
    Assert-Server (@($options | Where-Object { $_.Kind -eq 'Python' }).Count -eq 1) 'Dossier public non propose.'
    Write-Host 'OK : decouverte des commandes declarees et dossiers publics.'

    $redactionState = New-LocalServerState $serverTestProject
    foreach ($sample in @('API_KEY=DEMO_PRIVATE_VALUE', 'Authorization: Bearer DEMO_PRIVATE_VALUE', 'https://demo:DEMO_PRIVATE_VALUE@localhost/', 'http://localhost:8000/?token=DEMO_PRIVATE_VALUE')) {
        $safe = Protect-LocalServerLog $sample $redactionState
        Assert-Server (-not $safe.Contains('DEMO_PRIVATE_VALUE')) 'Valeur sensible factice exposee.'
    }
    # Construire les marqueurs évite qu'un scanner de secrets confonde cette
    # donnée de test avec une vraie clé enregistrée dans le dépôt.
    $keyBegin = '-----BEGIN ' + 'PRIVATE KEY-----'
    $keyEnd = '-----END ' + 'PRIVATE KEY-----'
    $null = Protect-LocalServerLog $keyBegin $redactionState
    Assert-Server ($null -eq (Protect-LocalServerLog 'DEMO_KEY_BODY' $redactionState)) 'Corps de cle expose.'
    $null = Protect-LocalServerLog $keyEnd $redactionState
    Write-Host 'OK : masquage des secrets factices et blocs de cles.'

    $npmOption = @($options | Where-Object { $_.Kind -eq 'npm' -and $_.Name -eq 'dev' })[0]
    Write-ServerFixture $manifest '{"scripts":{"dev":"node changed.cjs"}}'
    $refused = $false
    try { $null = Get-LocalServerLaunch $npmOption } catch { $refused = $true }
    Assert-Server $refused 'Une commande modifiee apres selection est acceptee.'
    Write-Host 'OK : modification du manifeste detectee avant execution.'

    $pythonOption = @($options | Where-Object { $_.Kind -eq 'Python' })[0]
    $otherListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $otherListener.Start()
        Start-LocalManagedServer $serverTestState $pythonOption 0
        Wait-ServerAddress $serverTestState
        $response = Invoke-WebRequest -Uri $serverTestState.Url -UseBasicParsing -TimeoutSec 3
        Assert-Server ($response.Content -eq 'PYTHON_TEST_OK') 'Le serveur Python ne sert pas le bon projet.'
        $duplicateRefused = $false
        try { Start-LocalManagedServer $serverTestState $pythonOption 0 } catch { $duplicateRefused = $true }
        Assert-Server $duplicateRefused 'Un second serveur remplace le premier sans arret.'
        Stop-LocalManagedServer $serverTestState
        Assert-Server ($null -eq $serverTestState.Process -and $otherListener.Server.IsBound) 'Arret incorrect ou serveur tiers touche.'
        Assert-Server $serverTestState.StopRequested 'Arret volontaire non identifie.'
    }
    finally { $otherListener.Stop(); Stop-LocalManagedServer $serverTestState }
    Write-Host 'OK : serveur Python, bon projet, doublon refuse et arret limite au serveur gere.'

    if ((Find-LocalServerExecutable @('node.exe')) -and (Find-LocalServerExecutable @('npm.exe', 'npm.cmd'))) {
        Write-ServerFixture $manifest '{"scripts":{"dev":"node server.cjs","predev":"node forbidden.cjs"}}'
        Write-ServerFixture (Join-Path $serverTestProject 'forbidden.cjs') 'require("fs").writeFileSync("HOOK_MUST_NOT_RUN", "demo");'
        Write-ServerFixture (Join-Path $serverTestProject 'server.cjs') @'
const http = require('http');
console.log('API_KEY=DEMO_NPM_PRIVATE_VALUE');
console.log('-----BEGIN ' + 'PRIVATE KEY-----');
console.log('DEMO_KEY_BODY_MUST_NOT_APPEAR');
console.log('-----END ' + 'PRIVATE KEY-----');
const server = http.createServer((req, res) => { res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'}); res.end('NODE_TEST_OK'); });
server.listen(0, '127.0.0.1', () => console.log('http://127.0.0.1:' + server.address().port + '/'));
'@
        $npmOption = @(Get-LocalServerOptions $serverTestProject | Where-Object { $_.Kind -eq 'npm' -and $_.Name -eq 'dev' })[0]
        Start-LocalManagedServer $serverTestState $npmOption
        Wait-ServerAddress $serverTestState
        $response = Invoke-WebRequest -Uri $serverTestState.Url -UseBasicParsing -TimeoutSec 3
        Assert-Server ($response.Content -eq 'NODE_TEST_OK') 'Serveur npm non joignable.'
        Assert-Server (-not (Test-Path -LiteralPath (Join-Path $serverTestProject 'HOOK_MUST_NOT_RUN'))) 'Un hook npm automatique a ete execute.'
        $logs = @($serverTestState.Logs | ForEach-Object { $_.Text }) -join "`n"
        Assert-Server ($logs -notmatch 'DEMO_NPM_PRIVATE_VALUE|DEMO_KEY_BODY_MUST_NOT_APPEAR') 'Secrets factices dans les journaux.'
        Stop-LocalManagedServer $serverTestState
        Write-Host 'OK : serveur npm, hooks desactives, journaux filtres et arret.'

        Write-ServerFixture (Join-Path $serverTestProject 'server.cjs') 'process.exit(7);'
        Start-LocalManagedServer $serverTestState $npmOption
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do { Update-LocalServerState $serverTestState; Start-Sleep -Milliseconds 25 } while ($serverTestState.Process -and [DateTime]::UtcNow -lt $deadline)
        Assert-Server ($null -eq $serverTestState.Process -and $serverTestState.LastExitCode -ne 0) 'Echec du serveur annonce actif.'
        Assert-Server (-not $serverTestState.StopRequested) 'Un echec est confondu avec un arret volontaire.'
        Write-Host 'OK : serveur quittant en erreur detecte.'
    }
    else { Write-Host 'NON VERIFIE : Node/npm absents de cette machine.' }
    # La console independante heberge un vrai serveur et survit a un autre outil.
    $readyFile = Join-Path $serverTestRoot 'manager-ready.json'
    $managerPath = Join-Path $serverTestRepo 'PowerShell\02-gerer-serveurs-locaux.ps1'
    $managerCode = '. ' + (ConvertTo-LocalServerLiteral $managerPath) + "`nInitialize-LocalServerRuntime`n"
    $managerCode += '$localRoot = ' + (ConvertTo-LocalServerLiteral $serverTestProject) + "`n"
    $managerCode += '$readyFile = ' + (ConvertTo-LocalServerLiteral $readyFile) + "`n"
    $managerCode += @'
$state = New-LocalServerState $localRoot
try {
    $option = @(Get-LocalServerOptions $localRoot | Where-Object { $_.Kind -eq 'Python' })[0]
    Start-LocalManagedServer $state $option 0
    while (-not $state.Url -and $state.Process) { Update-LocalServerState $state; Start-Sleep -Milliseconds 30 }
    if (-not $state.Process) { exit 2 }
    @{ Url = $state.Url; ProcessId = $state.Process.Id } | ConvertTo-Json -Compress | Set-Content -LiteralPath $readyFile -Encoding UTF8
    while ($true) { Update-LocalServerState $state; Start-Sleep -Milliseconds 100 }
}
finally { Stop-LocalManagedServer $state }
'@
    $serverEngineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $serverEngine = Join-Path $PSHOME $serverEngineName
    $managerStart = New-Object Diagnostics.ProcessStartInfo
    $managerStart.FileName = $serverEngine
    $managerStart.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($managerCode))
    $managerStart.WorkingDirectory = $serverTestProject
    $managerStart.UseShellExecute = $false
    $managerStart.CreateNoWindow = $true
    $independentManager = [Diagnostics.Process]::Start($managerStart)
    $managedProcess = $null
    $shortTool = $null
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $readyFile) -and -not $independentManager.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 30 }
        Assert-Server (Test-Path -LiteralPath $readyFile) 'Gestionnaire independant non demarre.'
        $ready = Get-Content -LiteralPath $readyFile -Raw | ConvertFrom-Json
        $managedProcess = [Diagnostics.Process]::GetProcessById([int]$ready.ProcessId)
        $shortCode = $script:LocalStartGateCode + "`nexit 0"
        $shortArguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shortCode))
        $shortTool = [ScriptsPerso.ProcessRunner]::Launch($serverEngine, $shortArguments, $serverTestProject)
        Assert-Server ($shortTool.WaitForExit(5000)) 'Outil court non termine.'
        [ScriptsPerso.ProcessRunner]::Release($shortTool)
        Assert-Server (-not $independentManager.HasExited -and -not $managedProcess.HasExited) 'Le serveur est mort au retour dans les autres outils.'
        $response = Invoke-WebRequest -Uri $ready.Url -UseBasicParsing -TimeoutSec 3
        Assert-Server ($response.Content -eq 'PYTHON_TEST_OK') 'Serveur independant non joignable.'
        $independentManager.Kill()
        Assert-Server ($managedProcess.WaitForExit(5000)) 'Le serveur survit a la fermeture de son gestionnaire.'
    }
    finally {
        if ($shortTool) { [ScriptsPerso.ProcessRunner]::Release($shortTool); $shortTool.Dispose() }
        if (-not $independentManager.HasExited) { $independentManager.Kill() }
        $null = $independentManager.WaitForExit(5000)
        if ($managedProcess) { $managedProcess.Dispose() }
        $independentManager.Dispose()
    }
    Write-Host 'OK : serveur maintenu entre les outils et arrete a la fermeture de sa console.'
    & {
        function Read-Host { param($Prompt) return 'Q' }
        Invoke-LocalServerManager $serverTestProject
    }
    Write-Host 'OK : ouverture et fermeture du menu du gestionnaire.'
    Write-Host ('SUCCES - Serveurs locaux / PowerShell ' + $PSVersionTable.PSVersion)
}
finally {
    Stop-LocalManagedServer $serverTestState
    $resolvedRoot = [IO.Path]::GetFullPath($serverTestRoot)
    if ([IO.Directory]::GetParent($resolvedRoot).FullName -ne $serverTestParent -or
        -not [IO.Path]::GetFileName($resolvedRoot).StartsWith('scripts-perso-servers-')) { throw 'Nettoyage hors du dossier de test refuse.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
