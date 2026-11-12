# Integration sur fichiers factices ; -Gui active aussi le parcours graphique.
param([switch]$Gui)

$ErrorActionPreference = 'Stop'
$testRepoRoot = [IO.Directory]::GetParent($PSScriptRoot).FullName
$testSupport = Join-Path $testRepoRoot 'PowerShell\Support'
$testRunner = Join-Path $testSupport 'runner.ps1'
$engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$testEngine = Join-Path $PSHOME $engineName
$testTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testScratch = Join-Path $testTempParent ('scripts-perso-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testScratch)
$testProcesses = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'

function Assert-Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Test-TextContains([string]$text, [string]$expected) {
    return $text.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Write-Fixture([string]$path, [string]$content) {
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($true))
}

function Start-Fixture([string]$path, [string]$project) {
    $arguments = '-NoProfile -File ' + [ScriptsPerso.ProcessRunner]::QuoteArgument($testRunner) +
        ' -Target ' + [ScriptsPerso.ProcessRunner]::QuoteArgument($path) +
        ' -Project ' + [ScriptsPerso.ProcessRunner]::QuoteArgument($project)
    $process = [ScriptsPerso.ProcessRunner]::Launch($testEngine, $arguments, $project)
    $testProcesses.Add($process)
    return $process
}

function Read-Messages {
    [string]$message = $null
    while ([ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$message)) { $message }
}

function Complete-Fixture([Diagnostics.Process]$process) {
    # Le premier démarrage de Windows PowerShell est nettement plus lent sur
    # un runner GitHub fraîchement créé que sur une machine déjà initialisée.
    Assert-Check ($process.WaitForExit(60000)) 'Le processus de test ne termine pas.'
    [ScriptsPerso.ProcessRunner]::Release($process)
    $process.WaitForExit()
}

function Test-GraphicalLauncher {
    Add-Type -AssemblyName System.Windows.Forms
    $copyRoot = Join-Path $testScratch 'Bibliotheque avec espaces [1]'
    $copyPowerShell = Join-Path $copyRoot 'PowerShell'
    $copySupport = Join-Path $copyPowerShell 'Support'
    $copyGit = Join-Path $copyRoot 'Git'
    $copyPython = Join-Path $copyRoot 'Python'
    $copyTests = Join-Path $copyRoot 'Tests'
    foreach ($directory in @($copySupport, $copyGit, $copyPython, $copyTests)) { [void][IO.Directory]::CreateDirectory($directory) }
    Copy-Item -LiteralPath (Join-Path $testRepoRoot 'PowerShell\menu-scripts.ps1') -Destination $copyPowerShell
    foreach ($name in @('runner.ps1', 'ScriptsPersoRunner.cs')) {
        Copy-Item -LiteralPath (Join-Path $testSupport $name) -Destination $copySupport
    }
    Copy-Item -LiteralPath (Join-Path $testRepoRoot 'PowerShell\01-diagnostic-developpeur.ps1') -Destination $copyPowerShell
    Copy-Item -LiteralPath (Join-Path $testRepoRoot 'PowerShell\02-gerer-serveurs-locaux.ps1') -Destination $copyPowerShell
    Copy-Item -LiteralPath (Join-Path $testRepoRoot 'PowerShell\03-centre-tests.ps1') -Destination $copyPowerShell
    Copy-Item -LiteralPath (Join-Path $testRepoRoot 'Python\03-analyser-espace-projet.py') -Destination $copyPython
    [IO.File]::WriteAllBytes((Join-Path $project 'volume-demo.bin'), (New-Object byte[] 4096))
    $projectTests = Join-Path $project 'Tests'
    [void][IO.Directory]::CreateDirectory($projectTests)
    Write-Fixture (Join-Path $projectTests 'test-centre-demo.ps1') "Write-Host 'GUI_CONTROL_OK'; exit 0"
    $contextSource = Join-Path $project 'context-demo.ts'
    Write-Fixture $contextSource "export const source = 'SAVED_GUI_CONTEXT';"
    $contextPath = Join-Path $testScratch ('scripts-perso-vscode-' + [Guid]::NewGuid().ToString('N') + '.json')
    $contextPayload = [ordered]@{
        version = 1; createdAt = [DateTime]::UtcNow.ToString('o'); workspaceRoot = $project
        activeFile = [ordered]@{
            path = $contextSource; relativePath = 'context-demo.ts'; languageId = 'typescript'; isDirty = $true
            selectedText = ''; content = "export const source = 'UNSAVED_GUI_CONTEXT';"; contentScope = 'document'; blockedReason = $null
        }
    }
    [IO.File]::WriteAllText($contextPath, ($contextPayload | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    # Intercepter uniquement l'ouverture de la console du gestionnaire dans
    # ce processus de test ; les serveurs reels sont testes separement.
    function Start-Process {
        [CmdletBinding()]
        param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle)
        $global:ScriptsPersoGuiCheck.ManagerLaunch = @{ FilePath = $FilePath; Arguments = [string]$ArgumentList; Project = $WorkingDirectory; WindowStyle = [string]$WindowStyle }
    }
    Write-Fixture (Join-Path $copyTests 'ne-pas-afficher.ps1') "throw 'TEST_IN_MENU'"
    Write-Fixture (Join-Path $copyGit '01-etat-depot.ps1') @'
$answer = Read-Host 'Test graphique (O/N)'
$receipt = 'ANSWER=' + $answer + '|ENGINE=' + $PSVersionTable.PSVersion.Major
[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'gui-result.txt'), $receipt)
'@
    . (Join-Path $PSScriptRoot 'test-assistant-ollama.ps1')
    $guiOllamaFixture = Start-OllamaTestFixture $testScratch
    try {
    $assistantSource = [IO.File]::ReadAllText((Join-Path $testRepoRoot 'PowerShell\04-assistant-ollama-local.ps1'))
    $portSetting = '[int]$Port = 11434'
    Assert-Check ($assistantSource.Contains($portSetting)) 'Port par defaut introuvable dans l assistant.'
    Write-Fixture (Join-Path $copyPowerShell '04-assistant-ollama-local.ps1') ($assistantSource.Replace($portSetting, ('[int]$Port = ' + $guiOllamaFixture.Port)))
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        # Le callback s'execute pendant ShowDialog dans la portee du menu.
        # Une variable globale de CE processus de test evite les differences
        # de portee des delegates PowerShell entre 5.1 et 7.
        $toolName = switch ($attempt) { 1 { 'Etat du depot' } 2 { 'Diagnostic developpeur' } 3 { 'Serveurs locaux' } 4 { 'Centre de tests' } 5 { 'Assistant Ollama local' } 6 { 'Espace du projet' } }
        $global:ScriptsPersoGuiCheck = @{ Started = $false; Answered = ($attempt -eq 2 -or $attempt -eq 3 -or $attempt -eq 6); SelectionSent = $false; Completed = $false; Error = $null; Project = $project; ToolName = $toolName; ManagerLaunch = $null; Deadline = [DateTime]::UtcNow.AddSeconds(30) }
        $idleAction = {
            $form = @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'Scripts-Perso - Mes outils' } | Select-Object -First 1)
            if ($form.Count -eq 0) { return }
            $window = $form[0]
            $window.Opacity = 0
            try {
                if ([DateTime]::UtcNow -gt $global:ScriptsPersoGuiCheck.Deadline) { throw 'Delai du test graphique depasse.' }
                $controls = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Control]'
                $pending = New-Object 'System.Collections.Generic.Queue[System.Windows.Forms.Control]'
                $pending.Enqueue($window)
                while ($pending.Count -gt 0) {
                    foreach ($control in $pending.Dequeue().Controls) { $controls.Add($control); $pending.Enqueue($control) }
                }
                if (-not $global:ScriptsPersoGuiCheck.Started) {
                    if (@($controls | Where-Object { $_.Text -eq ('Projet actif : ' + $global:ScriptsPersoGuiCheck.Project) }).Count -ne 1) { throw 'Mauvais projet dans la fenetre.' }
                    if (@($controls | Where-Object { $_.Text -like '*ne-pas-afficher*' -or $_.Text -eq 'runner' }).Count -ne 0) { throw 'Un script interne est affiche dans le menu.' }
                    $label = @($controls | Where-Object { $_ -is [Windows.Forms.Label] -and $_.Text -eq $global:ScriptsPersoGuiCheck.ToolName })
                    if ($label.Count -ne 1) {
                        $visibleNames = @($controls | Where-Object { $_ -is [Windows.Forms.Label] } | ForEach-Object { $_.Text }) -join ' | '
                        throw ('Outil absent : ' + $global:ScriptsPersoGuiCheck.ToolName + '. Libelles : ' + $visibleNames)
                    }
                    $button = @($label[0].Parent.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Lancer' })[0]
                    $global:ScriptsPersoGuiCheck.Started = $true
                    # Poste une methode .NET pure : les delegates PowerShell
                    # imbriques peuvent bloquer le moteur 5.1.
                    $click = [Delegate]::CreateDelegate([Action], $button, 'PerformClick')
                    [void]$button.BeginInvoke($click)
                }
                elseif (-not $global:ScriptsPersoGuiCheck.Answered) {
                    if (($global:ScriptsPersoGuiCheck.ToolName -eq 'Centre de tests' -and -not $global:ScriptsPersoGuiCheck.SelectionSent) -or
                        $global:ScriptsPersoGuiCheck.ToolName -eq 'Assistant Ollama local') {
                        $fields = @($controls | Where-Object { $_ -is [Windows.Forms.TextBox] -and $_.Visible })
                        $submit = @($controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Valider' -and $_.Visible })
                        if ($fields.Count -eq 1 -and $submit.Count -eq 1) {
                            if ($global:ScriptsPersoGuiCheck.ToolName -eq 'Assistant Ollama local') {
                                $fields[0].Text = 'demo:gui'
                                $global:ScriptsPersoGuiCheck.Answered = $true
                            }
                            else { $fields[0].Text = 'T'; $global:ScriptsPersoGuiCheck.SelectionSent = $true }
                            $click = [Delegate]::CreateDelegate([Action], $submit[0], 'PerformClick')
                            [void]$submit[0].BeginInvoke($click)
                        }
                    }
                    else {
                        $yes = @($controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Oui' -and $_.Visible })
                        if ($yes.Count -eq 1) {
                            $global:ScriptsPersoGuiCheck.Answered = $true
                            $click = [Delegate]::CreateDelegate([Action], $yes[0], 'PerformClick')
                            [void]$yes[0].BeginInvoke($click)
                        }
                    }
                }
                elseif ($global:ScriptsPersoGuiCheck.ToolName -eq 'Serveurs locaux' -and
                    @($controls | Where-Object { $_ -is [Windows.Forms.Label] -and $_.Text -eq 'Gestionnaire ouvert dans une console dediee.' }).Count -eq 1) {
                    $launch = $global:ScriptsPersoGuiCheck.ManagerLaunch
                    if ($null -eq $launch -or $launch.Project -ne $global:ScriptsPersoGuiCheck.Project -or
                        -not (Test-TextContains $launch.Arguments '02-gerer-serveurs-locaux.ps1') -or
                        -not (Test-TextContains $launch.Arguments $global:ScriptsPersoGuiCheck.Project) -or $launch.WindowStyle -ne 'Normal') {
                        throw 'Mauvaise ouverture du gestionnaire dans une console independante.'
                    }
                    $global:ScriptsPersoGuiCheck.Completed = $true
                    $close = [Delegate]::CreateDelegate([Action], $window, 'Close')
                    [void]$window.BeginInvoke($close)
                }
                elseif (@($controls | Where-Object { $_ -is [Windows.Forms.Label] -and $_.Text -eq 'Termine (code 0)' }).Count -eq 1) {
                    if ($global:ScriptsPersoGuiCheck.ToolName -eq 'Diagnostic developpeur') {
                        $logs = @($controls | Where-Object { $_ -is [Windows.Forms.RichTextBox] })[0].Text
                        if ($logs -notlike '*DIAGNOSTIC DEVELOPPEUR*' -or $logs -notlike '*Diagnostic termine.*') { throw 'Rapport du diagnostic absent du lanceur.' }
                        if (-not (Test-TextContains $logs ('Projet : ' + $global:ScriptsPersoGuiCheck.Project))) {
                            throw ('Mauvais projet dans le rapport. Attendu : ' + $global:ScriptsPersoGuiCheck.Project + ' | Journal : ' + ($logs -replace "`r?`n", ' / '))
                        }
                    }
                    if ($global:ScriptsPersoGuiCheck.ToolName -eq 'Centre de tests') {
                        $logs = @($controls | Where-Object { $_ -is [Windows.Forms.RichTextBox] })[0].Text
                        if (-not $logs.Contains('BILAN DES CONTROLES') -or -not $logs.Contains('GUI_CONTROL_OK') -or -not $logs.Contains('Reussi')) { throw 'Bilan du Centre de tests absent ou incorrect.' }
                        if (-not (Test-TextContains $logs ('Projet : ' + $global:ScriptsPersoGuiCheck.Project))) { throw 'Mauvais projet dans le Centre de tests.' }
                    }
                    if ($global:ScriptsPersoGuiCheck.ToolName -eq 'Assistant Ollama local') {
                        $logs = @($controls | Where-Object { $_ -is [Windows.Forms.RichTextBox] })[0].Text
                        if (-not $logs.Contains('ASSISTANT OLLAMA LOCAL') -or -not $logs.Contains('| GUI_OLLAMA_OK') -or -not $logs.Contains('| __SCRIPTS_PERSO_INPUT__:')) { throw 'Reponse Ollama absente ou interpretee comme une question.' }
                        if (-not (Test-TextContains $logs ('Projet : ' + $global:ScriptsPersoGuiCheck.Project))) { throw 'Mauvais projet dans l assistant Ollama.' }
                        if (-not $logs.Contains('Contexte IDE : context-demo.ts (modifications non enregistrees incluses).')) { throw 'Contexte IDE absent de l assistant Ollama.' }
                    }
                    if ($global:ScriptsPersoGuiCheck.ToolName -eq 'Espace du projet') {
                        $logs = @($controls | Where-Object { $_ -is [Windows.Forms.RichTextBox] })[0].Text
                        if (-not $logs.Contains('ESPACE DU PROJET') -or -not $logs.Contains('volume-demo.bin') -or -not $logs.Contains('Complet dans le perimetre mesure')) { throw 'Rapport espace absent ou incomplet.' }
                        if (-not (Test-TextContains $logs ('Projet : ' + $global:ScriptsPersoGuiCheck.Project))) { throw 'Mauvais projet dans le rapport espace.' }
                    }
                    $global:ScriptsPersoGuiCheck.Completed = $true
                    $close = [Delegate]::CreateDelegate([Action], $window, 'Close')
                    [void]$window.BeginInvoke($close)
                }
            }
            catch { $global:ScriptsPersoGuiCheck.Error = $_.Exception.Message; $window.Dispose() }
        }
        $guiTimer = New-Object Windows.Forms.Timer
        $guiTimer.Interval = 50
        $guiTimer.Add_Tick($idleAction)
        $guiTimer.Start()
        Push-Location -LiteralPath $project
        Write-Host ('Verification graphique : ouverture ' + $attempt + '/6.')
        try { & (Join-Path $copyPowerShell 'menu-scripts.ps1') -Project $project -IdeContextPath $contextPath }
        finally {
            Pop-Location
            $guiTimer.Stop()
            $guiTimer.Dispose()
        }
        Assert-Check ($null -eq $global:ScriptsPersoGuiCheck.Error) ([string]$global:ScriptsPersoGuiCheck.Error)
        Assert-Check ($global:ScriptsPersoGuiCheck.Completed) ('Le parcours graphique ne termine pas. Etat : ' + ($global:ScriptsPersoGuiCheck | ConvertTo-Json -Compress))
        $receipt = [IO.File]::ReadAllText((Join-Path $project 'gui-result.txt'))
        Assert-Check ($receipt -eq ('ANSWER=O|ENGINE=' + $PSVersionTable.PSVersion.Major)) 'Mauvaise reponse ou famille de PowerShell dans le lanceur.'
    }
    }
    finally { Stop-OllamaTestFixture $guiOllamaFixture }
    Write-Host 'OK : lanceur deplace, diagnostic, console serveur, Centre de tests, assistant Ollama et espace du projet.'
}

