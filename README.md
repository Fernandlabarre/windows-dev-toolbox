# Scripts-Perso — boîte à outils Windows

[![CI Windows](https://github.com/Fernandlabarre/windows-dev-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/Fernandlabarre/windows-dev-toolbox/actions/workflows/ci.yml)
[![Version](https://img.shields.io/github/v/release/Fernandlabarre/windows-dev-toolbox?display_name=tag&sort=semver)](https://github.com/Fernandlabarre/windows-dev-toolbox/releases/latest)

J'ai regroupé ici les outils que j'utilise le plus souvent autour d'un projet
Windows : vérifier Git, préparer un commit, lancer un serveur local, exécuter
les tests et analyser un dossier.

Le point d'entrée est un lanceur WinForms. Il garde le bon dossier de travail,
affiche les résultats au même endroit et demande une confirmation avant les
actions qui modifient un dépôt ou exécutent du code.

![Lanceur Scripts-Perso sur un projet de démonstration](docs/images/launcher.png)

## Ce que fait le projet

| Partie | Utilité |
| --- | --- |
| Lanceur Windows | Découvre les outils et centralise leurs sorties dans une seule fenêtre. |
| Git | Affiche l'état du dépôt, aide à préparer un commit et synchronise une branche sans force push. |
| Développement local | Lance un script npm ou sert un dossier public sur `127.0.0.1`. |
| Tests | Détecte les contrôles Python, PowerShell et npm, puis affiche un bilan. |
| Analyse du projet | Mesure l'espace utilisé et crée un export filtré, sans envoi automatique. |
| VS Code et Ollama | Transmet, si besoin, le contexte de l'éditeur à un modèle installé localement. |

## Points techniques

- PowerShell 5.1 et 7, avec une interface WinForms.
- Petit composant C# chargé de placer chaque outil dans un Job Object Windows :
  l'arrêt du lanceur ferme aussi ses processus descendants.
- Scripts Python basés uniquement sur la bibliothèque standard.
- Extension VS Code locale pour ouvrir le lanceur sur le fichier actif.
- Gestion explicite de l'UTF-8, des chemins avec espaces et des réponses
  interactives.
- Exclusion ou masquage des fichiers et valeurs sensibles connus.

## Installation et lancement

Le projet est portable : il n'y a pas d'installateur et aucun droit
administrateur n'est nécessaire pour l'installation. Il suffit de cloner le
dépôt une fois dans le dossier de son choix.

Prérequis : Windows, Git et Windows PowerShell 5.1 ou PowerShell 7. Python 3.9
ou plus récent est nécessaire pour les outils d'export et d'analyse ; Ollama
reste facultatif.

### 1. Récupérer la boîte à outils

```powershell
git clone https://github.com/Fernandlabarre/windows-dev-toolbox.git
Set-Location -LiteralPath '.\windows-dev-toolbox'
```

### 2. Ouvrir le lanceur sur un projet

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\PowerShell\menu-scripts.ps1" `
  -Project "C:\chemin\vers\mon-projet"
```

Le chemin donné à `-Project` est celui du projet sur lequel travailler, pas
celui de la boîte à outils. Avec PowerShell 7, remplace `powershell.exe` par
`pwsh.exe`. L'option `-ExecutionPolicy Bypass` vaut uniquement pour ce
lancement et ne change pas la configuration de Windows.

Le projet actif est toujours affiché en haut de la fenêtre. Chaque script peut
aussi être lancé directement depuis un terminal.

### 3. Mettre la boîte à outils à jour

```powershell
Set-Location -LiteralPath 'C:\chemin\vers\windows-dev-toolbox'
git pull --ff-only
```

Pour retirer la boîte à outils, il suffit de supprimer son dossier.

## Organisation

```text
Git/          outils de vérification, commit et synchronisation
PowerShell/   lanceur, diagnostic, serveurs locaux, tests et Ollama
Python/       export, serveur local limité et analyse d'espace
VSCode/       extension de contexte pour l'éditeur
Tests/        scénarios sur projets, dépôts et services factices
docs/         guide complet et architecture technique
```

## Qualité et sécurité

La CI exécute les tests sous Python 3.9 et 3.14, Node.js 24, Windows
PowerShell 5.1 et PowerShell 7. Les scénarios utilisent des fichiers, dépôts et
services factices : aucun projet personnel n'est nécessaire pour les lancer.

Les outils n'installent pas de dépendance dans les projets analysés. Les
serveurs Python écoutent uniquement sur la boucle locale et l'exportateur
n'effectue aucun envoi réseau. Le filtrage de secrets reste une protection
complémentaire : tout export doit être relu avant d'être partagé.

## Aller plus loin

- [Guide d'utilisation complet](docs/GUIDE-UTILISATION.md)
- [Architecture technique](docs/ARCHITECTURE.md)
- [Historique des versions](CHANGELOG.md)
- [Politique de sécurité](SECURITY.md)
- [Version publiée](https://github.com/Fernandlabarre/windows-dev-toolbox/releases/latest)

Ce projet est conçu pour Windows et pour un usage local. Le code est visible
pour consultation et présentation ; sa réutilisation nécessite un accord
préalable, conformément à la [licence](LICENSE).
