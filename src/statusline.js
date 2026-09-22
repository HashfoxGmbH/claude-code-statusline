#!/usr/bin/env node
/**
 * Claude Code statusline (Node variant): model + thinking mode, context usage,
 * free tokens, rate limits, running subagents, cost, folder + git branch.
 *
 * The primary source is the stdin field `context_window` (Claude Code v2.1.x+):
 *   - resume-safe (live session state, not guessed from the transcript),
 *   - limit-correct (200k vs. 1M exactly),
 *   - subagent-free (main session context only).
 *
 * Fallback for older versions: the last assistant message of the main chain
 * from the transcript (isSidechain entries are skipped).
 *
 * Behaviorally identical to statusline.py and statusline.ps1.
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

function fixed(x, digits, unit = 1) {
  // x/unit with `digits` decimals, halves rounded up. Round to an integer first
  // (floor(v + 0.5)), then build the string by hand: Python and .NET formatting
  // round halves to even, so this is what keeps all three variants identical.
  const v = Math.max(0, Math.floor((x * 10 ** digits + unit / 2) / unit));
  const s = String(v).padStart(digits + 1, '0');
  return digits ? s.slice(0, -digits) + '.' + s.slice(-digits) : s;
}

function fmtTokens(n) {
  // Thresholds after rounding: 999950 is "1.0M", not "1000.0k"
  if (n >= 999_950) return fixed(n, 1, 1_000_000) + 'M';
  if (n >= 999.5) return fixed(n, 1, 1000) + 'k';
  return fixed(n, 0);
}

function fmtLimit(n) {
  if (n >= 999_500) return fixed(n, 0, 1_000_000) + 'M';
  if (n >= 999.5) return fixed(n, 0, 1000) + 'k';
  return fixed(n, 0);
}

function readTail(file, maxBytes) {
  // Read only the end of the file - transcripts grow to many MB and the
  // statusline runs every few hundred ms.
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
    } catch { /* the statusline must never crash */ }
  }
  return used;
}

function detectLimit(data, used) {
  // Detect a 1M session when Claude Code sends no context_window (older
  // versions / resume edge cases). Otherwise a resumed 1M session would
  // wrongly show /200k.
  if (used > 200_000) return 1_000_000;
  if (data.exceeds_200k_tokens) return 1_000_000;
  const model = data.model || {};
  const modelStr = `${model.id || ''} ${model.display_name || ''}`;
  if (/\[1m\]/i.test(modelStr)) return 1_000_000;
  try {
    const settingsPath = path.join(require('os').homedir(), '.claude', 'settings.json');
    const rawSettings = fs.readFileSync(settingsPath, 'utf8');
    const settings = JSON.parse(rawSettings.charCodeAt(0) === 0xFEFF ? rawSettings.slice(1) : rawSettings);
    if (typeof settings.model === 'string' && /\[1m\]/i.test(settings.model)) {
      return 1_000_000;
    }
  } catch { /* settings unreadable -> conservatively 200k */ }
  return 200_000;
}

function gitBranch(cwd) {
  // Read .git/HEAD directly instead of spawning git (the statusline runs often)
  try {
    let dir = cwd;
    for (let i = 0; i < 12 && dir; i++) {
      const gitPath = path.join(dir, '.git');
      if (fs.existsSync(gitPath)) {
        let headFile = path.join(gitPath, 'HEAD');
        const stat = fs.statSync(gitPath);
        if (stat.isFile()) { // worktree: .git is a file "gitdir: <path>"
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
  } catch { /* not a git repo */ }
  return null;
}

function waitingOnTool(file) {
  // Last message entry of a subagent transcript: assistant with tool_use =
  // waiting for a tool (e.g. a long build), user with tool_result = the model
  // is working on the next step. Either way nothing is written to the
  // transcript until it finishes, but the agent is still running.
  const lines = readTail(file, 64 * 1024).split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes('"type"')) continue;
    let obj;
    try { obj = JSON.parse(lines[i]); } catch { continue; }
    if (obj.type !== 'assistant' && obj.type !== 'user') continue;
    const content = obj.message && obj.message.content;
    if (!Array.isArray(content)) return false;
    const want = obj.type === 'assistant' ? 'tool_use' : 'tool_result';
    return content.some((c) => c && c.type === want);
  }
  return false;
}

function activeAgents(data) {
  // Running subagents: agent-*.jsonl under <session>/subagents/. Active means
  // written within the last 45s (running agents append constantly), or at
  // most 10 min old and currently waiting on a tool or the next model reply
  // (10 min = the maximum Bash timeout). Resume-safe, because the path is
  // derived directly from transcript_path.
  try {
    const tpath = data.transcript_path;
    if (!tpath) return 0;
    const dir = path.join(tpath.replace(/\.jsonl$/i, ''), 'subagents');
    if (!fs.existsSync(dir)) return 0;
    const now = Date.now();
    let count = 0;
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith('agent-') || !f.endsWith('.jsonl')) continue;
      const file = path.join(dir, f);
      const age = now - fs.statSync(file).mtimeMs;
      if (age < 45_000) count++;
      else if (age < 600_000) {
        try { if (waitingOnTool(file)) count++; } catch { /* file gone */ }
      }
    }
    return count;
  } catch {
    return 0;
  }
}

