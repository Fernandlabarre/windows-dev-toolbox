# Verification sans Ollama reel : API HTTP locale, ephemere et factice.
$ErrorActionPreference = 'Stop'

function ConvertTo-OllamaTestArgument([string]$Value) {
    $quoted = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}

function Start-OllamaTestFixture([string]$Scratch) {
    $python = @(Get-Command python.exe, python3.exe -CommandType Application -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '(?i)[\\/]Microsoft[\\/]WindowsApps[\\/]' } | Select-Object -First 1)
    if ($python.Count -eq 0) { throw 'Python est requis pour le serveur HTTP factice.' }
    $portFile = Join-Path $Scratch ('ollama-port-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $fixture = Join-Path $PSScriptRoot 'Fixtures\ollama-http.py'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $python[0].Source
    $start.Arguments = '-B -u ' + (ConvertTo-OllamaTestArgument $fixture) + ' --port-file ' + (ConvertTo-OllamaTestArgument $portFile)
    $start.WorkingDirectory = $Scratch
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $portFile) -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 25 }
        if (-not (Test-Path -LiteralPath $portFile)) { throw 'Le serveur HTTP factice ne demarre pas.' }
        $portNumber = [int][IO.File]::ReadAllText($portFile)
        if ($portNumber -lt 1 -or $portNumber -gt 65535) { throw 'Port factice invalide.' }
        return [pscustomobject]@{ Process = $process; Port = $portNumber }
    }
    catch { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose(); throw }
}

