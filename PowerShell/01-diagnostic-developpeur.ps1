# Diagnostic local en lecture seule, compatible Windows PowerShell 5.1 et 7.
param(
    [ValidateRange(1, 65535)]
    [ValidateNotNullOrEmpty()]
    [int[]]$Ports = @(3000, 4173, 5000, 5173, 8000, 8080, 11434),

    [ValidateRange(1, 15)]
    [int]$TimeoutSeconds = 4,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Find-DeveloperExecutable([string[]]$names) {
    foreach ($name in $names) {
        foreach ($command in @(Get-Command -Name $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            # Les alias Windows peuvent ouvrir le Store ou un installateur.
            if ($command.Source -match '(?i)[\\/]Microsoft[\\/]WindowsApps[\\/]') { continue }
            return $command.Source
        }
    }
    return $null
}

function ConvertTo-DeveloperArgument([string]$value) {
    $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Stop-DeveloperProbe([Diagnostics.Process]$process) {
    if ($process.HasExited) { return }
    if ($null -ne $process.GetType().GetMethod('Kill', [type[]]@([bool]))) {
        $process.Kill($true)
    }
    else {
        # Ne cible que le processus de version que nous venons de creer.
        $stopInfo = New-Object Diagnostics.ProcessStartInfo
        $stopInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
        $stopInfo.Arguments = '/PID ' + $process.Id + ' /T /F'
        $stopInfo.UseShellExecute = $false
        $stopInfo.CreateNoWindow = $true
        $stopInfo.RedirectStandardOutput = $true
        $stopInfo.RedirectStandardError = $true
        $stopper = [Diagnostics.Process]::Start($stopInfo)
        try {
            if (-not $stopper.WaitForExit(1500)) { $stopper.Kill() }
        }
        finally { $stopper.Dispose() }
    }
    if (-not $process.WaitForExit(500)) { $process.Kill() }
}

function Read-DeveloperVersion {
    param(
        [string]$Executable,
        [string]$Arguments = '--version',
        [string[]]$Patterns,
        [int]$LimitSeconds = 4,
        [switch]$LocalOllama
    )
    $result = [pscustomobject]@{ Status = 'Non verifie'; Version = ''; Detail = '' }
    $process = New-Object Diagnostics.Process
    $started = $false
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $Executable
        $startInfo.Arguments = $Arguments
        $startInfo.WorkingDirectory = (Get-Location).Path
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        if ($LocalOllama) {
            # La commande de version peut contacter Ollama ; la limiter a la
            # machine locale, sans modifier la configuration de l'utilisateur.
            $startInfo.EnvironmentVariables['OLLAMA_HOST'] = '127.0.0.1:11434'
        }
        $process.StartInfo = $startInfo
        $clock = [Diagnostics.Stopwatch]::StartNew()
        [void]$process.Start()
        $started = $true
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $limitMs = $LimitSeconds * 1000
        $remainingMs = [Math]::Max(1, $limitMs - [int]$clock.ElapsedMilliseconds)
        if (-not $process.WaitForExit($remainingMs)) {
            $result.Detail = 'Delai depasse'
            return $result
        }
        $remainingMs = [Math]::Max(1, $limitMs - [int]$clock.ElapsedMilliseconds)
        $tasks = [Threading.Tasks.Task[]]@($outputTask, $errorTask)
        if (-not [Threading.Tasks.Task]::WaitAll($tasks, $remainingMs)) {
            $result.Detail = 'Delai de lecture depasse'
            return $result
        }
        if ($process.ExitCode -ne 0) {
            $result.Detail = 'Commande terminee en erreur (code ' + $process.ExitCode + ')'
            return $result
        }
        # Seule une version conforme est conservee, jamais les sorties brutes.
        $probeText = $outputTask.Result + "`n" + $errorTask.Result
        foreach ($pattern in $Patterns) {
            $versionMatch = [regex]::Match($probeText, $pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
            if ($versionMatch.Success) {
                $result.Status = 'Disponible'
                $result.Version = $versionMatch.Groups['version'].Value
                return $result
            }
        }
        $result.Detail = 'Version non reconnue'
        return $result
    }
    catch {
        $result.Detail = 'Impossible de verifier la version'
        return $result
    }
    finally {
        if ($started) {
            try { Stop-DeveloperProbe $process } catch { }
        }
        $process.Dispose()
    }
}

function Get-DeveloperListeningPorts {
    # Observation passive : aucune connexion, aucun scan reseau.
    $properties = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    @($properties.GetActiveTcpListeners() | Select-Object -ExpandProperty Port -Unique)
}

function Get-DeveloperDiagnostic {
    param([int[]]$CheckedPorts, [int]$LimitSeconds = 4)
    if ((Get-Location).Provider.Name -ne 'FileSystem') { throw 'Ouvre un dossier de projet avant le diagnostic.' }
    $definitions = @(
        @{ Name = 'Node.js'; Commands = @('node.exe'); Patterns = @('^v(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\s*$') },
        @{ Name = 'npm'; Commands = @('npm.exe', 'npm.cmd'); Patterns = @('^(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\s*$') },
        @{ Name = 'Python'; Commands = @('python.exe', 'python3.exe'); Patterns = @('^Python\s+(?<version>\d+\.\d+\.\d+(?:(?:a|b|rc)\d+)?)\s*$') },
        @{ Name = 'Ollama'; Commands = @('ollama.exe'); Patterns = @('^Warning: client version is\s+(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\s*$', '^ollama version is\s+(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\s*$') }
    )
    $tools = @(
        [pscustomobject]@{ Name = 'PowerShell actif'; Status = 'Disponible'; Version = $PSVersionTable.PSVersion.ToString(); Detail = [string]$PSVersionTable.PSEdition }
        foreach ($definition in $definitions) {
            $executable = Find-DeveloperExecutable $definition.Commands
            $version = [pscustomobject]@{ Status = 'Non trouve'; Version = ''; Detail = 'Non trouve dans le PATH (alias Windows ignores)' }
            if ($executable) {
                $probeArguments = '--version'
                $canProbe = $true
                if ([IO.Path]::GetExtension($executable) -ieq '.cmd') {
                    # npm.cmd distribue par Node appelle ce point d'entree.
                    # Executer le JS avec Node evite tout shell intermediaire.
                    $npmRoot = [IO.Path]::GetDirectoryName($executable)
                    $npmCli = Join-Path $npmRoot 'node_modules\npm\bin\npm-cli.js'
                    $nodeExecutable = Join-Path $npmRoot 'node.exe'
                    if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) { $nodeExecutable = Find-DeveloperExecutable @('node.exe') }
                    if ($nodeExecutable -and (Test-Path -LiteralPath $npmCli -PathType Leaf)) {
                        $executable = $nodeExecutable
                        $probeArguments = (ConvertTo-DeveloperArgument $npmCli) + ' --version'
                    }
                    else {
                        $canProbe = $false
                        $version.Status = 'Non verifie'
                        $version.Detail = 'npm detecte ; version non verifiable avec cette installation'
                    }
                }
                if ($canProbe) {
                    $version = Read-DeveloperVersion -Executable $executable -Arguments $probeArguments -Patterns $definition.Patterns -LimitSeconds $LimitSeconds -LocalOllama:($definition.Name -eq 'Ollama')
                }
            }
            [pscustomobject]@{ Name = $definition.Name; Status = $version.Status; Version = $version.Version; Detail = $version.Detail }
        }
    )
    $portsReadable = $true
    try { $listening = @(Get-DeveloperListeningPorts) }
    catch { $portsReadable = $false; $listening = @() }
    $portRows = @(
        foreach ($portNumber in @($CheckedPorts | Sort-Object -Unique)) {
            $state = if (-not $portsReadable) { 'Non verifie' } elseif ($portNumber -in $listening) { 'Occupe' } else { 'Libre' }
            [pscustomobject]@{ Port = $portNumber; Status = $state }
        }
    )
    [pscustomobject]@{
        Project = (Get-Location).Path
        Tools = $tools
        Ports = $portRows
        UnverifiedTools = @($tools | Where-Object { $_.Status -ne 'Disponible' }).Count
        PortsReadable = $portsReadable
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ''
    Write-Host '=== DIAGNOSTIC DEVELOPPEUR ===' -ForegroundColor Cyan
    Write-Host ('Projet : ' + (Get-Location).Path)
    Write-Host 'Verification des versions en cours...'
    $report = Get-DeveloperDiagnostic -CheckedPorts $Ports -LimitSeconds $TimeoutSeconds
    Write-Host ''
    Write-Host '=== OUTILS ===' -ForegroundColor Cyan
    foreach ($tool in $report.Tools) {
        $details = if ($tool.Version) { $tool.Version } else { $tool.Detail }
        Write-Host ('{0} : {1} - {2}' -f $tool.Name, $tool.Status, $details)
    }
    Write-Host ''
    Write-Host '=== PORTS TCP (OBSERVATION ACTUELLE) ===' -ForegroundColor Cyan
    foreach ($portRow in $report.Ports) { Write-Host ('Port {0} : {1}' -f $portRow.Port, $portRow.Status) }
    Write-Host ''
    Write-Host ('Diagnostic termine. Outils non verifies ou non trouves : ' + $report.UnverifiedTools)
    if (-not $report.PortsReadable) { Write-Host 'Etat des ports indisponible sur cette session.' -ForegroundColor Yellow }
    Write-Host 'Un port occupe ne signifie pas que le service fonctionne correctement.'
    if ($PassThru) { $report }
}
