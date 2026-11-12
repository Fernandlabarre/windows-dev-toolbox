'use strict';

const path = require('node:path');

const BLOCKED_BASENAMES = [
  /^\.env(?:\..*)?$/i,
  /^id_(?:rsa|dsa|ecdsa|ed25519)(?:\..*)?$/i,
  /^(?:credentials|secrets?|service-account)(?:\..*)?\.json$/i,
];

const BLOCKED_EXTENSIONS = new Set([
  '.key', '.pem', '.p12', '.pfx', '.jks', '.kdbx', '.keystore',
]);

function isPathInside(root, candidate) {
  // path.relative évite les faux positifs de préfixe comme projet/projet-copie.
  const resolvedRoot = path.resolve(root);
  const resolvedCandidate = path.resolve(candidate);
  const relative = path.relative(resolvedRoot, resolvedCandidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function isSensitivePath(filePath) {
  const basename = path.basename(filePath);
  if (BLOCKED_BASENAMES.some((pattern) => pattern.test(basename))) return true;
  if (BLOCKED_EXTENSIONS.has(path.extname(basename).toLowerCase())) return true;
  return filePath.split(/[\\/]+/).some((segment) => segment.toLowerCase() === '.git');
}

function relativeForDisplay(root, candidate) {
  return path.relative(path.resolve(root), path.resolve(candidate)).split(path.sep).join('/');
}

function redactSensitiveText(text) {
  // Les blocs de clés sont retirés avant les motifs ligne par ligne pour ne
  // jamais conserver le corps d'une clé multi-ligne dans le contexte temporaire.
  let safe = String(text).replace(/\r\n?/g, '\n');
  safe = safe.replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/gi, '[CLE PRIVEE MASQUEE]');
  safe = safe.replace(/\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b/gi, '[JETON MASQUE]');
  safe = safe.replace(/\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, '[JETON MASQUE]');
  safe = safe.replace(/\b(Bearer|Basic)\s+[A-Za-z0-9+/=._-]+/gi, '$1 [MASQUE]');
  safe = safe.replace(/\b((?:https?|postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis):\/\/)[^/\s@]+@/gi, '$1[IDENTIFIANTS MASQUES]@');
  safe = safe.replace(/([?&](?:token|access_token|api_key|password|secret|key)=)[^&#\s"'`]+/gi, '$1[MASQUE]');
  safe = safe.replace(/^(\s*(?:(?:const|let|var)\s+)?["']?[A-Za-z0-9_]*(?:password|passwd|api[_-]?key|access[_-]?token|client[_-]?secret|authorization|token|secret)[A-Za-z0-9_]*["']?\s*[:=]\s*).*$/gim, '$1[MASQUE]');
  return safe;
}

module.exports = { isPathInside, isSensitivePath, relativeForDisplay, redactSensitiveText };
