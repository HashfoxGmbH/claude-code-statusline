#!/usr/bin/env node
/**
 * Claude Code Statusline (Windows): Modell + Context-Verbrauch + freie Tokens.
 *
 * Primaerquelle ist das stdin-Feld `context_window` (Claude Code v2.1.x+):
 *   - resume-fest (Live-Session-State, nicht Transcript-Raten),
 *   - limit-korrekt (200k vs. 1M exakt),
 *   - subagenten-frei (nur Haupt-Session-Context).
 *
 * Fallback fuer aeltere Versionen: letzte Assistant-Nachricht der Hauptkette
 * aus dem Transcript (isSidechain wird uebersprungen).
 *
 * Gegenstueck zu ~/.claude/statusline.py in WSL Ubuntu.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';
const CYAN = '\x1b[36m';

function fmtTokens(n) {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(Math.round(n));
}

function fmtLimit(n) {
  if (n >= 1_000_000) return Math.round(n / 1_000_000) + 'M';
  if (n >= 1000) return Math.round(n / 1000) + 'k';
  return String(Math.round(n));
}

function readTail(file, maxBytes) {
  // Nur das Dateiende lesen — Transcripts werden viele MB gross,
  // die Statusline laeuft alle paar hundert ms.
  const fd = fs.openSync(file, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - maxBytes);
    const buf = Buffer.alloc(size - start);
    const n = fs.readSync(fd, buf, 0, buf.length, start);
    return buf.toString('utf8', 0, n);
  } finally {
    fs.closeSync(fd);
  }
}

function fromTranscript(data) {
  let used = 0;
  const tpath = data.transcript_path;
  if (tpath && fs.existsSync(tpath)) {
    try {
      const lines = readTail(tpath, 512 * 1024).split('\n');
      for (const line of lines) {
        if (!line.includes('"usage"')) continue;
        let obj;
        try { obj = JSON.parse(line); } catch { continue; }
        if (obj.type !== 'assistant' || obj.isSidechain) continue;
        const u = obj.message && obj.message.usage;
        if (!u) continue;
        used = (u.input_tokens || 0)
          + (u.cache_read_input_tokens || 0)
          + (u.cache_creation_input_tokens || 0);
      }
    } catch { /* Statusline darf nie crashen */ }
  }
  return used;
}

function detectLimit(data, used) {
  // 1M-Session erkennen, wenn Claude Code kein context_window liefert
  // (aeltere Versionen / Resume-Edge-Cases). Sonst wuerde eine resumte
  // 1M-Session faelschlich als /200k angezeigt.
  if (used > 200_000) return 1_000_000;
  if (data.exceeds_200k_tokens) return 1_000_000;
  const model = data.model || {};
  const modelStr = `${model.id || ''} ${model.display_name || ''}`;
  if (/\[1m\]/i.test(modelStr)) return 1_000_000;
  try {
    const settingsPath = path.join(require('os').homedir(), '.claude', 'settings.json');
    const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    if (typeof settings.model === 'string' && /\[1m\]/i.test(settings.model)) {
      return 1_000_000;
    }
  } catch { /* Settings nicht lesbar -> konservativ 200k */ }
  return 200_000;
}

function gitBranch(cwd) {
  // .git/HEAD direkt lesen statt git zu spawnen (Statusline laeuft oft)
  try {
    let dir = cwd;
    for (let i = 0; i < 12 && dir; i++) {
      const gitPath = path.join(dir, '.git');
      if (fs.existsSync(gitPath)) {
        let headFile = path.join(gitPath, 'HEAD');
        const stat = fs.statSync(gitPath);
        if (stat.isFile()) { // Worktree: .git ist Datei "gitdir: <pfad>"
          const gitdir = fs.readFileSync(gitPath, 'utf8').replace(/^gitdir:\s*/, '').trim();
          headFile = path.join(path.isAbsolute(gitdir) ? gitdir : path.join(dir, gitdir), 'HEAD');
        }
        const head = fs.readFileSync(headFile, 'utf8').trim();
        const m = head.match(/^ref: refs\/heads\/(.+)$/);
        return m ? m[1] : head.slice(0, 7);
      }
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch { /* kein Git-Repo */ }
  return null;
}

function activeAgents(data) {
  // Laufende Subagenten: agent-*.jsonl unter <session>/subagents/, das in den
  // letzten 45s beschrieben wurde. Laufende Agenten appenden staendig an ihr
  // Transcript; fertige Dateien veralten sofort. Resume-fest, da der Pfad
  // direkt aus transcript_path abgeleitet wird.
  try {
    const tpath = data.transcript_path;
    if (!tpath) return 0;
    const dir = path.join(tpath.replace(/\.jsonl$/i, ''), 'subagents');
    if (!fs.existsSync(dir)) return 0;
    const now = Date.now();
    let count = 0;
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith('agent-') || !f.endsWith('.jsonl')) continue;
      const mtime = fs.statSync(path.join(dir, f)).mtimeMs;
      if (now - mtime < 45_000) count++;
    }
    return count;
  } catch {
    return 0;
  }
}

