'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vscode = require('vscode');
const { isPathInside, isSensitivePath, relativeForDisplay, redactSensitiveText } = require('./context-utils');

const COMMAND = 'scriptsPerso.openToolsWithContext';
const MAX_DOCUMENT_CHARS = 60000;
const MAX_SELECTION_CHARS = 20000;
const TEMP_PREFIX = 'scripts-perso-vscode-';

async function removeQuietly(filePath) {
  try {
    await fs.unlink(filePath);
  } catch (error) {
    if (error && error.code !== 'ENOENT') console.warn(`Scripts-Perso: nettoyage impossible pour ${filePath}`);
  }
}

async function cleanStaleContexts() {
  const deadline = Date.now() - 24 * 60 * 60 * 1000;
  try {
    const entries = await fs.readdir(os.tmpdir(), { withFileTypes: true });
    await Promise.all(entries
      .filter((entry) => entry.isFile() && entry.name.startsWith(TEMP_PREFIX) && entry.name.endsWith('.json'))
      .map(async (entry) => {
        const candidate = path.join(os.tmpdir(), entry.name);
        const stat = await fs.stat(candidate);
        if (stat.mtimeMs < deadline) await removeQuietly(candidate);
      }));
  } catch (error) {
    console.warn('Scripts-Perso: nettoyage des anciens contextes ignore.');
  }
}

function chooseWorkspace(editor) {
  if (editor) {
    const owner = vscode.workspace.getWorkspaceFolder(editor.document.uri);
    if (owner) return owner;
  }
  return vscode.workspace.workspaceFolders?.[0];
}

function captureActiveFile(editor, workspaceRoot) {
  if (!editor) return null;
  const document = editor.document;
  if (document.uri.scheme !== 'file') {
    return { blockedReason: 'Le document actif n est pas un fichier local.' };
  }

  const filePath = document.uri.fsPath;
  const base = {
    path: filePath,
    relativePath: isPathInside(workspaceRoot, filePath) ? relativeForDisplay(workspaceRoot, filePath) : null,
    languageId: document.languageId,
    isDirty: document.isDirty,
    selectedText: '',
    content: '',
    contentScope: 'none',
    blockedReason: null,
  };

  if (!isPathInside(workspaceRoot, filePath)) {
    base.blockedReason = 'Le fichier actif est en dehors du projet.';
    return base;
  }
  if (isSensitivePath(filePath)) {
    base.blockedReason = 'Le fichier actif est considere comme sensible.';
    return base;
  }

  // Une sélection courte reste utile lorsque le document complet dépasse la
  // limite. Les deux chemins passent par le même filtre avant l'écriture.
  const selectedText = document.getText(editor.selection);
  if (selectedText && selectedText.length <= MAX_SELECTION_CHARS) base.selectedText = redactSensitiveText(selectedText);
  const documentText = document.getText();
  if (documentText.length <= MAX_DOCUMENT_CHARS) {
    base.content = redactSensitiveText(documentText);
    base.contentScope = 'document';
  } else if (base.selectedText) {
    base.content = base.selectedText;
    base.contentScope = 'selection';
    base.blockedReason = 'Le fichier complet est trop volumineux ; seule la selection est transmise.';
  } else {
    base.blockedReason = 'Le fichier actif est trop volumineux ; selectionne la partie utile.';
  }
  return base;
}

async function openTools(extensionContext) {
  const editor = vscode.window.activeTextEditor;
  const workspaceFolder = chooseWorkspace(editor);
  if (!workspaceFolder || workspaceFolder.uri.scheme !== 'file') {
    vscode.window.showErrorMessage('Scripts-Perso : ouvre d abord un dossier de projet local.');
    return;
  }

  const workspaceRoot = workspaceFolder.uri.fsPath;
  const activeFile = captureActiveFile(editor, workspaceRoot);
  const contextPayload = {
    version: 1,
    createdAt: new Date().toISOString(),
    workspaceRoot,
    activeFile,
  };
  const contextPath = path.join(os.tmpdir(), `${TEMP_PREFIX}${crypto.randomUUID()}.json`);
  await fs.writeFile(contextPath, JSON.stringify(contextPayload), { encoding: 'utf8', flag: 'wx', mode: 0o600 });

  let menuPath;
  try {
    // VS Code conserve le chemin de la jonction dans extensionPath : le chemin
    // reel permet de retrouver la racine Scripts-Perso de cette installation.
    const realExtensionPath = await fs.realpath(extensionContext.extensionPath);
    menuPath = path.resolve(realExtensionPath, '..', '..', 'PowerShell', 'menu-scripts.ps1');
    await fs.access(menuPath);
  } catch {
    await removeQuietly(contextPath);
    vscode.window.showErrorMessage(`Scripts-Perso : lanceur introuvable${menuPath ? ` (${menuPath})` : ''}.`);
    return;
  }

  const execution = new vscode.ProcessExecution(
    'powershell.exe',
    ['-NoProfile', '-File', menuPath, '-Project', workspaceRoot, '-IdeContextPath', contextPath],
    {
      cwd: workspaceRoot,
      env: {
        SCRIPTS_PERSO_OLLAMA_MODEL: String(
          vscode.workspace.getConfiguration('scriptsPerso', workspaceFolder.uri).get('ollamaModel', 'qwen2.5-coder:7b'),
        ).trim(),
      },
    },
  );
  const task = new vscode.Task(
    { type: 'scripts-perso-context', contextId: path.basename(contextPath) },
    workspaceFolder,
    'Perso - Ouvrir mes scripts avec contexte IDE',
    'Scripts-Perso',
    execution,
    [],
  );
  task.presentationOptions = {
    reveal: vscode.TaskRevealKind.Always,
    focus: false,
    panel: vscode.TaskPanelKind.Dedicated,
    clear: true,
  };

  let taskExecution;
  const endSubscription = vscode.tasks.onDidEndTaskProcess(async (event) => {
    if (taskExecution && event.execution === taskExecution) {
      endSubscription.dispose();
      await removeQuietly(contextPath);
    }
  });
  try {
    taskExecution = await vscode.tasks.executeTask(task);
  } catch (error) {
    endSubscription.dispose();
    await removeQuietly(contextPath);
    vscode.window.showErrorMessage(`Scripts-Perso : lancement impossible (${error.message}).`);
  }
}

function activate(context) {
  cleanStaleContexts();
  context.subscriptions.push(vscode.commands.registerCommand(COMMAND, () => openTools(context)));
}

function deactivate() {}

module.exports = { activate, deactivate };