function Stop-OllamaTestFixture([object]$Fixture) {
    if ($Fixture -and $Fixture.Process) {
        if (-not $Fixture.Process.HasExited) { $Fixture.Process.Kill() }
        if (-not $Fixture.Process.WaitForExit(5000)) { throw 'Le serveur HTTP factice ne termine pas.' }
        $Fixture.Process.Dispose()
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
function Assert-OllamaTest([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$ollamaTestRepo = [IO.Directory]::GetParent($PSScriptRoot).FullName
. (Join-Path $ollamaTestRepo 'PowerShell\04-assistant-ollama-local.ps1') -Project $ollamaTestRepo
$ollamaTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$ollamaScratch = Join-Path $ollamaTempParent ('scripts-perso-ollama-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($ollamaScratch)
$ollamaFixture = $null
try {
    $ollamaFixture = Start-OllamaTestFixture $ollamaScratch
    $fixtureState = Ensure-LocalAssistantOllama $ollamaFixture.Port
    Assert-OllamaTest ($fixtureState.Ready -and -not $fixtureState.Started) 'Un serveur local deja pret est redemarre.'
    $contextProject = Join-Path $ollamaScratch 'context-project'
    $contextServer = Join-Path $contextProject 'server'
    [void][IO.Directory]::CreateDirectory($contextServer)
    $contextSource = Join-Path $contextServer 'context-demo.ts'
    [IO.File]::WriteAllText($contextSource, "export const source = 'SAVED_DISK_CONTEXT';", [Text.UTF8Encoding]::new($false))
    $contextPath = Join-Path $ollamaScratch ('scripts-perso-vscode-' + [Guid]::NewGuid().ToString('N') + '.json')
    $contextPayload = [ordered]@{
        version = 1
        createdAt = [DateTime]::UtcNow.ToString('o')
        workspaceRoot = $contextProject
        activeFile = [ordered]@{
            path = $contextSource; relativePath = 'server/context-demo.ts'; languageId = 'typescript'; isDirty = $true
            selectedText = "source = 'UNSAVED_IDE_CONTEXT'"; content = "export const source = 'UNSAVED_IDE_CONTEXT';`nAPI_KEY=DEMO_PRIVATE_CONTEXT"
            contentScope = 'document'; blockedReason = $null
        }
    }
    [IO.File]::WriteAllText($contextPath, ($contextPayload | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $ideContext = Read-LocalAssistantIdeContext -ContextPath $contextPath -ProjectPath $contextProject
    Assert-OllamaTest ($ideContext.Status -eq 'Pret' -and $ideContext.IsDirty -and $ideContext.RelativePath -eq 'server/context-demo.ts' -and
        $ideContext.Content.Contains('UNSAVED_IDE_CONTEXT')) 'Le contexte IDE actif n est pas charge.'
    $contextMessages = @(New-LocalAssistantMessages -Text 'demo:context' -FileContext $ideContext)
    Assert-OllamaTest ($contextMessages[1].content.Contains('UNSAVED_IDE_CONTEXT') -and
        -not $contextMessages[1].content.Contains('DEMO_PRIVATE_CONTEXT')) 'Le contexte IDE ou son filtrage est incorrect.'
    $result = Invoke-LocalAssistantQuestion -Text 'demo:context' -LocalPort $ollamaFixture.Port -LimitSeconds 5 -FileContext $ideContext
    Assert-OllamaTest ($result.Status -eq 'Reussi' -and $result.Text -eq 'CONTEXT_OK') ('Contexte IDE non transmis a Ollama : ' + $result.Detail)

    $mentioned = Read-LocalAssistantMentionedFile -Text 'Explique @server/context-demo.ts' -ProjectPath $contextProject
    Assert-OllamaTest ($mentioned.Status -eq 'Pret' -and -not $mentioned.IsDirty -and $mentioned.Content.Contains('SAVED_DISK_CONTEXT')) 'Le fichier mentionne par @ n est pas charge.'
    $outside = Read-LocalAssistantMentionedFile -Text 'Explique @../hors-projet.ts' -ProjectPath $contextProject
    Assert-OllamaTest ($outside.Status -eq 'Refuse') 'Un chemin hors projet est accepte.'
    [IO.File]::WriteAllText((Join-Path $contextProject '.env'), 'DEMO=NOT_A_SECRET', [Text.UTF8Encoding]::new($false))
    $sensitive = Read-LocalAssistantMentionedFile -Text 'Explique @.env' -ProjectPath $contextProject
    Assert-OllamaTest ($sensitive.Status -eq 'Refuse') 'Un fichier sensible est accepte.'
    Write-Host 'OK : contexte VS Code non enregistre, @fichier et garde-fous.'

    $result = Invoke-LocalAssistantQuestion -Text ('demo:utf8 caf' + [char]0xE9) -LocalPort $ollamaFixture.Port -LimitSeconds 5
    Assert-OllamaTest ($result.Status -eq 'Reussi' -and $result.HttpStatus -eq 200 -and $result.Text.Contains('caf' + [char]0xE9)) ('Contrat ou UTF-8 incorrect : ' + $result.Detail)
    Assert-OllamaTest ($result.Model -eq 'qwen2.5-coder:7b') 'Le modele configure a change.'
    Write-Host 'OK : API chat locale, modele existant, UTF-8 et reponse complete.'

    foreach ($case in @('missing','server-error','redirect','api-error','invalid-json','wrong-model','empty','oversize')) {
        $result = Invoke-LocalAssistantQuestion -Text ('demo:' + $case) -LocalPort $ollamaFixture.Port -LimitSeconds 5
        Assert-OllamaTest ($result.Status -eq 'Echec') ('Echec non detecte : ' + $case)
        Assert-OllamaTest (($result.Detail + $result.Text) -notlike '*DEMO_PRIVATE_ERROR*') 'Erreur brute divulguee.'
        if ($case -eq 'redirect') { Assert-OllamaTest ($result.HttpStatus -eq 307) 'La redirection a ete suivie.' }
    }
    foreach ($case in @('unfinished','length','display-limit')) {
        $result = Invoke-LocalAssistantQuestion -Text ('demo:' + $case) -LocalPort $ollamaFixture.Port -LimitSeconds 5
        Assert-OllamaTest ($result.Status -eq 'Partiel' -and $result.Text.Length -le 32000) ('Reponse partielle non detectee : ' + $case)
    }
    foreach ($questionText in @(' ', ('x' * 8001))) {
        $result = Invoke-LocalAssistantQuestion -Text $questionText -LocalPort $ollamaFixture.Port
        Assert-OllamaTest ($result.Status -eq 'Echec' -and $null -eq $result.HttpStatus) 'Question invalide envoyee.'
    }
    Write-Host 'OK : erreurs HTTP/JSON, redirection refusee, modele incorrect, limites et reponses partielles.'

    foreach ($case in @('slow-headers','slow-body')) {
        $result = Invoke-LocalAssistantQuestion -Text ('demo:' + $case) -LocalPort $ollamaFixture.Port -LimitSeconds 1
        Assert-OllamaTest ($result.Status -eq 'Echec' -and $result.Detail -like 'Delai*' -and $result.Seconds -lt 4) ('Delai non respecte : ' + $case)
    }
    Write-Host 'OK : delai global, avant et apres les en-tetes HTTP.'

    $result = Invoke-LocalAssistantQuestion -Text 'demo:mask' -LocalPort $ollamaFixture.Port -LimitSeconds 5
    Assert-OllamaTest ($result.Status -eq 'Reussi' -and $result.Text.Contains('OK_MASK') -and $result.Text -notlike '*DEMO_PRIVATE_*') 'Filtrage des sorties incorrect.'
    $result = Invoke-LocalAssistantQuestion -Text 'demo:gui' -LocalPort $ollamaFixture.Port -LimitSeconds 5
    $printed = @(Write-LocalAssistantAnswer $result 6>&1) | ForEach-Object { [string]$_ }
    Assert-OllamaTest (@($printed | Where-Object { $_.StartsWith('__SCRIPTS_PERSO_INPUT__:') }).Count -eq 0) 'Le modele peut injecter une question GUI.'
    Assert-OllamaTest (@($printed | Where-Object { $_.StartsWith('| __SCRIPTS_PERSO_INPUT__:') }).Count -eq 1) 'La ligne du modele n est pas affichee comme du texte.'
    Write-Host 'OK : sorties filtrees et protocole du lanceur protege.'

    $target = Join-Path $ollamaTestRepo 'PowerShell\04-assistant-ollama-local.ps1'
    $result = & $target -Project $contextProject -Question 'demo:context' -Port $ollamaFixture.Port -IdeContextPath $contextPath -PassThru 6>$null
    Assert-OllamaTest ($result.Status -eq 'Reussi' -and $result.Text -eq 'CONTEXT_OK') 'Parcours complet avec contexte IDE incorrect.'
    $result = & $target -Project $ollamaScratch -Question 'demo:gui' -Port $ollamaFixture.Port -PassThru 6>$null
    Assert-OllamaTest ($result.Status -eq 'Reussi' -and $result.Text.Contains('GUI_OLLAMA_OK')) 'Parcours du script incorrect.'
    $result = & $target -Project $ollamaScratch -Question 'Q' -Port $ollamaFixture.Port -PassThru 6>$null
    Assert-OllamaTest ($result.Status -eq 'Annule' -and $null -eq $result.HttpStatus) 'Annulation non respectee.'
    $result = & $target -Project $ollamaScratch -Question ' ' -Port $ollamaFixture.Port -PassThru 6>$null
    Assert-OllamaTest ($result.Status -eq 'Annule') 'Question vide non annulee.'
    $result = & $target -Project (Join-Path $ollamaScratch 'projet-absent') -Question 'demo:gui' -Port $ollamaFixture.Port -PassThru 6>$null
    Assert-OllamaTest ($result.Status -eq 'Echec' -and $null -eq $result.HttpStatus) 'Projet invalide non signale dans le rapport.'
    $closedPort = $ollamaFixture.Port
    Stop-OllamaTestFixture $ollamaFixture
    $ollamaFixture = $null
    $closedState = Ensure-LocalAssistantOllama $closedPort
    Assert-OllamaTest (-not $closedState.Ready -and -not $closedState.Started) 'Un port personnalise indisponible declenche un serveur.'
    $result = Invoke-LocalAssistantQuestion -Text 'demo:offline' -LocalPort $closedPort -LimitSeconds 5
    Assert-OllamaTest ($result.Status -eq 'Echec' -and $null -eq $result.HttpStatus -and $result.Detail -match 'injoignable|Delai') 'Ollama absent non signale.'
    Write-Host 'OK : script complet, annulation et serveur absent.'
    Write-Host ('SUCCES - Assistant Ollama / PowerShell ' + $PSVersionTable.PSVersion)
}
finally {
    Stop-OllamaTestFixture $ollamaFixture
    $resolvedOllamaScratch = [IO.Path]::GetFullPath($ollamaScratch)
    if ([IO.Directory]::GetParent($resolvedOllamaScratch).FullName -ne $ollamaTempParent -or
        -not [IO.Path]::GetFileName($resolvedOllamaScratch).StartsWith('scripts-perso-ollama-')) { throw 'Nettoyage hors du dossier temporaire refuse.' }
    Remove-Item -LiteralPath $resolvedOllamaScratch -Recurse -Force
}
