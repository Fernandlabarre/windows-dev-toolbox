# Tests sur commandes factices et port TCP temporaire, sans modele IA.
$ErrorActionPreference = 'Stop'
$diagnosticRepo = [IO.Directory]::GetParent($PSScriptRoot).FullName
$diagnosticScript = Join-Path $diagnosticRepo 'PowerShell\01-diagnostic-developpeur.ps1'
. $diagnosticScript
$diagnosticEngineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$diagnosticEngine = Join-Path $PSHOME $diagnosticEngineName
$versionPattern = '^v(?<version>\d+\.\d+\.\d+)\s*$'

function Assert-Diagnostic([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

$version = Read-DeveloperVersion -Executable $diagnosticEngine -Arguments '-NoProfile -NonInteractive -Command "[Console]::WriteLine(''DEMO_PRIVATE_VALUE''); [Console]::WriteLine(''v20.12.3'')"' -Patterns $versionPattern
Assert-Diagnostic ($version.Status -eq 'Disponible' -and $version.Version -eq '20.12.3') 'Version non reconnue.'
Assert-Diagnostic (($version | ConvertTo-Json -Compress) -notlike '*DEMO_PRIVATE_VALUE*') 'Sortie brute exposee.'
Write-Host 'OK : version reconnue, sorties brutes masquees.'

$version = Read-DeveloperVersion -Executable $diagnosticEngine -Arguments '-NoProfile -NonInteractive -Command "[Console]::WriteLine(''v20.12.3''); exit 9"' -Patterns $versionPattern
Assert-Diagnostic ($version.Status -eq 'Non verifie' -and $version.Detail -like '*code 9*') 'Un echec est annonce comme disponible.'
Write-Host 'OK : code retour en erreur respecte.'

$version = Read-DeveloperVersion -Executable $diagnosticEngine -Arguments '-NoProfile -NonInteractive -Command "[Console]::WriteLine(''DEMO_UNEXPECTED_OUTPUT'')"' -Patterns $versionPattern
Assert-Diagnostic ($version.Status -eq 'Non verifie' -and $version.Detail -eq 'Version non reconnue') 'Sortie inconnue mal classee.'
Assert-Diagnostic (($version | ConvertTo-Json -Compress) -notlike '*DEMO_UNEXPECTED_OUTPUT*') 'Sortie inattendue exposee.'
Write-Host 'OK : version inconnue signalee sans divulgation.'

$localVersion = Read-DeveloperVersion -Executable $diagnosticEngine -Arguments '-NoProfile -NonInteractive -Command "[Console]::WriteLine(''LOCAL_HOST='' + [Environment]::GetEnvironmentVariable(''OLLAMA_HOST'') + '' 1.2.3'')"' -Patterns '^LOCAL_HOST=127\.0\.0\.1:11434 (?<version>1\.2\.3)\s*$' -LocalOllama
Assert-Diagnostic ($localVersion.Status -eq 'Disponible' -and $localVersion.Version -eq '1.2.3') 'La verification Ollama ne force pas la machine locale.'
Write-Host 'OK : verification Ollama limitee a la machine locale.'

$timeoutClock = [Diagnostics.Stopwatch]::StartNew()
$version = Read-DeveloperVersion -Executable $diagnosticEngine -Arguments '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 20"' -Patterns $versionPattern -LimitSeconds 1
Assert-Diagnostic ($version.Status -eq 'Non verifie' -and $version.Detail -eq 'Delai depasse') 'Delai non signale.'
Assert-Diagnostic ($timeoutClock.ElapsedMilliseconds -lt 8000) 'Le controle ne respecte pas sa limite de temps.'
Write-Host 'OK : commande lente interrompue avec delai borne.'

$probeInfo = New-Object Diagnostics.ProcessStartInfo
$probeInfo.FileName = $diagnosticEngine
$probeInfo.Arguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 20"'
$probeInfo.UseShellExecute = $false
$probeInfo.CreateNoWindow = $true
$ownedProbe = [Diagnostics.Process]::Start($probeInfo)
try {
    Stop-DeveloperProbe $ownedProbe
    Assert-Diagnostic ($ownedProbe.WaitForExit(3000)) 'Le processus du controle reste actif.'
}
finally {
    if (-not $ownedProbe.HasExited) { $ownedProbe.Kill() }
    $ownedProbe.Dispose()
}
Write-Host 'OK : nettoyage du seul processus cree par le diagnostic.'

$missingReport = & {
    function Find-DeveloperExecutable { return $null }
    function Get-DeveloperListeningPorts { throw 'DEMO_PORTS_UNAVAILABLE' }
    function Read-DeveloperVersion { throw 'Aucun outil absent ne doit etre lance.' }
    Get-DeveloperDiagnostic -CheckedPorts @(5173, 3000, 5173)
}
Assert-Diagnostic ($missingReport.Tools.Count -eq 5 -and $missingReport.UnverifiedTools -eq 4) 'Inventaire des outils absents incorrect.'
Assert-Diagnostic (-not $missingReport.PortsReadable -and $missingReport.Ports.Count -eq 2) 'Ports non verifies mal restitues.'
Assert-Diagnostic (@($missingReport.Ports | Where-Object { $_.Status -ne 'Non verifie' }).Count -eq 0) 'Un port inconnu est annonce libre.'
Write-Host 'OK : outils absents et lecture des ports impossible.'

$freeReport = & {
    function Find-DeveloperExecutable { return $null }
    function Get-DeveloperListeningPorts { return @() }
    Get-DeveloperDiagnostic -CheckedPorts @(5173)
}
Assert-Diagnostic ($freeReport.Ports[0].Status -eq 'Libre') 'Port libre mal restitue.'
Write-Host 'OK : absence ecoute TCP restituee.'

$busyReport = & {
    function Find-DeveloperExecutable { return $null }
    function Get-DeveloperListeningPorts { return @(5173) }
    Get-DeveloperDiagnostic -CheckedPorts @(3000, 5173)
}
Assert-Diagnostic ($busyReport.Ports[0].Status -eq 'Libre' -and $busyReport.Ports[1].Status -eq 'Occupe') 'Port occupe mal restitue.'
Write-Host 'OK : distinction entre ports libres et occupes.'

$resolved = & {
    function Get-Command {
        [CmdletBinding()]
        param($Name, $CommandType, [switch]$All)
        [pscustomobject]@{ Source = 'C:\Users\DEMO\AppData\Local\Microsoft\WindowsApps\python.exe' }
    }
    Find-DeveloperExecutable @('python.exe')
}
Assert-Diagnostic ($null -eq $resolved) 'Un alias Windows susceptible de lancer le Store est selectionne.'
Write-Host 'OK : alias Windows ignores.'

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try {
    $listener.Start()
    $ownedPort = $listener.LocalEndpoint.Port
    $observed = @(Get-DeveloperListeningPorts)
    if ($ownedPort -in $observed) {
        Write-Host 'OK : ecoute TCP reelle observee.'
    }
    else {
        # Certaines sessions isolees peuvent ouvrir une ecoute invisible aux
        # tables TCP du poste. Corroborer avant de classer ce test non verifie.
        $systemSeesPort = $false
        $referencePort = $null
        foreach ($connection in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
            if ($connection.LocalPort -eq $ownedPort) { $systemSeesPort = $true }
            if ($connection.LocalPort -gt 0 -and $null -eq $referencePort) { $referencePort = [int]$connection.LocalPort }
        }
        Assert-Diagnostic (-not $systemSeesPort) 'L API du diagnostic omet une ecoute visible par Windows.'
        if ($null -ne $referencePort) {
            Assert-Diagnostic ($referencePort -in $observed) 'Une ecoute du poste visible par Windows est absente du diagnostic.'
            Write-Host 'OK : ecoute reelle du poste corroboree avec les tables TCP Windows.'
        }
        Write-Host 'NON VERIFIE : ecoute factice invisible dans les tables TCP .NET et Windows de cette session.'
    }
    Assert-Diagnostic ($listener.Server.IsBound) 'Le diagnostic a ferme le serveur existant.'
}
finally { $listener.Stop() }
Write-Host 'OK : serveur de test preserve.'
Write-Host ('SUCCES - Diagnostic developpeur / PowerShell ' + $PSVersionTable.PSVersion)
