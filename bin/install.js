#!/usr/bin/env node
/**
 * npx installer for the Claude Code statusline:
 *   npx @hashfox/claude-code-statusline               install
 *   npx @hashfox/claude-code-statusline --uninstall   uninstall
 *
 * Copies statusline.js to ~/.claude/ and registers it in settings.json. Existing
 * settings are kept; the state before the first install is saved as
 * settings.json.bak. Anyone running npx has Node, so the Node variant is always used.
 * The settings logic mirrors the merge scripts embedded in install.ps1 / install.sh.
 */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const claudeDir = path.join(os.homedir(), '.claude');
const src = path.join(__dirname, '..', 'src', 'statusline.js');
const dest = path.join(claudeDir, 'statusline.js');
const settingsPath = path.join(claudeDir, 'settings.json');
const bakPath = settingsPath + '.bak';

function load(file) {
  let raw = fs.readFileSync(file, 'utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  return raw.trim() ? JSON.parse(raw) : {};
}

function ours(s) {
  // Is the registered statusLine one of this project's scripts?
  return !!(s && s.statusLine && typeof s.statusLine === 'object'
    && /[\\/]\.claude[\\/]statusline\.(js|py|ps1)\b/.test(String(s.statusLine.command)));
}

function loadSettings() {
  if (!fs.existsSync(settingsPath)) return {};
  let s;
  try { s = load(settingsPath); } catch (e) { throw new Error('settings.json is not valid JSON: ' + e.message); }
  if (!s || typeof s !== 'object' || Array.isArray(s)) throw new Error('settings.json is not a JSON object');
  return s;
}

function save(s) {
  fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n');
}

function install() {
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.copyFileSync(src, dest);

  // Forward slashes: on Windows Claude Code runs the command via Git Bash or
  // PowerShell; a path with / works in both.
  const cmd = 'node "' + dest.replace(/\\/g, '/') + '"';

  const settings = loadSettings();
  // Back up only a state WITHOUT this statusline: re-running the installer must
  // not overwrite the original backup with already-modified settings.
  if (fs.existsSync(settingsPath) && !ours(settings)) fs.copyFileSync(settingsPath, bakPath);
  settings.statusLine = { type: 'command', command: cmd, padding: 0 };
  save(settings);

  // Smoke test
  const { execFileSync } = require('child_process');
  const sample = '{"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"total_input_tokens":50000}}';
  const out = execFileSync(process.execPath, [dest], { input: sample, encoding: 'utf8' }).trim();
  if (!out) throw new Error('Smoke test failed: no output.');

  console.log('');
  console.log('Statusline installed: ' + dest);
  console.log('settings.json updated: ' + settingsPath + ' (backup: settings.json.bak)');
  console.log('Test output:  ' + out);
  console.log('Done. New Claude Code sessions show the statusline; running sessions after a restart.');
}

function uninstall() {
  const settings = loadSettings();
  if (!ours(settings)) {
    console.log('This statusline is not registered in settings.json - nothing to do.');
    return;
  }
  // Restore a statusLine the user had before installing, taken from the backup
  let prev = null;
  try {
    const b = load(bakPath);
    if (b && b.statusLine && !ours(b)) prev = b.statusLine;
  } catch (e) { /* no backup */ }
  if (prev) settings.statusLine = prev; else delete settings.statusLine;
  save(settings);
  for (const ext of ['js', 'py', 'ps1']) {
    try { fs.unlinkSync(path.join(claudeDir, 'statusline.' + ext)); } catch (e) { /* not present */ }
  }
  console.log(prev ? 'Restored your previous statusLine from settings.json.bak.' : 'Removed statusLine from settings.json.');
  console.log('Statusline uninstalled. Restart running Claude Code sessions to apply.');
}

const args = process.argv.slice(2);
const unknown = args.filter((a) => a !== '--uninstall');
try {
  if (unknown.length) throw new Error('Unknown option: ' + unknown.join(' '));
  if (args.includes('--uninstall')) uninstall(); else install();
} catch (e) {
  console.error((args.includes('--uninstall') ? 'Uninstall' : 'Installation') + ' failed: ' + e.message);
  process.exit(1);
}
