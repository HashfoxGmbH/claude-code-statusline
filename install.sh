#!/usr/bin/env bash
# Claude Code Statusline - installer (Linux / WSL / macOS)
# Shows model, thinking mode, context usage (%, bar, free), rate limits, running
# subagents, cost, lines and runtime below the input line of every Claude Code session.
#
# Install:    curl -fsSL https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.sh | bash
#   or:       bash install.sh
# Uninstall:  curl -fsSL https://raw.githubusercontent.com/HashfoxGmbH/claude-code-statusline/main/install.sh | bash -s -- --uninstall
#   or:       bash install.sh --uninstall
set -euo pipefail

UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
[ "${CLAUDE_STATUSLINE_UNINSTALL:-}" = "1" ] && UNINSTALL=1

CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

# Check that the runtime actually runs (e.g. the macOS /usr/bin/python3 stub
# without Command Line Tools exists but fails) and is recent enough.
have_python() {
    command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' >/dev/null 2>&1
}
have_node() {
    command -v node >/dev/null 2>&1 \
        && node -e 'process.exit(parseInt(process.versions.node) >= 12 ? 0 : 1)' >/dev/null 2>&1
}

if have_python; then
    RUNTIME=python3
elif have_node; then
    RUNTIME=node
else
    echo "Neither python3 (>= 3.6) nor node (>= 12) found - please install one of them." >&2
    exit 1
fi

CMD=""
merge() {
    # $1 = install | uninstall. Exit codes: 0 = ok, 1 = error, 3 = nothing of ours registered.
    if [ "$RUNTIME" = "python3" ]; then
        CLAUDE_STATUSLINE_MODE="$1" CLAUDE_STATUSLINE_CMD="$CMD" CLAUDE_STATUSLINE_SETTINGS="$CLAUDE_DIR/settings.json" python3 - <<'MERGE_EOF'
# Merge settings.json. Mode, command and settings path come in via environment variables.
# Exit codes: 0 = ok, 1 = error, 3 = uninstall: no statusline of ours registered.
import json, os, re, shutil, sys
p = os.environ.get('CLAUDE_STATUSLINE_SETTINGS') or os.path.expanduser('~/.claude/settings.json')
bak = p + '.bak'
mode = os.environ.get('CLAUDE_STATUSLINE_MODE')
cmd = os.environ.get('CLAUDE_STATUSLINE_CMD')

def load(f):
    with open(f, encoding='utf-8-sig') as fh:
        raw = fh.read()
    return json.loads(raw) if raw.strip() else {}

def ours(s):
    sl = s.get('statusLine') if isinstance(s, dict) else None
    return isinstance(sl, dict) and re.search(r'[\\/]\.claude[\\/]statusline\.(js|py|ps1)\b', str(sl.get('command'))) is not None

def save(s):
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
        f.write('\n')

s = {}
if os.path.exists(p):
    try:
        s = load(p)
        if not isinstance(s, dict):
            raise ValueError('not a JSON object')
    except Exception as e:
        print('settings.json is not valid JSON: %s' % e, file=sys.stderr)
        sys.exit(1)
if mode == 'uninstall':
    if not ours(s):
        sys.exit(3)
    # Restore a statusLine the user had before installing, taken from the backup
    prev = None
    try:
        b = load(bak)
        if isinstance(b, dict) and b.get('statusLine') and not ours(b):
            prev = b['statusLine']
    except Exception:
        pass
    if prev:
        s['statusLine'] = prev
    else:
        s.pop('statusLine', None)
    save(s)
    print('Restored your previous statusLine from settings.json.bak.' if prev else 'Removed statusLine from settings.json.')
else:
    # Back up only a state WITHOUT this statusline: re-running the installer must not
    # overwrite the original backup with already-modified settings.
    if os.path.exists(p) and not ours(s):
        shutil.copy(p, bak)
    s['statusLine'] = {'type': 'command', 'command': cmd, 'padding': 0}
    save(s)
MERGE_EOF
    else
        CLAUDE_STATUSLINE_MODE="$1" CLAUDE_STATUSLINE_CMD="$CMD" CLAUDE_STATUSLINE_SETTINGS="$CLAUDE_DIR/settings.json" node - <<'MERGE_EOF'
// Merge settings.json. Mode, command and settings path come in via environment
// variables because Windows PowerShell 5.1 strips double quotes from arguments
// passed to node.
// Exit codes: 0 = ok, 1 = error, 3 = uninstall: no statusline of ours registered.
const fs = require('fs'), os = require('os'), path = require('path');
const p = process.env.CLAUDE_STATUSLINE_SETTINGS || path.join(os.homedir(), '.claude', 'settings.json');
const bak = p + '.bak';
const mode = process.env.CLAUDE_STATUSLINE_MODE;
const cmd = process.env.CLAUDE_STATUSLINE_CMD;
const load = (f) => {
  let raw = fs.readFileSync(f, 'utf8');
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
  return raw.trim() ? JSON.parse(raw) : {};
};
const ours = (s) => !!(s && s.statusLine && typeof s.statusLine === 'object'
  && /[\\/]\.claude[\\/]statusline\.(js|py|ps1)\b/.test(String(s.statusLine.command)));
const save = (s) => fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
let s = {};
if (fs.existsSync(p)) {
  try {
    s = load(p);
    if (!s || typeof s !== 'object' || Array.isArray(s)) throw new Error('not a JSON object');
  } catch (e) { console.error('settings.json is not valid JSON: ' + e.message); process.exit(1); }
}
if (mode === 'uninstall') {
  if (!ours(s)) process.exit(3);
  // Restore a statusLine the user had before installing, taken from the backup
  let prev = null;
  try { const b = load(bak); if (b && b.statusLine && !ours(b)) prev = b.statusLine; } catch (e) { /* no backup */ }
  if (prev) s.statusLine = prev; else delete s.statusLine;
  save(s);
  console.log(prev ? 'Restored your previous statusLine from settings.json.bak.' : 'Removed statusLine from settings.json.');
} else {
  // Back up only a state WITHOUT this statusline: re-running the installer must not
  // overwrite the original backup with already-modified settings.
  if (fs.existsSync(p) && !ours(s)) fs.copyFileSync(p, bak);
  s.statusLine = { type: 'command', command: cmd, padding: 0 };
  save(s);
}
MERGE_EOF
    fi
}