function fmtDuration(ms) {
  const min = Math.floor(ms / 60_000);
  if (min < 60) return min + 'm';
  return Math.floor(min / 60) + 'h' + String(min % 60).padStart(2, '0') + 'm';
}

function bar(pct, width) {
  // floor(x+0.5) statt Math.round: identisches Runden wie die Python-Variante
  const filled = Math.max(0, Math.min(width, Math.floor((pct / 100) * width + 0.5)));
  return '▰'.repeat(filled) + DIM + '▱'.repeat(width - filled);
}

function main() {
  let data = {};
  try {
    // BOM strippen — manche Shells (Windows PowerShell 5.1) pipen mit
    const raw = fs.readFileSync(0, 'utf8');
    data = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
  } catch {
    process.stdout.write('Claude\n');
    return;
  }

  try {
    render(data);
  } catch {
    // Kontrakt: niemals crashen, schlimmstenfalls nur der Name
    process.stdout.write('Claude\n');
  }
}

function render(data) {
  const model = data.model || {};
  const name = model.display_name || model.id || 'Claude';

  let used, limit, pct;
  const cw = data.context_window || {};
  if (cw.context_window_size) {
    limit = cw.context_window_size;
    used = cw.total_input_tokens;
    if (used == null) {
      const cu = cw.current_usage || {};
      used = (cu.input_tokens || 0)
        + (cu.cache_read_input_tokens || 0)
        + (cu.cache_creation_input_tokens || 0);
    }
    pct = cw.used_percentage != null ? cw.used_percentage : (limit ? used / limit * 100 : 0);
  } else {
    used = fromTranscript(data);
    limit = detectLimit(data, used);
    pct = limit ? used / limit * 100 : 0;
  }
  if (!Number.isFinite(pct)) pct = 0;
  pct = Math.max(0, pct);
  const free = Math.max(0, limit - used);

  const col = pct >= 90 ? RED : pct >= 70 ? YELLOW : GREEN;
  const sep = ` ${DIM}│${RESET} `;

  let ctxSeg = `${col}${fmtTokens(used)}${RESET}${DIM}/${fmtLimit(limit)}${RESET} ${DIM}·${RESET} free ${GREEN}${fmtTokens(free)}${RESET}`;
  if (pct >= 85) ctxSeg += ` ${RED}Compact bald!${RESET}`;

  const parts = [
    `${name}`,
    `${col}${bar(pct, 10)}${RESET} ${col}${pct.toFixed(0)}%${RESET}`,
    ctxSeg,
  ];

  const agents = activeAgents(data);
  if (agents > 0) {
    parts.push(`${CYAN}Agents: ${agents}${RESET}`);
  }

  const cost = data.cost || {};
  const costBits = [];
  if (cost.total_cost_usd > 0) costBits.push('$' + cost.total_cost_usd.toFixed(2));
  if (cost.total_lines_added || cost.total_lines_removed) {
    costBits.push(`${GREEN}+${cost.total_lines_added || 0}${RESET}${DIM}/${RESET}${RED}-${cost.total_lines_removed || 0}${RESET}${DIM} lines${RESET}`);
  }
  if (cost.total_duration_ms > 60_000) costBits.push(fmtDuration(cost.total_duration_ms) + ' runtime');
  if (costBits.length) parts.push(`${DIM}${costBits.join(' · ')}${RESET}`);

  const cwd = (data.workspace && data.workspace.current_dir) || data.cwd;
  if (cwd) {
    let loc = path.basename(cwd);
    const branch = gitBranch(cwd);
    if (branch) loc += ` ${CYAN}(${branch})${RESET}`;
    parts.push(loc);
  }

  process.stdout.write(parts.join(sep) + '\n');
}

main();