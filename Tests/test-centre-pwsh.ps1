# Cette suite d'integration utilise PowerShell 7. Le parcours 5.1 du lanceur
# reste couvert par test-lanceur.ps1 -Gui.
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Cette suite necessite PowerShell 7 : utilise pwsh.exe.'
}
# Verification du centre sur projets factices uniquement.
$ErrorActionPreference = 'Stop'
$checkTestRepo = [IO.Directory]::GetParent($PSScriptRoot).FullName
. (Join-Path $checkTestRepo 'PowerShell\03-centre-tests.ps1') -Project $checkTestRepo
$checkTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$checkTempRoot = Join-Path $checkTempParent ('scripts-perso-checks-' + [Guid]::NewGuid().ToString('N'))
$checkProject = Join-Path $checkTempRoot "Projet [1] avec l'apostrophe"
$checkTests = Join-Path $checkProject 'Tests'
[void][IO.Directory]::CreateDirectory($checkTests)

function Assert-CheckCentre([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Write-CheckFixture([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }
function Find-CheckFixture([object[]]$Checks, [string]$Id) {
    $matchesFound = @($Checks | Where-Object { $_.Id -eq $Id })
    Assert-CheckCentre ($matchesFound.Count -eq 1) ('Controle de test manquant : ' + $Id)
    return $matchesFound[0]
}

try {
    $manifest = Join-Path $checkProject 'package.json'
    Write-CheckFixture $manifest @'
{"scripts":{"lint":"node control.cjs ok","test":"node control.cjs ok","test:ci":"node control.cjs --watch=false","build":"node control.cjs fail","test:watch":"node control.cjs --watch","lint:fix":"node control.cjs --fix","lint:format":"prettier -w .","dev":"node control.cjs","prelint":"node forbidden.cjs"}}
'@
    Write-CheckFixture (Join-Path $checkProject 'control.cjs') @'
if (process.env.CI !== 'true') process.exit(12);
console.log('API_KEY=DEMO_PRIVATE_VALUE');
console.log('CONTROL_DONE');
process.exit(process.argv[2] === 'fail' ? 7 : 0);
'@
    Write-CheckFixture (Join-Path $checkProject 'forbidden.cjs') 'require("fs").writeFileSync("FORBIDDEN_HOOK", "demo");'
    Write-CheckFixture (Join-Path $checkTests 'test-ok.ps1') "Write-Host 'PS_CONTROL_OK'; exit 0"
    Write-CheckFixture (Join-Path $checkTests 'test-fail.ps1') 'exit 7'
    Write-CheckFixture (Join-Path $checkTests 'test-partial.ps1') "Write-Host 'NON VERIFIE : DEMO'; exit 0"
    Write-CheckFixture (Join-Path $checkTests 'test-slow.ps1') 'Start-Sleep -Seconds 20; exit 0'
    Write-CheckFixture (Join-Path $checkTests 'test_ok.py') @'
import unittest
class Demo(unittest.TestCase):
    def test_demo(self):
        self.assertEqual(2 + 2, 4)
'@
    $checks = @(Get-LocalCheckOptions $checkProject)
    Assert-CheckCentre (@($checks | Where-Object { $_.Kind -eq 'npm' }).Count -eq 7) 'Decouverte npm incorrecte ou script dev propose.'
    Assert-CheckCentre (@($checks | Where-Object { $_.Blocked }).Count -eq 3) 'Modes watch/fix/write non bloques.'
    Assert-CheckCentre (-not (Find-CheckFixture $checks 'npm:test:ci').Blocked) 'Le mode --watch=false est refuse.'
    Assert-CheckCentre (@($checks | Where-Object { $_.Kind -eq 'Python' }).Count -eq 1) 'Decouverte unittest incorrecte.'
    Assert-CheckCentre (@($checks | Where-Object { $_.Kind -eq 'PowerShell' }).Count -eq 4) 'Decouverte PowerShell incorrecte.'
    $selection = @(Get-LocalCheckSelection 'T' $checks)
    Assert-CheckCentre (@($selection | Where-Object { $_.Blocked }).Count -eq 0) 'Tout selectionne inclut un controle bloque.'
    $invalidRefused = $false
    try { $null = Get-LocalCheckSelection '1,999' $checks } catch { $invalidRefused = $true }
    Assert-CheckCentre $invalidRefused 'Selection partiellement invalide acceptee.'
    Write-Host 'OK : detection, exclusions watch/fix et validation de la selection.'

    $ok = Find-CheckFixture $checks 'ps:Tests/test-ok.ps1'
    $failed = Find-CheckFixture $checks 'ps:Tests/test-fail.ps1'
    $partial = Find-CheckFixture $checks 'ps:Tests/test-partial.ps1'
    $slow = Find-CheckFixture $checks 'ps:Tests/test-slow.ps1'
    $result = Invoke-LocalCheck $ok -Quiet
    Assert-CheckCentre ($result.Status -eq 'Reussi' -and $result.ExitCode -eq 0 -and $result.Tail -contains 'PS_CONTROL_OK') 'Commande PowerShell reussie mal rapportee.'
    $result = Invoke-LocalCheck $failed -Quiet
    Assert-CheckCentre ($result.Status -eq 'Echec' -and $result.ExitCode -eq 7) 'Echec PowerShell ignore.'
    $result = Invoke-LocalCheck $partial -Quiet
    Assert-CheckCentre ($result.Status -eq 'Partiel') 'Un controle non verifie est annonce reussi.'
    $result = Invoke-LocalCheck $slow -LimitSeconds 1 -Quiet
    Assert-CheckCentre ($result.Status -eq 'Echec' -and $result.Detail -like 'Delai*') 'Delai du controle non respecte.'
    Write-Host 'OK : reussite, echec, bilan partiel et delai PowerShell.'

    $report = Invoke-LocalCheckPlan -Checks @($ok, $failed) -SelectedIds @($ok.Id) -Quiet
    Assert-CheckCentre ($report.ExitCode -eq 0 -and $report.Results[1].Status -eq 'Non execute') 'Controle non selectionne mal rapporte.'
    $report = Invoke-LocalCheckPlan -Checks @($ok, $failed) -SelectedIds @($ok.Id, $failed.Id) -Quiet
    Assert-CheckCentre ($report.ExitCode -eq 1) 'Bilan global positif malgre un echec.'
    $report = Invoke-LocalCheckPlan -Checks @($partial) -SelectedIds @($partial.Id) -Quiet
    Assert-CheckCentre ($report.ExitCode -eq 2) 'Bilan partiel annonce totalement valide.'
    $report = Invoke-LocalCheckPlan -Checks @() -SelectedIds @() -Quiet
    Assert-CheckCentre ($report.ExitCode -eq 2) 'Projet sans controle annonce valide.'
    Write-Host 'OK : bilans selectionnes, non executes et projets sans controles.'

    $python = @($checks | Where-Object { $_.Kind -eq 'Python' })[0]
    $result = Invoke-LocalCheck $python -Quiet
    Assert-CheckCentre ($result.Status -eq 'Reussi' -and $result.ExitCode -eq 0) ('Unittest reel non reconnu : ' + $result.Status + ' / ' + $result.Detail)
    Write-CheckFixture (Join-Path $checkTests 'test_ok.py') 'def test_demo(): pass'
    $result = Invoke-LocalCheck $python -Quiet
    Assert-CheckCentre ($result.Status -eq 'Non execute') 'Aucun test Python annonce reussi.'
    Write-CheckFixture (Join-Path $checkTests 'test_ok.py') @'
import unittest
class Demo(unittest.TestCase):
    @unittest.skip('DEMO_SKIP')
    def test_demo(self):
        pass
'@
    $result = Invoke-LocalCheck $python -Quiet
    Assert-CheckCentre ($result.Status -eq 'Partiel') 'Tests Python ignores annonces totalement valides.'
    Write-Host 'OK : unittest reel, absence de tests et tests ignores.'

    if ((Find-LocalServerExecutable @('node.exe')) -and (Find-LocalServerExecutable @('npm.exe', 'npm.cmd'))) {
        $lint = Find-CheckFixture $checks 'npm:lint'
        $build = Find-CheckFixture $checks 'npm:build'
        $result = Invoke-LocalCheck $lint -Quiet
        Assert-CheckCentre ($result.Status -eq 'Reussi') 'Commande npm en mode CI non reussie.'
        Assert-CheckCentre (($result.Tail -join "`n") -notlike '*DEMO_PRIVATE_VALUE*') 'Sorties sensibles non masquees.'
        Assert-CheckCentre (-not (Test-Path -LiteralPath (Join-Path $checkProject 'FORBIDDEN_HOOK'))) 'Hook npm automatique execute.'
        $result = Invoke-LocalCheck $build -Quiet
        Assert-CheckCentre ($result.Status -eq 'Echec' -and $result.ExitCode -ne 0) 'Echec npm ignore.'
        Write-CheckFixture $manifest '{"scripts":{"lint":"node changed.cjs"}}'
        $result = Invoke-LocalCheck $lint -Quiet
        Assert-CheckCentre ($result.Status -eq 'Non execute' -and $result.Detail -like '*change*') 'Manifeste modifie execute.'
        Write-Host 'OK : npm CI, echec, hooks desactives, filtrage et manifeste modifie.'
    }
    else { Write-Host 'NON VERIFIE : Node/npm absents.' }

    $report = & {
        function Find-LocalServerExecutable { return $null }
        Invoke-LocalCheck $python -Quiet
    }
    Assert-CheckCentre ($report.Status -eq 'Non execute') 'Outil manquant non signale.'
    Write-Host 'OK : dependance manquante signalee sans installation.'
    Write-Host ('SUCCES - Centre de tests / PowerShell ' + $PSVersionTable.PSVersion)
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($checkTempRoot)
    if ([IO.Directory]::GetParent($resolvedRoot).FullName -ne $checkTempParent -or
        -not [IO.Path]::GetFileName($resolvedRoot).StartsWith('scripts-perso-checks-')) { throw 'Nettoyage hors du dossier de test refuse.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