if [ "$UNINSTALL" = "1" ]; then
    rc=0
    merge uninstall || rc=$?
    if [ "$rc" = "3" ]; then
        echo "This statusline is not registered in settings.json - nothing to do."
        exit 0
    fi
    [ "$rc" = "0" ] || { echo "Could not update settings.json." >&2; exit 1; }
    rm -f "$CLAUDE_DIR/statusline.py" "$CLAUDE_DIR/statusline.js" "$CLAUDE_DIR/statusline.ps1"
    echo "Statusline uninstalled. Restart running Claude Code sessions to apply."
    exit 0
fi

cat > "$CLAUDE_DIR/statusline.py" <<'STATUSLINE_PY_EOF'
#!/usr/bin/env python3
"""Claude Code statusline (Python variant): model + thinking mode, context
usage, free tokens, rate limits, running subagents, cost, folder + git branch.

The primary source is the stdin field `context_window` sent by Claude Code
(v2.1.x+). It is:
  - resume-safe (the value comes from the live session state, not the transcript),
  - limit-correct (context_window_size knows 200k vs. 1M exactly),
  - subagent-free (only the main session context is counted).

Fallback (older Claude Code versions without context_window): the last
assistant message of the main chain from the transcript, subagents
(isSidechain == true) skipped.

Behaviorally identical to statusline.js and statusline.ps1.
"""
import sys, json, os, math

RESET, DIM = "\033[0m", "\033[2m"
GREEN, YELLOW, RED, CYAN = "\033[32m", "\033[33m", "\033[31m", "\033[36m"


