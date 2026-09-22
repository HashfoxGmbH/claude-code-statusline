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
