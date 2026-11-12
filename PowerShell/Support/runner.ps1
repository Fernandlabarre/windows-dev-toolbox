param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Project,
    [string]$IdeContextPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$env:PYTHONIOENCODING = 'utf-8'
if ([string]::IsNullOrWhiteSpace($IdeContextPath)) {
    Remove-Item Env:SCRIPTS_PERSO_IDE_CONTEXT_PATH -ErrorAction SilentlyContinue
}
else {
    $env:SCRIPTS_PERSO_IDE_CONTEXT_PATH = [IO.Path]::GetFullPath($IdeContextPath)
}

# Attend que le parent ait protege tout l'arbre de processus. Un evenement
# Windows dedie laisse l'entree standard disponible pour les futures reponses.
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

function global:Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
        [object]$Separator = ' ',
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline
    )
    $message = (@($Object) | ForEach-Object { [string]$_ }) -join [string]$Separator
    [Console]::Out.WriteLine($message)
    [Console]::Out.Flush()
}

function global:Read-Host {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Prompt)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Prompt))
    [Console]::Out.WriteLine('__SCRIPTS_PERSO_INPUT__:' + $encoded)
    [Console]::Out.Flush()
    $response = [Console]::ReadLine()
    if ($null -eq $response) { throw 'Canal de reponse ferme.' }
    return $response
}

try {
    Set-Location -LiteralPath $Project
    if ($Target.EndsWith('.py', [StringComparison]::OrdinalIgnoreCase)) {
        if (Get-Command py -ErrorAction SilentlyContinue) { & py -3 -u $Target }
        elseif (Get-Command python -ErrorAction SilentlyContinue) { & python -u $Target }
        else { throw 'Python introuvable.' }
        exit $LASTEXITCODE
    }
    & $Target
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
