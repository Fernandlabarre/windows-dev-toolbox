'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const { isPathInside, isSensitivePath, relativeForDisplay, redactSensitiveText } = require('../context-utils');

test('un fichier enfant reste dans le projet', () => {
  const root = path.resolve('C:/demo/projet');
  assert.equal(isPathInside(root, path.join(root, 'server', 'account-store.ts')), true);
  assert.equal(isPathInside(root, path.resolve(root, '..', 'secret.txt')), false);
});

test('les chemins sensibles sont refuses', () => {
  assert.equal(isSensitivePath('C:/demo/.env.local'), true);
  assert.equal(isSensitivePath('C:/demo/certificat.pem'), true);
  assert.equal(isSensitivePath('C:/demo/.git/config'), true);
  assert.equal(isSensitivePath('C:/demo/server/account-store.ts'), false);
});

test('le chemin affiche est relatif et portable', () => {
  const root = path.resolve('C:/demo/projet');
  assert.equal(relativeForDisplay(root, path.join(root, 'server', 'account-store.ts')), 'server/account-store.ts');
});

test('les secrets reconnaissables sont masques avant le fichier temporaire', () => {
  const safe = redactSensitiveText('const apiKey = "DEMO_PRIVATE";\nconst ordinary = 42;\nAuthorization: Bearer abc.def-ghi');
  assert.ok(!safe.includes('DEMO_PRIVATE'));
  assert.ok(!safe.includes('abc.def-ghi'));
  assert.ok(safe.includes('const ordinary = 42;'));
});
