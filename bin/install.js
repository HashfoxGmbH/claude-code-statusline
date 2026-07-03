#!/usr/bin/env node
/**
 * Installer fuer die Claude-Code-Statusline via npx:
 *   npx claude-code-statusline
 *
 * Kopiert statusline.js nach ~/.claude/ und traegt sie in settings.json ein
 * (bestehende Einstellungen bleiben erhalten, Backup als settings.json.bak).
 * Wer npx nutzt, hat Node — daher wird immer die Node-Variante installiert.
 */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const claudeDir = path.join(os.homedir(), '.claude');
const src = path.join(__dirname, '..', 'src', 'statusline.js');
const dest = path.join(claudeDir, 'statusline.js');
const settingsPath = path.join(claudeDir, 'settings.json');

try {
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.copyFileSync(src, dest);

  // Forward-Slashes: Claude Code fuehrt den Befehl unter Windows via
  // Git Bash oder PowerShell aus; mit / funktioniert der Pfad in beiden.
  const cmd = 'node "' + dest.replace(/\\/g, '/') + '"';

  let settings = {};
  if (fs.existsSync(settingsPath)) {
    const raw = fs.readFileSync(settingsPath, 'utf8');
    settings = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
    fs.copyFileSync(settingsPath, settingsPath + '.bak');
  }
  settings.statusLine = { type: 'command', command: cmd, padding: 0 };
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');

  // Smoke-Test
  const { execFileSync } = require('child_process');
  const sample = '{"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"total_input_tokens":50000}}';
  const out = execFileSync(process.execPath, [dest], { input: sample, encoding: 'utf8' }).trim();
  if (!out) throw new Error('Smoke-Test fehlgeschlagen: keine Ausgabe.');

  console.log('');
  console.log('Statusline installiert: ' + dest);
  console.log('settings.json aktualisiert: ' + settingsPath + ' (Backup: settings.json.bak)');
  console.log('Testausgabe:  ' + out);
  console.log('Fertig. Neue Claude-Code-Sessions zeigen die Statusline an; laufende nach Neustart der Session.');
} catch (e) {
  console.error('Installation fehlgeschlagen: ' + e.message);
  process.exit(1);
}
