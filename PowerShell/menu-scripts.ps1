# Scripts-Perso - Lanceur graphique avec resultats et validations integres.
# Compatible avec Windows PowerShell 5.1 et PowerShell 7 / WinForms.
# Les outils restent aussi utilisables directement en ligne de commande.
param(
    [string]$Project = (Get-Location).Path,
    [string]$IdeContextPath,
    [string]$ScreenshotPath
)

$ErrorActionPreference = "Stop"
$libraryRoot = [IO.Directory]::GetParent($PSScriptRoot).FullName
$projectItem = Get-Item -LiteralPath $Project
if (-not $projectItem.PSIsContainer -or $projectItem.PSProvider.Name -ne 'FileSystem') { throw 'Choisis un dossier de projet local.' }
$projectRoot = $projectItem.FullName
$runnerPath = Join-Path $PSScriptRoot 'Support\runner.ps1'
$script:ideContextPath = if ([string]::IsNullOrWhiteSpace($IdeContextPath)) { '' } else { [IO.Path]::GetFullPath($IdeContextPath) }

if (-not (Test-Path -LiteralPath $libraryRoot -PathType Container)) {
    throw "Bibliotheque introuvable : $libraryRoot"
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Le processus enfant ecrit dans une file thread-safe. Seul le timer WinForms
# touche aux controles graphiques (pas de script PowerShell sur thread secondaire).
if (-not ('ScriptsPerso.ProcessRunner' -as [type])) {
    Add-Type -LiteralPath (Join-Path $PSScriptRoot 'Support\ScriptsPersoRunner.cs')
}

$catalog = @{
    "Git/01-etat-depot.ps1" = @("Etat du depot", "Branche, fichiers modifies et dernier commit.", "Git")
    "Git/02-voir-modifications.ps1" = @("Voir les modifications", "Examiner les changements avant un commit.", "Git")
    "Git/03-creer-commit.ps1" = @("Creer un commit", "Choisir les fichiers, generer un message, confirmer.", "Git")
    "Git/04-synchroniser-github.ps1" = @("Synchroniser GitHub", "Fetch, pull ou push avec confirmation.", "Git")
    "Python/01-exporter-contexte-projet.py" = @("Exporter un contexte projet", "Preparer un contexte Markdown et une archive de sources.", "IA")
    "PowerShell/01-diagnostic-developpeur.ps1" = @("Diagnostic developpeur", "Versions des outils et ports TCP de developpement.", "Outils")
    "PowerShell/02-gerer-serveurs-locaux.ps1" = @("Serveurs locaux", "Demarrer et arreter un serveur dans une console dediee.", "Outils")
    "PowerShell/03-centre-tests.ps1" = @("Centre de tests", "Choisir les controles et consulter leur bilan.", "Outils")
    "PowerShell/04-assistant-ollama-local.ps1" = @("Assistant Ollama local", "Poser une question au modele local deja configure.", "IA")
    "Python/03-analyser-espace-projet.py" = @("Espace du projet", "Mesurer dossiers, caches et archives en lecture seule.", "Outils")
}
$hidden = @("Git/05-preparer-contexte-ia.ps1", "Python/02-serveur-local.py")
$script:tools = @(
    Get-ChildItem -LiteralPath $libraryRoot -File -Recurse |
        Where-Object { $_.Extension -in @(".ps1", ".py") -and $_.FullName -ne $PSCommandPath } |
        ForEach-Object {
            $relative = $_.FullName.Substring($libraryRoot.Length + 1).Replace("\", "/")
            if ($relative -in $hidden -or $relative -match '^(Tests|PowerShell/Support)/') { return }
            if ($catalog.ContainsKey($relative)) {
                $description = $catalog[$relative]
                $name, $details, $category = $description[0], $description[1], $description[2]
            } else {
                $name = ([IO.Path]::GetFileNameWithoutExtension($_.Name) -replace '^\d+-', '' -replace '-', ' ')
                $details = $relative
                $category = if ($_.Extension -eq '.py') { 'Python' } else { 'Outils' }
            }
            [pscustomobject]@{ Name = $name; Details = $details; Category = $category; File = $_.FullName }
        } | Sort-Object Category, Name
)
if ($script:tools.Count -eq 0) { Write-Host 'Aucun outil trouve.'; return }

function GuiColor([int]$r, [int]$g, [int]$b) { return [Drawing.Color]::FromArgb($r, $g, $b) }
function GuiButton([string]$label, [int]$width) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $label
    $button.Width = $width
    $button.Height = 35
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = GuiColor 28 101 78
    $button.ForeColor = [Drawing.Color]::White
    $button.Cursor = 'Hand'
    return $button
}

$script:form = New-Object Windows.Forms.Form
$script:form.Text = 'Scripts-Perso - Mes outils'
$script:form.ClientSize = [Drawing.Size]::new(850, 680)
$script:form.MinimumSize = [Drawing.Size]::new(670, 500)
$script:form.StartPosition = 'CenterScreen'
$script:form.Font = [Drawing.Font]::new('Segoe UI', 10)
$script:form.BackColor = GuiColor 247 249 252
$script:form.KeyPreview = $true

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 112
$header.BackColor = GuiColor 24 49 74
$heading = New-Object Windows.Forms.Label
$heading.Text = 'Mes outils de developpement'
$heading.ForeColor = [Drawing.Color]::White
$heading.Font = [Drawing.Font]::new('Segoe UI', 17, [Drawing.FontStyle]::Bold)
$heading.SetBounds(20, 12, 790, 37)
$heading.Anchor = 'Top,Left,Right'
$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'Resultats et confirmations directement dans cette fenetre.'
$subtitle.ForeColor = GuiColor 205 220 235
$subtitle.SetBounds(21, 54, 790, 23)
$subtitle.Anchor = 'Top,Left,Right'
$projectLabel = New-Object Windows.Forms.Label
$projectLabel.Text = "Projet actif : $projectRoot"
$projectLabel.ForeColor = GuiColor 165 227 210
$projectLabel.SetBounds(21, 83, 790, 22)
$projectLabel.Anchor = 'Top,Left,Right'
$projectLabel.AutoEllipsis = $true
$header.Controls.AddRange(@($heading, $subtitle, $projectLabel))

$container = New-Object Windows.Forms.Panel
$container.Dock = 'Fill'
$script:homePanel = New-Object Windows.Forms.Panel
$script:homePanel.Dock = 'Fill'
$script:execution = New-Object Windows.Forms.Panel
$script:execution.Dock = 'Fill'
$script:execution.Visible = $false
$container.Controls.AddRange(@($script:homePanel, $script:execution))

$searchArea = New-Object Windows.Forms.Panel
$searchArea.Dock = 'Top'
$searchArea.Height = 63
$script:search = New-Object Windows.Forms.TextBox
$script:search.SetBounds(16, 14, 805, 32)
$script:search.Anchor = 'Top,Left,Right'
$script:search.Font = [Drawing.Font]::new('Segoe UI', 11)
$searchArea.Controls.Add($script:search)

$categoriesPanel = New-Object Windows.Forms.FlowLayoutPanel
$categoriesPanel.Dock = 'Top'
$categoriesPanel.Height = 52
$categoriesPanel.Padding = [Windows.Forms.Padding]::new(13, 3, 0, 0)
$script:category = 'Tous'
$script:categoryButtons = @()
$visibleCategories = @('Tous') + @($script:tools | Select-Object -ExpandProperty Category -Unique)
foreach ($categoryName in $visibleCategories) {
    $button = GuiButton $categoryName 105
    $button.Tag = $categoryName
    $button.Margin = [Windows.Forms.Padding]::new(3)
    $button.Add_Click({
        param($sender, $eventArgs)
        $script:category = [string]$sender.Tag
        Update-Categories
        Update-Tools
    })
    $script:categoryButtons += $button
    $categoriesPanel.Controls.Add($button)
}

$script:toolList = New-Object Windows.Forms.FlowLayoutPanel
$script:toolList.Dock = 'Fill'
$script:toolList.AutoScroll = $true
$script:toolList.FlowDirection = 'TopDown'
$script:toolList.WrapContents = $false
$script:toolList.Padding = [Windows.Forms.Padding]::new(14, 4, 8, 8)
$script:homePanel.Controls.AddRange(@($script:toolList, $categoriesPanel, $searchArea))

# ----------------------------
# Ecran des resultats
# ----------------------------
$runHeader = New-Object Windows.Forms.Panel
$runHeader.Dock = 'Top'
$runHeader.Height = 66
$script:runTitle = New-Object Windows.Forms.Label
$script:runTitle.Font = [Drawing.Font]::new('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$script:runTitle.SetBounds(18, 8, 800, 30)
$script:runTitle.Anchor = 'Top,Left,Right'
$script:runStatus = New-Object Windows.Forms.Label
$script:runStatus.Text = 'En attente'
$script:runStatus.ForeColor = GuiColor 95 107 116
$script:runStatus.SetBounds(18, 39, 800, 22)
$script:runStatus.Anchor = 'Top,Left,Right'
$runHeader.Controls.AddRange(@($script:runTitle, $script:runStatus))

$script:log = New-Object Windows.Forms.RichTextBox
$script:log.Dock = 'Fill'
$script:log.ReadOnly = $true
$script:log.WordWrap = $false
$script:log.BackColor = GuiColor 22 31 39
$script:log.ForeColor = GuiColor 228 236 242
$script:log.Font = [Drawing.Font]::new('Consolas', 10)
$script:log.BorderStyle = 'None'

$script:promptPanel = New-Object Windows.Forms.Panel
$script:promptPanel.Dock = 'Bottom'
$script:promptPanel.Height = 120
$script:promptPanel.BackColor = GuiColor 235 243 240
$script:promptPanel.Visible = $false
$script:question = New-Object Windows.Forms.Label
$script:question.Text = 'Votre reponse :'
$script:question.SetBounds(15, 7, 790, 25)
$script:question.Anchor = 'Top,Left,Right'
$script:answer = New-Object Windows.Forms.TextBox
$script:answer.SetBounds(15, 42, 540, 29)
$script:answer.Anchor = 'Top,Left,Right'
$script:send = GuiButton 'Valider' 115
$script:send.SetBounds(570, 39, 115, 35)
$script:send.Anchor = 'Top,Right'
$script:yes = GuiButton 'Oui' 100
$script:yes.SetBounds(15, 39, 100, 35)
$script:no = GuiButton 'Non' 100
$script:no.SetBounds(125, 39, 100, 35)
$script:questionHelp = New-Object Windows.Forms.Label
$script:questionHelp.Text = 'Tu peux annuler en repondant N ou Q selon la question.'
$script:questionHelp.ForeColor = GuiColor 85 99 105
$script:questionHelp.SetBounds(15, 85, 780, 23)
$script:questionHelp.Anchor = 'Top,Left,Right'
$script:promptPanel.Controls.AddRange(@($script:question, $script:answer, $script:send, $script:yes, $script:no, $script:questionHelp))

$actions = New-Object Windows.Forms.Panel
$actions.Dock = 'Bottom'
$actions.Height = 53
$actions.BackColor = GuiColor 233 238 243
$script:back = GuiButton 'Retour aux outils' 165
$script:back.SetBounds(15, 9, 165, 35)
$script:stop = GuiButton 'Arret d urgence' 155
$script:stop.SetBounds(195, 9, 155, 35)
$script:stop.BackColor = GuiColor 153 67 48
$script:stop.Enabled = $false
$actions.Controls.AddRange(@($script:back, $script:stop))
$script:execution.Controls.AddRange(@($script:log, $script:promptPanel, $actions, $runHeader))

function Append-Log([string]$message, [bool]$isError = $false) {
    $script:log.SelectionStart = $script:log.TextLength
    $script:log.SelectionLength = 0
    $script:log.SelectionColor = if ($isError) { GuiColor 255 158 140 } else { GuiColor 228 236 242 }
    $script:log.AppendText($message + [Environment]::NewLine)
    $script:log.SelectionStart = $script:log.TextLength
    $script:log.ScrollToCaret()
}

function Update-Categories {
    foreach ($button in $script:categoryButtons) {
        if ($button.Tag -eq $script:category) {
            $button.BackColor = GuiColor 28 101 78
            $button.ForeColor = [Drawing.Color]::White
        } else {
            $button.BackColor = GuiColor 229 235 241
            $button.ForeColor = GuiColor 44 58 70
        }
    }
}

function Update-Tools {
    $query = $script:search.Text.Trim()
    $matches = @($script:tools | Where-Object {
        ($script:category -eq 'Tous' -or $_.Category -eq $script:category) -and
        (($_.Name + ' ' + $_.Details + ' ' + $_.File).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    $script:toolList.SuspendLayout()
    try {
        foreach ($control in @($script:toolList.Controls)) {
            $script:toolList.Controls.Remove($control)
            $control.Dispose()
        }
        foreach ($tool in $matches) {
            $card = New-Object Windows.Forms.Panel
            $card.Width = [Math]::Max(460, $script:toolList.ClientSize.Width - 42)
            $card.Height = 80
            $card.BackColor = [Drawing.Color]::White
            $card.BorderStyle = 'FixedSingle'
            $card.Margin = [Windows.Forms.Padding]::new(2, 2, 2, 8)
            $label = New-Object Windows.Forms.Label
            $label.Text = $tool.Name
            $label.Font = [Drawing.Font]::new('Segoe UI', 11, [Drawing.FontStyle]::Bold)
            $label.SetBounds(14, 10, $card.Width - 150, 27)
            $label.Anchor = 'Top,Left,Right'
            $details = New-Object Windows.Forms.Label
            $details.Text = $tool.Details
            $details.ForeColor = GuiColor 95 107 119
            $details.SetBounds(14, 43, $card.Width - 150, 24)
            $details.Anchor = 'Top,Left,Right'
            $launch = GuiButton 'Lancer' 94
            $launch.Tag = $tool.File
            $launch.SetBounds($card.Width - 111, 20, 94, 36)
            $launch.Anchor = 'Top,Right'
            $launch.Add_Click({ param($sender, $eventArgs) Start-Tool ([string]$sender.Tag) })
            $card.Controls.AddRange(@($label, $details, $launch))
            $script:toolList.Controls.Add($card)
        }
        if ($matches.Count -eq 0) {
            $empty = New-Object Windows.Forms.Label
            $empty.Text = 'Aucun outil ne correspond a la recherche.'
            $empty.AutoSize = $true
            $script:toolList.Controls.Add($empty)
        }
    }
    finally { $script:toolList.ResumeLayout() }
}

$script:process = $null
$script:running = $false
$script:stopRequested = $false
$script:promptActive = $false
$script:promptToken = '__SCRIPTS_PERSO_INPUT__:'

function Quote-ProcessArgument([string]$value) {
    return [ScriptsPerso.ProcessRunner]::QuoteArgument($value)
}

function Start-Tool([string]$file) {
    if ($script:running) { return }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        [Windows.Forms.MessageBox]::Show('Script introuvable : ' + $file, 'Erreur') | Out-Null
        return
    }

    while ($true) {
        [string]$discard = $null
        if (-not [ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$discard)) { break }
    }

    $tool = @($script:tools | Where-Object { $_.File -eq $file } | Select-Object -First 1)
    $script:runTitle.Text = if ($tool.Count -gt 0) { $tool[0].Name } else { [IO.Path]::GetFileName($file) }
    $script:runStatus.Text = 'Execution en cours...'
    $script:log.Clear()
    $script:promptPanel.Visible = $false
    $script:promptActive = $false
    $script:stopRequested = $false
    $script:back.Enabled = $false
    $script:stop.Enabled = $true
    $script:homePanel.Visible = $false
    $script:execution.Visible = $true
    $script:execution.BringToFront()
    Append-Log "Projet : $projectRoot"
    Append-Log "Script : $file"
    Append-Log ''

    try {
        $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $executable = Join-Path $PSHOME $engineName
        if ($file -eq (Join-Path $libraryRoot 'PowerShell\02-gerer-serveurs-locaux.ps1')) {
            # Ce gestionnaire doit survivre au retour dans le menu. Il possede
            # ses propres groupes de processus dans sa console independante.
            $arguments = '-NoProfile -File ' + (Quote-ProcessArgument $file) + ' -Project ' + (Quote-ProcessArgument $projectRoot)
            Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Normal -ErrorAction Stop
            $script:runStatus.Text = 'Gestionnaire ouvert dans une console dediee.'
            $script:back.Enabled = $true
            $script:stop.Enabled = $false
            Append-Log 'Les serveurs restent geres dans cette nouvelle console. Tu peux revenir aux autres outils.'
            return
        }
        $arguments = '-NoProfile -File ' + (Quote-ProcessArgument $runnerPath) + ' -Target ' + (Quote-ProcessArgument $file) + ' -Project ' + (Quote-ProcessArgument $projectRoot)
        if ($script:ideContextPath) { $arguments += ' -IdeContextPath ' + (Quote-ProcessArgument $script:ideContextPath) }
        $script:process = [ScriptsPerso.ProcessRunner]::Launch($executable, $arguments, $projectRoot)
        $script:running = $true
    }
    catch {
        Append-Log "ERREUR : $($_.Exception.Message)" $true
        $script:runStatus.Text = 'Echec du lancement'
        $script:back.Enabled = $true
        $script:stop.Enabled = $false
    }
}

function Submit-Answer([string]$answer) {
    if (-not $script:running -or -not $script:promptActive) { return }
    try {
        $script:process.StandardInput.WriteLine($answer)
        $script:process.StandardInput.Flush()
        $script:promptActive = $false
        $script:promptPanel.Visible = $false
        $script:runStatus.Text = 'Execution en cours...'
        Append-Log 'Reponse transmise.'
    }
    catch { Append-Log "Reponse impossible : $($_.Exception.Message)" $true }
}

$script:send.Add_Click({ Submit-Answer $script:answer.Text })
$script:yes.Add_Click({ Submit-Answer 'O' })
$script:no.Add_Click({ Submit-Answer 'N' })
$script:answer.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        $eventArgs.SuppressKeyPress = $true
        Submit-Answer $script:answer.Text
    }
})
$script:back.Add_Click({
    if ($script:running) { return }
    $script:execution.Visible = $false
    $script:homePanel.Visible = $true
    $script:homePanel.BringToFront()
})
$script:stop.Add_Click({
    if (-not $script:running) { return }
    $result = [Windows.Forms.MessageBox]::Show(
        'Interrompre de force ? Un git add, commit, pull ou push peut etre en cours. L etat Git devra etre verifie ensuite.',
        'Arret d urgence', [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [Windows.Forms.DialogResult]::Yes) {
        try {
            [ScriptsPerso.ProcessRunner]::Stop($script:process)
            $script:stopRequested = $true
            $script:runStatus.Text = 'Arret demande...'
        }
        catch { Append-Log $_.Exception.Message $true }
    }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 110
$timer.Add_Tick({
    if (-not $script:running) { return }
    for ($i = 0; $i -lt 600; $i++) {
        [string]$entry = $null
        if (-not [ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$entry)) { break }
        $payload = $entry.Substring(1)
        if ($entry.StartsWith('O') -and $payload.StartsWith($script:promptToken)) {
            try {
                $encoded = $payload.Substring($script:promptToken.Length)
                $prompt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
                Append-Log "QUESTION : $prompt"
                $script:question.Text = $prompt
                $script:answer.Clear()
                $yesNo = $prompt -match '(?i)\(\s*O\s*/\s*N\s*\)'
                $script:yes.Visible = $yesNo
                $script:no.Visible = $yesNo
                $script:answer.Visible = -not $yesNo
                $script:send.Visible = -not $yesNo
                $script:promptPanel.Visible = $true
                $script:promptActive = $true
                $script:runStatus.Text = 'En attente de votre reponse'
                if (-not $yesNo) { $script:answer.Focus() }
            }
            catch { Append-Log 'Question GUI illisible.' $true }
        }
        else {
            Append-Log $payload ($entry.StartsWith('E'))
        }
    }
    if ($script:process -and $script:process.HasExited) {
        # Ferme aussi les descendants avant d'attendre la fin des sorties.
        [ScriptsPerso.ProcessRunner]::Release($script:process)
        $script:process.WaitForExit()
        [string]$entry = $null
        while ([ScriptsPerso.ProcessRunner]::Messages.TryDequeue([ref]$entry)) {
            if ($entry.StartsWith('O') -and $entry.Substring(1).StartsWith($script:promptToken)) { continue }
            Append-Log $entry.Substring(1) ($entry.StartsWith('E'))
        }
        $exitCode = $script:process.ExitCode
        $script:running = $false
        $script:promptActive = $false
        $script:promptPanel.Visible = $false
        $script:stop.Enabled = $false
        $script:back.Enabled = $true
        $script:runStatus.Text = if ($script:stopRequested) { 'Interrompu : verifier l etat du projet.' } elseif ($exitCode -eq 0) { 'Termine (code 0)' } else { "Termine avec erreur (code $exitCode)" }
        Append-Log ''
        Append-Log $script:runStatus.Text ($exitCode -ne 0)
        $script:process.Dispose()
        $script:process = $null
    }
})

$script:form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:running) {
        [Windows.Forms.MessageBox]::Show(
            'Un script est en cours. Attendez sa fin ou utilisez Arret d urgence.',
            'Execution en cours', [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        $eventArgs.Cancel = $true
    }
})
$script:form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Escape -and -not $script:running) {
        if ($script:execution.Visible) {
            $script:execution.Visible = $false
            $script:homePanel.Visible = $true
            $script:homePanel.BringToFront()
        }
        else { $script:form.Close() }
    }
})
$script:search.Add_TextChanged({ Update-Tools })
$script:toolList.Add_Resize({
    foreach ($card in $script:toolList.Controls) {
        if ($card -is [Windows.Forms.Panel]) {
            $card.Width = [Math]::Max(460, $script:toolList.ClientSize.Width - 42)
        }
    }
})
$script:form.Controls.Add($container)
$script:form.Controls.Add($header)
Update-Categories
Update-Tools
$timer.Start()

if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
    # DrawToBitmap capture le rendu WinForms lui-même. La documentation reste
    # reproductible même lorsqu'aucun outil de capture d'écran n'est installé.
    $target = [IO.Path]::GetFullPath($ScreenshotPath)
    if ([IO.Path]::GetExtension($target) -ine '.png') {
        throw 'La capture du lanceur doit utiliser le format PNG.'
    }
    $targetDirectory = [IO.Path]::GetDirectoryName($target)
    if (-not [IO.Directory]::Exists($targetDirectory)) {
        [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
    }
    $script:form.Show()
    [Windows.Forms.Application]::DoEvents()
    $script:form.PerformLayout()
    $bitmap = New-Object Drawing.Bitmap $script:form.ClientSize.Width, $script:form.ClientSize.Height
    try {
        $script:form.DrawToBitmap($bitmap, $script:form.ClientRectangle)
        $bitmap.Save($target, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
        $script:form.Close()
    }
    return
}

try { [void]$script:form.ShowDialog() }
finally {
    $timer.Stop()
    $timer.Dispose()
    if ($script:process) {
        [ScriptsPerso.ProcessRunner]::Release($script:process)
        $script:process.Dispose()
    }
    $script:form.Dispose()
}
