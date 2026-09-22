#!/usr/bin/env python3
"""Claude Code statusline: Modell + Context-Verbrauch + freie Tokens.

Primaerquelle ist das von Claude Code gelieferte stdin-Feld `context_window`
(ab v2.1.x). Das ist:
  - resume-fest (Wert kommt aus dem Live-Session-State, nicht aus dem Transcript),
  - limit-korrekt (context_window_size kennt 200k vs. 1M exakt),
  - subagenten-frei (nur der Haupt-Session-Context wird gezaehlt).

Fallback (aeltere Claude-Code-Versionen ohne context_window): letzte
Assistant-Nachricht der Hauptkette aus dem Transcript, Subagenten
(isSidechain == true) uebersprungen.

Gegenstueck zu %USERPROFILE%\\.claude\\statusline.js auf der Windows-Seite.
"""
import sys, json, os, math

RESET, DIM = "\033[0m", "\033[2m"
GREEN, YELLOW, RED, CYAN = "\033[32m", "\033[33m", "\033[31m", "\033[36m"


def fixed(x, digits, unit=1):
    """x/unit mit `digits` Nachkommastellen, halbe Werte aufgerundet.

    Erst auf eine Ganzzahl runden (floor(v + 0.5)), dann den String selbst
    bauen: Die Format-Rundung von Python und .NET geht bei halben Werten zur
    geraden Zahl (0.5 -> "0", 1.25 -> "1.2"), JS toFixed nicht. So zeigen
    alle drei Varianten exakt dieselben Werte."""
    v = max(0, int(math.floor((x * 10 ** digits + unit / 2) / unit)))
    s = str(v).zfill(digits + 1)
    return s[:-digits] + "." + s[-digits:] if digits else s


def fmt_tokens(n):
    # Schwellen nach dem Runden: 999950 ist "1.0M", nicht "1000.0k"
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


TAIL_BYTES = 512 * 1024  # Transcripts werden viele MB gross; nur Ende lesen


def from_transcript(data):
    """Fallback: used_tokens aus dem Transcript-Ende ableiten."""
    used = 0
    tpath = data.get("transcript_path")
    if tpath and os.path.exists(tpath):
        try:
            with open(tpath, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - TAIL_BYTES))
                text = f.read().decode("utf-8", errors="replace")
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
    """1M-Session erkennen, wenn context_window fehlt (aeltere Versionen /
    Resume-Edge-Cases). Sonst wuerde eine resumte 1M-Session als /200k
    angezeigt werden."""
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
    """`.git/HEAD` direkt lesen statt git zu spawnen (Statusline laeuft oft)."""
    try:
        d = cwd
        for _ in range(12):
            git_path = os.path.join(d, ".git")
            if os.path.exists(git_path):
                head_file = os.path.join(git_path, "HEAD")
                if os.path.isfile(git_path):  # Worktree: .git ist Datei
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


def active_agents(data):
    """Laufende Subagenten: agent-*.jsonl unter <session>/subagents/, das in
    den letzten 45s beschrieben wurde. Laufende Agenten appenden staendig an
    ihr Transcript; fertige Dateien veralten sofort. Resume-fest, da der Pfad
    direkt aus transcript_path abgeleitet wird."""
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
            if now - os.path.getmtime(os.path.join(subdir, f)) < 45:
                count += 1
        return count
    except Exception:
        return 0


def fmt_duration(ms):
    minutes = int(ms // 60_000)
    if minutes < 60:
        return f"{minutes}m"
    return f"{minutes // 60}h{minutes % 60:02d}m"


def bar(pct, width=10):
    # floor(x+0.5) statt round(): identisches Runden wie die JS-Variante
    # (Python rundet halbe Werte zur geraden Zahl, JS nicht)
    filled = max(0, min(width, int(pct / 100 * width + 0.5)))
    return "\u25b0" * filled + DIM + "\u25b1" * (width - filled)


def main():
    try:
        # Windows-Python nutzt sonst cp1252 und crasht an den Balkenzeichen
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    try:
        # BOM strippen - manche Shells pipen mit
        # Bytes lesen und selbst als UTF-8 dekodieren: Windows-Python nutzt fuer
        # stdin sonst cp1252 und zerlegt Umlaute in Pfaden (Ordnername, Git).
        # utf-8-sig strippt zugleich ein BOM, das manche Shells mitpipen.
        data = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
        if not isinstance(data, dict):
            raise ValueError("kein JSON-Objekt")
    except Exception:
        print("Claude")
        return

    try:
        render(data)
    except Exception:
        # Kontrakt: niemals crashen, schlimmstenfalls nur der Name
        print("Claude")


def mode_suffix(data):
    # Denkmodus: effort.level (fehlt bei Modellen ohne Effort-Parameter),
    # thinking.enabled (nur "aus" wird angezeigt), fast_mode.
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
    if not isinstance(pct, (int, float)) or pct != pct:  # NaN-Schutz
        pct = 0
    pct = max(0, pct)
    free = max(0, limit - used)

    col = RED if pct >= 90 else YELLOW if pct >= 70 else GREEN
    sep = f" {DIM}\u2502{RESET} "

    ctx_seg = (f"{col}{fmt_tokens(used)}{RESET}{DIM}/{fmt_limit(limit)}{RESET} "
               f"{DIM}\u00b7{RESET} free {GREEN}{fmt_tokens(free)}{RESET}")
    if pct >= 85:
        ctx_seg += f" {RED}Compact bald!{RESET}"

    parts = [
        name,
        f"{col}{bar(pct)}{RESET} {col}{fixed(pct, 0)}%{RESET}",
        ctx_seg,
    ]

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
        # Join ausserhalb des f-Strings: Backslash im Ausdruck erst ab Python 3.12 erlaubt
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