try {
    foreach ($file in (Get-ChildItem -LiteralPath $testRepoRoot -Filter '*.ps1' -Recurse -File)) {
        $parseTokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$parseTokens, [ref]$parseErrors)
        Assert-Check (@($parseErrors).Count -eq 0) ('Syntaxe invalide : ' + $file.Name)
    }
    Write-Host 'OK : syntaxe PowerShell.'

    if (-not ('ScriptsPerso.ProcessRunner' -as [type])) {
        Add-Type -LiteralPath (Join-Path $testSupport 'ScriptsPersoRunner.cs')
    }
    $project = Join-Path $testScratch 'Projet avec espaces [1]'
    [void][IO.Directory]::CreateDirectory($project)
    $tool = Join-Path $testScratch 'outil avec espaces.ps1'
    Write-Fixture $tool @'
$answer = Read-Host 'Reponse de test (O/N)'
Write-Host ('ANSWER=' + $answer)
Write-Host ('PROJECT=' + (Get-Location).Path)
'@
    $process = Start-Fixture $tool $project
    $messages = @()
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $messages += @(Read-Messages)
        if (@($messages | Where-Object { $_ -like 'O__SCRIPTS_PERSO_INPUT__:*' }).Count -gt 0) { break }
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    $promptCount = @($messages | Where-Object { $_ -like 'O__SCRIPTS_PERSO_INPUT__:*' }).Count
    if ($promptCount -ne 1) {
        $state = if ($process.HasExited) { 'termine, code ' + $process.ExitCode } else { 'encore actif' }
        $detail = if ($messages.Count) { $messages -join ' | ' } else { 'aucun message' }
        throw "Question du script non transmise (processus $state ; $detail)."
    }
    $answer = 'DEMO_' + [char]0xE9
    $process.StandardInput.WriteLine($answer)
    $process.StandardInput.Flush()
    Complete-Fixture $process
    $messages += @(Read-Messages)
    Assert-Check ($process.ExitCode -eq 0) 'Echec du script interactif.'
    Assert-Check ($messages -contains ('OANSWER=' + $answer)) 'Reponse UTF-8 alteree.'
    Assert-Check ($messages -contains ('OPROJECT=' + $project)) 'Mauvais dossier projet.'
    Write-Host 'OK : chemins avec espaces et crochets, confirmations et UTF-8.'

    Write-Fixture $tool "Write-Host ('PROJECT=' + (Get-Location).Path)"
    $driveRoot = [IO.Path]::GetPathRoot($testScratch)
    $process = Start-Fixture $tool $driveRoot
    Complete-Fixture $process
    $messages = @(Read-Messages)
    Assert-Check ($process.ExitCode -eq 0 -and $messages -contains ('OPROJECT=' + $driveRoot)) 'Chemin termine par un antislash altere.'
    Write-Host 'OK : chemin de racine termine par un antislash.'

    $pythonTool = Join-Path $testScratch 'outil python.py'
    Write-Fixture $pythonTool 'print("PYTHON_" + chr(233), flush=True)'
    $process = Start-Fixture $pythonTool $project
    Complete-Fixture $process
    Assert-Check ($process.ExitCode -eq 0 -and @(Read-Messages) -contains ('OPYTHON_' + [char]0xE9)) 'Execution Python ou encodage incorrect.'
    Write-Host 'OK : execution Python et sorties UTF-8.'

    Write-Fixture $tool "[Console]::Error.WriteLine('DEMO_FAILURE'); exit 7"
    $process = Start-Fixture $tool $project
    Complete-Fixture $process
    Assert-Check ($process.ExitCode -eq 7 -and @(Read-Messages) -contains 'EDEMO_FAILURE') 'Erreur ou code retour perdu.'
    Write-Host 'OK : erreurs et codes de sortie.'

    foreach ($mode in @('stop', 'release')) {
        $tree = Join-Path $testScratch $mode
        [void][IO.Directory]::CreateDirectory($tree)
        Write-Fixture (Join-Path $tree 'child.ps1') @'
$engine = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
$psi = New-Object Diagnostics.ProcessStartInfo($engine, '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120"')
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$leaf = [Diagnostics.Process]::Start($psi)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'leaf.pid'), [string]$leaf.Id)
Start-Sleep -Seconds 120
'@
        $parentSource = @'