def fixed(x, digits, unit=1):
    """x/unit with `digits` decimals, halves rounded up.

    Round to an integer first (floor(v + 0.5)), then build the string by hand:
    Python and .NET format rounding sends halves to the even number
    (0.5 -> "0", 1.25 -> "1.2"), JS toFixed does not. This keeps all three
    variants identical."""
    v = max(0, int(math.floor((x * 10 ** digits + unit / 2) / unit)))
    s = str(v).zfill(digits + 1)
    return s[:-digits] + "." + s[-digits:] if digits else s


def fmt_tokens(n):
    # Thresholds after rounding: 999950 is "1.0M", not "1000.0k"
    if n >= 999_950:
        return fixed(n, 1, 1_000_000) + "M"
    if n >= 999.5:
        return fixed(n, 1, 1000) + "k"
    return fixed(n, 0)


def fmt_limit(n):
    if n >= 999_500:
        return fixed(n, 0, 1_000_000) + "M"
    if n >= 999.5:
        return fixed(n, 0, 1000) + "k"
    return fixed(n, 0)


TAIL_BYTES = 512 * 1024  # transcripts grow to many MB; read only the end


def from_transcript(data):
    """Fallback: derive used tokens from the end of the transcript."""
    used = 0
    tpath = data.get("transcript_path")
    if tpath and os.path.exists(tpath):
        try:
            text = read_tail(tpath, TAIL_BYTES)
            for line in text.split("\n"):
                if '"usage"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "assistant" or obj.get("isSidechain"):
                    continue
                u = obj.get("message", {}).get("usage")
                if not u:
                    continue
                used = ((u.get("input_tokens") or 0)
                        + (u.get("cache_read_input_tokens") or 0)
                        + (u.get("cache_creation_input_tokens") or 0))
        except Exception:
            pass
    return used


def detect_limit(data, used):
    """Detect a 1M session when context_window is missing (older versions /
    resume edge cases). Otherwise a resumed 1M session would show /200k."""
    if used > 200_000:
        return 1_000_000
    if data.get("exceeds_200k_tokens"):
        return 1_000_000
    model = data.get("model") or {}
    model_str = f"{model.get('id', '')} {model.get('display_name', '')}"
    if "[1m]" in model_str.lower():
        return 1_000_000
    try:
        settings_path = os.path.expanduser("~/.claude/settings.json")
        with open(settings_path, encoding="utf-8-sig") as f:
            settings = json.load(f)
        if "[1m]" in str(settings.get("model", "")).lower():
            return 1_000_000
    except Exception:
        pass
    return 200_000


def git_branch(cwd):
    """Read `.git/HEAD` directly instead of spawning git (the statusline runs often)."""
    try:
        d = cwd
        for _ in range(12):
            git_path = os.path.join(d, ".git")
            if os.path.exists(git_path):
                head_file = os.path.join(git_path, "HEAD")
                if os.path.isfile(git_path):  # worktree: .git is a file
                    with open(git_path, encoding="utf-8") as f:
                        gitdir = f.read().split("gitdir:")[-1].strip()
                    if not os.path.isabs(gitdir):
                        gitdir = os.path.join(d, gitdir)
                    head_file = os.path.join(gitdir, "HEAD")
                with open(head_file, encoding="utf-8") as f:
                    head = f.read().strip()
                if head.startswith("ref: refs/heads/"):
                    return head[len("ref: refs/heads/"):]
                return head[:7]
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
    except Exception:
        pass
    return None


def read_tail(path, max_bytes):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - max_bytes))
        return f.read().decode("utf-8", errors="replace")


def waiting_on_tool(path):
    """Last message entry of a subagent transcript: assistant with tool_use =
    waiting for a tool (e.g. a long build), user with tool_result = the model
    is working on the next step. Either way nothing is written to the
    transcript until it finishes, but the agent is still running."""
    for line in reversed(read_tail(path, 64 * 1024).split("\n")):
        if '"type"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if not isinstance(obj, dict) or obj.get("type") not in ("assistant", "user"):
            continue
        content = (obj.get("message") or {}).get("content")
        if not isinstance(content, list):
            return False
        want = "tool_use" if obj["type"] == "assistant" else "tool_result"
        return any(isinstance(c, dict) and c.get("type") == want for c in content)
    return False