function fmtReset(sec) {
  // Time until a limit resets: 2d4h / 1h05m / 12m
  const min = Math.max(0, Math.floor(sec / 60));
  if (min >= 1440) return Math.floor(min / 1440) + 'd' + Math.floor((min % 1440) / 60) + 'h';
  if (min >= 60) return Math.floor(min / 60) + 'h' + String(min % 60).padStart(2, '0') + 'm';
  return min + 'm';
}

function rateLimits(data) {
  // Rate limits (Pro/Max, or a gateway spend limit): "5h 23% . 7d 41%".
  // From 70 % on with the time until reset. Missing windows are skipped.
  const rl = data.rate_limits;
  if (!rl || typeof rl !== 'object') return '';
  const now = Date.now() / 1000;
  const bits = [];
  for (const [key, label] of [['five_hour', '5h'], ['seven_day', '7d'], ['spend_limit', 'spend']]) {
    const w = rl[key];
    if (!w || typeof w.used_percentage !== 'number' || !Number.isFinite(w.used_percentage)) continue;
    const pct = Math.max(0, w.used_percentage);
    const col = pct >= 90 ? RED : pct >= 70 ? YELLOW : GREEN;
    let bit = `${DIM}${label}${RESET} ${col}${fixed(pct, 0)}%${RESET}`;
    if (pct >= 70 && typeof w.resets_at === 'number' && w.resets_at > now) {
      bit += ` ${DIM}(${fmtReset(w.resets_at - now)})${RESET}`;
    }
    bits.push(bit);
  }
  return bits.join(` ${DIM}\u00B7${RESET} `);
}

function fmtDuration(ms) {
  const min = Math.floor(ms / 60_000);
  if (min < 60) return min + 'm';
  return Math.floor(min / 60) + 'h' + String(min % 60).padStart(2, '0') + 'm';
}

function bar(pct, width) {
  // floor(x+0.5): rounds exactly like the Python and PowerShell variants
  const filled = Math.max(0, Math.min(width, Math.floor((pct / 100) * width + 0.5)));
  return '\u25B0'.repeat(filled) + DIM + '\u25B1'.repeat(width - filled);
}

function main() {
  let data = {};
  try {
    // Strip a BOM - some shells (Windows PowerShell 5.1) pipe one along
    const raw = fs.readFileSync(0, 'utf8');
    data = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('not a JSON object');
  } catch {
    process.stdout.write('Claude\n');
    return;
  }

  try {
    render(data);
  } catch {
    // Contract: never crash; worst case, show just the name
    process.stdout.write('Claude\n');
  }
}

function modeSuffix(data) {
  // Thinking mode: effort.level (absent for models without an effort
  // parameter), thinking.enabled (only "off" is shown), fast_mode.
  let out = '';
  const effort = data.effort;
  if (effort && typeof effort.level === 'string' && effort.level) {
    out += ` ${DIM}\u00B7${RESET} ${effort.level}`;
  }
  const thinking = data.thinking;
  if (thinking && thinking.enabled === false) out += ` ${DIM}\u00B7 thinking off${RESET}`;
  if (data.fast_mode === true) out += ` ${YELLOW}\u26A1${RESET}`;
  return out;
}

function render(data) {
  const model = data.model || {};
  let name = model.display_name || model.id || 'Claude';
  try { name += modeSuffix(data); } catch (e) { /* name only */ }

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
  const sep = ` ${DIM}\u2502${RESET} `;

  let ctxSeg = `${col}${fmtTokens(used)}${RESET}${DIM}/${fmtLimit(limit)}${RESET} ${DIM}\u00B7${RESET} free ${GREEN}${fmtTokens(free)}${RESET}`;
  if (pct >= 85) ctxSeg += ` ${RED}compact soon${RESET}`;

  const parts = [
    `${name}`,
    `${col}${bar(pct, 10)}${RESET} ${col}${fixed(pct, 0)}%${RESET}`,
    ctxSeg,
  ];

  const limits = rateLimits(data);
  if (limits) parts.push(limits);

  const agents = activeAgents(data);
  if (agents > 0) {
    parts.push(`${CYAN}Agents: ${agents}${RESET}`);
  }

  const cost = data.cost || {};
  const costBits = [];
  if (cost.total_cost_usd > 0) costBits.push('$' + fixed(cost.total_cost_usd, 2));
  if (cost.total_lines_added || cost.total_lines_removed) {
    costBits.push(`${GREEN}+${cost.total_lines_added || 0}${RESET}${DIM}/${RESET}${RED}-${cost.total_lines_removed || 0}${RESET}${DIM} lines${RESET}`);
  }
  if (cost.total_duration_ms > 60_000) costBits.push(fmtDuration(cost.total_duration_ms) + ' runtime');
  if (costBits.length) parts.push(`${DIM}${costBits.join(' \u00B7 ')}${RESET}`);

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