$engine = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
$psi = New-Object Diagnostics.ProcessStartInfo($engine, ('-NoProfile -File "' + (Join-Path $PSScriptRoot 'child.ps1') + '"'))
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$child = [Diagnostics.Process]::Start($psi)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'child.pid'), [string]$child.Id)
Start-Sleep -Seconds 120
'@
        if ($mode -eq 'release') { $parentSource = $parentSource.Replace('Start-Sleep -Seconds 120', 'exit 0') }
        $parentPath = Join-Path $tree 'parent.ps1'
        Write-Fixture $parentPath $parentSource
        $process = Start-Fixture $parentPath $tree
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $childMarker = Join-Path $tree 'child.pid'
        $leafMarker = Join-Path $tree 'leaf.pid'
        while (-not ((Test-Path -LiteralPath $childMarker) -and (Test-Path -LiteralPath $leafMarker)) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
        }
        Assert-Check ((Test-Path -LiteralPath $childMarker) -and (Test-Path -LiteralPath $leafMarker)) 'Les sous-processus factices ne sont pas prets.'
        $descendants = @(
            [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($childMarker))
            [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($leafMarker))
        )
        try {
            if ($mode -eq 'stop') { [ScriptsPerso.ProcessRunner]::Stop($process) }
            Complete-Fixture $process
            foreach ($descendant in $descendants) {
                Assert-Check ($descendant.WaitForExit(5000)) ('Sous-processus encore actif apres ' + $mode)
            }
        }
        finally { foreach ($descendant in $descendants) { $descendant.Dispose() } }
        $null = @(Read-Messages)
        Write-Host ('OK : parent, enfant et petit-enfant arretes (' + $mode + ').')
    }
    if ($Gui) { Test-GraphicalLauncher }
    Write-Host ('SUCCES - PowerShell ' + $PSVersionTable.PSVersion)
}
finally {
    foreach ($process in $testProcesses) {
        [ScriptsPerso.ProcessRunner]::Release($process)
        $process.Dispose()
    }
    $resolvedScratch = [IO.Path]::GetFullPath($testScratch)
    if ([IO.Directory]::GetParent($resolvedScratch).FullName -ne $testTempParent -or
        -not [IO.Path]::GetFileName($resolvedScratch).StartsWith('scripts-perso-tests-')) {
        throw 'Nettoyage hors du dossier temporaire refuse.'
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