def active_agents(data):
    """Running subagents: agent-*.jsonl under <session>/subagents/. Active
    means written within the last 45s (running agents append constantly), or
    at most 10 min old and currently waiting on a tool or the next model reply
    (10 min = the maximum Bash timeout). Resume-safe, because the path is
    derived directly from transcript_path."""
    import time
    try:
        tpath = data.get("transcript_path")
        if not tpath:
            return 0
        base = tpath[:-6] if tpath.lower().endswith(".jsonl") else tpath
        subdir = os.path.join(base, "subagents")
        if not os.path.isdir(subdir):
            return 0
        now = time.time()
        count = 0
        for f in os.listdir(subdir):
            if not (f.startswith("agent-") and f.endswith(".jsonl")):
                continue
            path = os.path.join(subdir, f)
            age = now - os.path.getmtime(path)
            if age < 45:
                count += 1
            elif age < 600:
                try:
                    if waiting_on_tool(path):
                        count += 1
                except Exception:
                    pass
        return count
    except Exception:
        return 0


def fmt_reset(sec):
    """Time until a limit resets: 2d4h / 1h05m / 12m"""
    minutes = max(0, int(sec // 60))
    if minutes >= 1440:
        return f"{minutes // 1440}d{(minutes % 1440) // 60}h"
    if minutes >= 60:
        return f"{minutes // 60}h{minutes % 60:02d}m"
    return f"{minutes}m"


def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x == x and abs(x) != float("inf")


def rate_limits(data):
    """Rate limits (Pro/Max, or a gateway spend limit): "5h 23% . 7d 41%".
    From 70 % on with the time until reset. Missing windows are skipped."""
    import time
    rl = data.get("rate_limits")
    if not isinstance(rl, dict):
        return ""
    now = time.time()
    bits = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d"), ("spend_limit", "spend")):
        w = rl.get(key)
        if not isinstance(w, dict) or not is_num(w.get("used_percentage")):
            continue
        pct = max(0, w["used_percentage"])
        col = RED if pct >= 90 else YELLOW if pct >= 70 else GREEN
        bit = f"{DIM}{label}{RESET} {col}{fixed(pct, 0)}%{RESET}"
        reset = w.get("resets_at")
        if pct >= 70 and is_num(reset) and reset > now:
            bit += f" {DIM}({fmt_reset(reset - now)}){RESET}"
        bits.append(bit)
    return f" {DIM}\u00b7{RESET} ".join(bits)


def fmt_duration(ms):
    minutes = int(ms // 60_000)
    if minutes < 60:
        return f"{minutes}m"
    return f"{minutes // 60}h{minutes % 60:02d}m"


def bar(pct, width=10):
    # floor(x+0.5) instead of round(): rounds exactly like the JS variant
    # (Python rounds halves to even, JS does not)
    filled = max(0, min(width, int(pct / 100 * width + 0.5)))
    return "\u25b0" * filled + DIM + "\u25b1" * (width - filled)


def main():
    try:
        # otherwise Windows Python uses cp1252 and crashes on the bar characters
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    try:
        # Read bytes and decode as UTF-8 ourselves: otherwise Windows Python
        # uses cp1252 for stdin and garbles non-ASCII paths (folder name, git).
        # utf-8-sig also strips a BOM that some shells pipe along.
        data = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
    except Exception:
        print("Claude")
        return

    try:
        render(data)
    except Exception:
        # Contract: never crash; worst case, show just the name
        print("Claude")


def mode_suffix(data):
    # Thinking mode: effort.level (absent for models without an effort
    # parameter), thinking.enabled (only "off" is shown), fast_mode.
    out = ""
    effort = data.get("effort")
    if isinstance(effort, dict) and isinstance(effort.get("level"), str) and effort["level"]:
        out += f" {DIM}\u00b7{RESET} {effort['level']}"
    thinking = data.get("thinking")
    if isinstance(thinking, dict) and thinking.get("enabled") is False:
        out += f" {DIM}\u00b7 thinking off{RESET}"
    if data.get("fast_mode") is True:
        out += f" {YELLOW}\u26a1{RESET}"
    return out


def render(data):
    model = data.get("model") or {}
    name = model.get("display_name") or model.get("id") or "Claude"
    try:
        name += mode_suffix(data)
    except Exception:
        pass

    cw = data.get("context_window") or {}
    size = cw.get("context_window_size")
    if size:
        used = cw.get("total_input_tokens")
        if used is None:
            cu = cw.get("current_usage") or {}
            used = ((cu.get("input_tokens") or 0)
                    + (cu.get("cache_read_input_tokens") or 0)
                    + (cu.get("cache_creation_input_tokens") or 0))
        limit = size
        pct = cw.get("used_percentage")
        if pct is None:
            pct = (used / limit * 100) if limit else 0
    else:
        used = from_transcript(data)
        limit = detect_limit(data, used)
        pct = (used / limit * 100) if limit else 0
    if not isinstance(pct, (int, float)) or pct != pct:  # NaN guard
        pct = 0
    pct = max(0, pct)
    free = max(0, limit - used)

    col = RED if pct >= 90 else YELLOW if pct >= 70 else GREEN
    sep = f" {DIM}\u2502{RESET} "

    ctx_seg = (f"{col}{fmt_tokens(used)}{RESET}{DIM}/{fmt_limit(limit)}{RESET} "
               f"{DIM}\u00b7{RESET} free {GREEN}{fmt_tokens(free)}{RESET}")
    if pct >= 85:
        ctx_seg += f" {RED}compact soon{RESET}"

    parts = [
        name,
        f"{col}{bar(pct)}{RESET} {col}{fixed(pct, 0)}%{RESET}",
        ctx_seg,
    ]

    limits = rate_limits(data)
    if limits:
        parts.append(limits)

    agents = active_agents(data)
    if agents > 0:
        parts.append(f"{CYAN}Agents: {agents}{RESET}")

    cost = data.get("cost") or {}
    cost_bits = []
    if (cost.get("total_cost_usd") or 0) > 0:
        cost_bits.append("$" + fixed(cost["total_cost_usd"], 2))
    added = cost.get("total_lines_added") or 0
    removed = cost.get("total_lines_removed") or 0
    if added or removed:
        cost_bits.append(f"{GREEN}+{added}{RESET}{DIM}/{RESET}{RED}-{removed}{RESET}{DIM} lines{RESET}")
    if (cost.get("total_duration_ms") or 0) > 60_000:
        cost_bits.append(fmt_duration(cost["total_duration_ms"]) + " runtime")
    if cost_bits:
        # join outside the f-string: a backslash in the expression needs Python 3.12+
        joined = " \u00b7 ".join(cost_bits)
        parts.append(f"{DIM}{joined}{RESET}")

    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd")
    if cwd:
        loc = os.path.basename(cwd)
        branch = git_branch(cwd)
        if branch:
            loc += f" {CYAN}({branch}){RESET}"
        parts.append(loc)

    print(sep.join(parts))


if __name__ == "__main__":
    main()
STATUSLINE_PY_EOF

cat > "$CLAUDE_DIR/statusline.js" <<'STATUSLINE_JS_EOF'
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
STATUSLINE_JS_EOF

if [ "$RUNTIME" = "python3" ]; then
    CMD="python3 \"$HOME/.claude/statusline.py\""
    SCRIPT="$CLAUDE_DIR/statusline.py"
else
    CMD="node \"$HOME/.claude/statusline.js\""
    SCRIPT="$CLAUDE_DIR/statusline.js"
fi

merge install

OUT=$(echo '{"model":{"display_name":"Test"},"context_window":{"context_window_size":200000,"total_input_tokens":50000}}' | $RUNTIME "$SCRIPT")
[ -n "$OUT" ] || { echo "Smoke test failed: no output." >&2; exit 1; }

echo ""
echo "Statusline installed ($RUNTIME): $SCRIPT"
echo "settings.json updated (backup: settings.json.bak)"
echo "Test output:  $OUT"
echo "Done. New Claude Code sessions show the statusline; running sessions after a restart."
