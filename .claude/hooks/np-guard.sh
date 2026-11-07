#!/usr/bin/env bash
# np-guard: Ninth Planet production-write guard for Claude Code (PreToolUse, matcher Bash).
#
# Exit 2 blocks the tool call and returns the message to Claude. Exit 0 lets the normal permission
# flow (settings deny/ask rules, then the user) decide. The hook is registered with
# onFailure: "block" (Claude Code 2.1.295+), so a crash, a timeout or any other exit code blocks the
# command too: every path below ends in exit 0 or exit 2 on purpose.
#
# Two layers, and a command is blocked if either one blocks it:
#   1. A shell-aware check in python3 (present on macOS with the Xcode tools, on Linux and in cloud
#      sessions). It splits the command the way the shell does and catches writes that plain text
#      matching cannot see (a bare `git push` while main is checked out, HTTP writes, wrappers such
#      as sudo, env and npx, nested commands and the .sh scripts it is asked to run). It can only add
#      blocks; when it cannot read a command fully it leaves the decision to the text checks.
#   2. Text checks, which always run (with or without python3). They are strict: a command that only
#      mentions a blocked phrase, such as a grep or a commit message, is blocked too.
#
# Known limits (GitHub rulesets and the settings deny rules stay the backstop): commands assembled
# at run time ($cmd, aliases, shell functions defined elsewhere), scripts in other languages that
# make HTTP calls themselves, and npm/make targets whose contents the guard cannot see.
set -u
input="$(cat 2>/dev/null || true)"

block() {
  printf 'np-guard blocked this command: %s.\nIt is a production write (or a default-branch push) under the Ninth Planet org rules: it needs the owner'"'"'s go and a record first. Prepare the change, verify it, and stop at the point where the owner runs it.\n' "$1" >&2
  exit 2
}

IFS= read -r -d '' NP_GUARD_PY <<'NP_GUARD_PY_END' || true
import json, os, re, subprocess, sys

DEFAULT_BRANCHES = ("main", "master")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
MAX_DEPTH = 5
MAX_SCRIPT_BYTES = 256 * 1024


def scan(text):
    """Split shell text into simple commands, the way the shell would.

    Returns (commands, nested). Each command is a dict with "words" (unquoted arguments), "sep"
    (the separator before it), "heredocs" (bodies fed to it) and "herestrings". nested holds the
    text of $(...), `...`, <(...) and >(...), which the shell runs as commands of their own.
    """
    commands, nested = [], []
    words, word = [], None
    heredocs, herestrings = [], []
    pending = []  # (delimiter, strip_tabs, index of the command it feeds)
    state = {"sep": "", "skip_next": False, "herestring_next": False}
    n, i = len(text), 0

    def end_word():
        nonlocal word
        if isinstance(word, list):
            word = "".join(word)
        if word is not None:
            if state["skip_next"]:
                state["skip_next"] = False
            elif state["herestring_next"]:
                state["herestring_next"] = False
                herestrings.append(word)
            else:
                words.append(word)
            word = None

    def end_command(sep):
        nonlocal words, heredocs, herestrings
        end_word()
        if words or heredocs or herestrings:
            commands.append({"words": words, "sep": state["sep"], "heredocs": heredocs, "herestrings": herestrings})
        words, heredocs, herestrings = [], [], []
        state["sep"] = sep

    def close_paren(j):
        """Index of the ) that closes the ( just before j (quotes respected), or n."""
        depth, k = 1, j
        while k < n:
            ch = text[k]
            if ch == "\\":
                k += 2
                continue
            if ch == "'":
                e = text.find("'", k + 1)
                k = n if e < 0 else e + 1
                continue
            if ch == '"':
                k += 1
                while k < n and text[k] != '"':
                    k += 2 if text[k] == "\\" else 1
                k += 1
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return k
            k += 1
        return n

    def close_backtick(j):
        k = j
        while k < n and text[k] != "`":
            k += 2 if text[k] == "\\" else 1
        return min(k, n)

    def add(s):
        nonlocal word
        if word is None:
            word = [s]
        elif isinstance(word, list):
            word.append(s)
        else:
            word = [word, s]

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c in " \t":
            end_word()
            i += 1
        elif c == "\\":
            if nxt == "\n":
                i += 2
            else:
                add(nxt)
                i += 2
        elif c == "#" and word is None:
            e = text.find("\n", i)
            i = n if e < 0 else e
        elif c == "'":
            e = text.find("'", i + 1)
            e = n if e < 0 else e
            add(text[i + 1:e])
            i = e + 1
        elif c == '"':
            i += 1
            buf = ""
            while i < n and text[i] != '"':
                ch = text[i]
                if ch == "\\" and i + 1 < n:
                    if text[i + 1] in '$`"\\':
                        buf += text[i + 1]
                    elif text[i + 1] != "\n":
                        buf += ch + text[i + 1]
                    i += 2
                elif ch == "$" and text[i + 1:i + 3] == "((":
                    e = close_paren(i + 2)
                    buf += text[i:e + 1]
                    i = e + 1
                elif ch == "$" and text[i + 1:i + 2] == "(":
                    e = close_paren(i + 2)
                    nested.append(text[i + 2:e])
                    buf += "\0"
                    i = e + 1
                elif ch == "`":
                    e = close_backtick(i + 1)
                    nested.append(text[i + 1:e].replace("\\`", "`"))
                    buf += "\0"
                    i = e + 1
                else:
                    buf += ch
                    i += 1
            add(buf)
            i += 1
        elif c == "$" and nxt == "'":
            i += 2
            buf = ""
            while i < n and text[i] != "'":
                if text[i] == "\\" and i + 1 < n:
                    esc = text[i + 1]
                    buf += {"n": "\n", "t": "\t", "\\": "\\", "'": "'", '"': '"'}.get(esc, "\\" + esc)
                    i += 2
                else:
                    buf += text[i]
                    i += 1
            add(buf)
            i += 1
        elif c == "$" and text[i + 1:i + 3] == "((":
            e = close_paren(i + 2)
            add(text[i:e + 1])
            i = e + 1
        elif c == "$" and nxt == "(":
            e = close_paren(i + 2)
            nested.append(text[i + 2:e])
            add("\0")
            i = e + 1
        elif c == "`":
            e = close_backtick(i + 1)
            nested.append(text[i + 1:e].replace("\\`", "`"))
            add("\0")
            i = e + 1
        elif c in "<>" and nxt == "(":
            e = close_paren(i + 2)
            nested.append(text[i + 2:e])
            add("\0")
            i = e + 1
        elif c == "<" and text[i:i + 3] == "<<<":
            end_word()
            state["herestring_next"] = True
            i += 3
        elif c == "<" and nxt == "<":
            end_word()
            i += 2
            strip = False
            if i < n and text[i] == "-":
                strip = True
                i += 1
            while i < n and text[i] in " \t":
                i += 1
            delim = ""
            while i < n and text[i] not in " \t\n;&|<>()":
                ch = text[i]
                if ch in "'\"":
                    e = text.find(ch, i + 1)
                    e = n if e < 0 else e
                    delim += text[i + 1:e]
                    i = e + 1
                elif ch == "\\":
                    delim += text[i + 1:i + 2]
                    i += 2
                else:
                    delim += ch
                    i += 1
            pending.append((delim, strip, len(commands)))
        elif c in "<>" or (c == "&" and nxt == ">"):
            # A redirection: an fd number before it is not an argument, the word after it is a file.
            if isinstance(word, list):
                word = "".join(word)
            if word is not None and word.isdigit() and not state["skip_next"]:
                word = None
            end_word()
            i += 1
            while i < n and text[i] in "<>&|":
                i += 1
            if i < n and (text[i].isdigit() or text[i] == "-") and text[i - 1] == "&":
                while i < n and (text[i].isdigit() or text[i] == "-"):
                    i += 1
            else:
                state["skip_next"] = True
        elif c in ";&|()\n":
            sep = c
            if c in "&|" and nxt == c:
                sep = c + c
                i += 1
            elif c == "|" and nxt == "&":
                sep = "|"
                i += 1
            end_command(sep)
            i += 1
            if c == "\n" and pending:
                for delim, strip, idx in pending:
                    body = []
                    while i < n:
                        e = text.find("\n", i)
                        e = n if e < 0 else e
                        line = text[i:e]
                        i = e + 1
                        if (line.lstrip("\t") if strip else line) == delim:
                            break
                        body.append(line)
                    target = commands[idx] if idx < len(commands) else None
                    if target is not None:
                        target["heredocs"].append("\n".join(body))
                pending = []
        else:
            add(c)
            i += 1
    end_command("")
    return commands, nested


ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
KEYWORDS = {"!", "{", "}", "then", "do", "else", "elif", "if", "while", "until", "coproc", "fi", "done", "esac", "in"}
SUDO_VAL = {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T"}
XARGS_VAL = {"-I", "-n", "-P", "-L", "-s", "-d", "-E", "-a", "-J", "-R", "-S"}
NPX_VAL = {"-p", "--package", "--registry", "--cache", "--userconfig"}
TOOLS = {"supabase", "vercel", "wrangler", "git", "gh", "curl", "node", "fastlane"}


def strip_version(name):
    if name.startswith("@"):
        at = name.find("@", 1)
        return name if at < 0 else name[:at]
    return name.split("@", 1)[0]


def base(word):
    b = word.replace("\\", "/").rsplit("/", 1)[-1]
    return b[:-4] if b.lower().endswith(".exe") else b


def unwrap(words, extra):
    """Drop assignments, keywords and wrapper programs (sudo, env, npx, ...) before the real program.
    Strings that a wrapper itself runs as a command (env -S, npx -c) go into extra."""
    w = list(words)
    changed = True
    while w and changed:
        changed = False
        while w and (ASSIGN.match(w[0]) or w[0] in KEYWORDS or w[0] == "time"):
            if w.pop(0) == "time" and w and w[0] == "-p":
                w.pop(0)
            changed = True
        if not w:
            break
        p = base(w[0])
        if p in ("sudo", "doas"):
            w.pop(0)
            while w and w[0].startswith("-"):
                o = w.pop(0)
                if o in SUDO_VAL and w:
                    w.pop(0)
            changed = True
        elif p == "env":
            w.pop(0)
            while w and (w[0].startswith("-") or ASSIGN.match(w[0])):
                o = w.pop(0)
                if o in ("-S", "--split-string") and w:
                    extra.append(w.pop(0))
                elif o in ("-u", "--unset", "-C", "--chdir") and w:
                    w.pop(0)
                elif o == "--":
                    break
            changed = True
        elif p in ("command", "builtin", "exec", "nohup", "noglob", "nice", "caffeinate", "stdbuf", "unbuffer", "chronic"):
            w.pop(0)
            while w and w[0].startswith("-"):
                o = w.pop(0)
                if o in ("-n", "-a") and w and p in ("nice", "exec"):
                    w.pop(0)
            changed = True
        elif p == "timeout":
            w.pop(0)
            while w and w[0].startswith("-"):
                o = w.pop(0)
                if o in ("-s", "--signal", "-k", "--kill-after") and w:
                    w.pop(0)
            if w:
                w.pop(0)  # the duration
            changed = True
        elif p == "xargs":
            w.pop(0)
            while w and w[0].startswith("-"):
                o = w.pop(0)
                if o in XARGS_VAL and w:
                    w.pop(0)
            changed = True
        elif p in ("npx", "bunx", "pnpx"):
            w.pop(0)
            while w and w[0].startswith("-"):
                o = w.pop(0)
                if o in ("-c", "--call") and w:
                    extra.append(w.pop(0))
                elif o in NPX_VAL and w:
                    w.pop(0)
                elif o == "--":
                    break
            if w:
                w[0] = strip_version(w[0])
            changed = True
        elif p in ("pnpm", "yarn", "bun", "npm") and len(w) > 1 and w[1] in ("dlx", "exec", "x"):
            w = w[2:]
            while w and w[0].startswith("-"):
                o = w.pop(0)
                if o == "--":
                    break
            if w:
                w[0] = strip_version(w[0])
            changed = True
        elif p in ("pnpm", "yarn") and len(w) > 1 and base(w[1]) in TOOLS:
            w.pop(0)
            changed = True
        elif p == "bundle" and len(w) > 1 and w[1] == "exec":
            w = w[2:]
            changed = True
        elif p in ("op", "npvault", "doppler", "infisical") and len(w) > 1 and w[1] == "run":
            w = w[2:]
            while w and w[0] != "--":
                o = w.pop(0)
                if not o.startswith("-"):
                    break
            if w and w[0] == "--":
                w.pop(0)
            changed = True
        elif p in ("dotenv", "dotenvx") and "--" in w:
            w = w[w.index("--") + 1:]
            changed = True
    return w


def positionals(args, value_flags=()):
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            out.extend(args[i + 1:])
            break
        if a.startswith("-"):
            if a in value_flags and "=" not in a:
                i += 1
        else:
            out.append(a)
        i += 1
    return out


def has_seq(toks, *seq):
    m = len(seq)
    return any(tuple(toks[k:k + m]) == seq for k in range(len(toks) - m + 1))


def flag(args, *names):
    return any(a == x or a.startswith(x + "=") for a in args for x in names)


class Guard:
    def __init__(self, cwd):
        self.cwd = cwd if isinstance(cwd, str) and os.path.isdir(cwd) else (os.environ.get("PWD") or "/")
        self.seen = {}

    def path(self, p, cwd=None):
        p = os.path.expanduser(p)
        return p if os.path.isabs(p) else os.path.normpath(os.path.join(cwd or self.cwd, p))

    def branch(self, gitdir):
        try:
            r = subprocess.run(["git", "-C", gitdir, "symbolic-ref", "--short", "-q", "HEAD"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
            return r.stdout.decode("utf-8", "replace").strip() or None
        except Exception:
            return None

    def script_file(self, p):
        try:
            full = os.path.realpath(self.path(p))
            if full in self.seen:
                return None  # already checked in this run
            self.seen[full] = True
            if os.path.isfile(full) and os.path.getsize(full) <= MAX_SCRIPT_BYTES:
                with open(full, "rb") as f:
                    return f.read().decode("utf-8", "replace")
        except Exception:
            pass
        return None

    # ---- entry points -------------------------------------------------------------------------

    def check_script(self, text, depth=0):
        if not text:
            return None
        if depth > MAX_DEPTH:
            return "command nested too deeply to check (more than %d levels)" % MAX_DEPTH
        commands, nested = scan(text)
        for inner in nested:
            r = self.check_script(inner, depth + 1)
            if r:
                return r
        prev = None
        for cmd in commands:
            words = cmd["words"]
            if words and base(words[0]) in ("cd", "pushd") and len(words) > 1 and cmd["sep"] in ("", ";", "&&", "\n"):
                target = self.path(words[1])
                if os.path.isdir(target):
                    self.cwd = target
            r = self.check_command(cmd, prev, depth)
            if r:
                return r
            prev = cmd
        return None

    def check_command(self, cmd, prev, depth):
        extra = []
        w = unwrap(cmd["words"], extra)
        for s in extra:
            r = self.check_script(s, depth + 1)
            if r:
                return r
        bodies = cmd["heredocs"] + cmd["herestrings"]
        if not w:
            return None
        prog, args = base(w[0]), w[1:]

        if prog in SHELLS:
            script = None
            for k, a in enumerate(args):
                if a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
                    script = args[k + 1] if k + 1 < len(args) else ""
                    break
            if script is not None:
                return self.check_script(script, depth + 1)
            files = [a for a in args if not a.startswith("-")]
            if files:
                body = self.script_file(files[0])
                return self.check_script(body, depth + 1) if body else None
            for b in bodies:
                r = self.check_script(b, depth + 1)
                if r:
                    return r
            if prev is not None and cmd["sep"] == "|":
                # `printf '...' | bash`: the previous command's arguments and heredocs become code.
                pw = unwrap(prev["words"], [])
                for b in [" ".join(pw[1:])] + prev["heredocs"] + prev["herestrings"]:
                    r = self.check_script(b, depth + 1)
                    if r:
                        return r
            return None
        if prog == "eval":
            return self.check_script(" ".join(args), depth + 1)
        if prog == "ssh":
            rest, i = [], 0
            vals = set("bcDEeFIiJLlmOopQRSWw")
            while i < len(args):
                a = args[i]
                if a.startswith("-") and len(a) == 2 and a[1] in vals:
                    i += 2
                    continue
                if a.startswith("-"):
                    i += 1
                    continue
                rest = args[i + 1:]
                break
            return self.check_script(" ".join(rest), depth + 1) if rest else None
        if "/" in w[0] and (prog.endswith(".sh") or prog.endswith(".bash")):
            body = self.script_file(w[0])
            if body:
                r = self.check_script(body, depth + 1)
                if r:
                    return r

        rule = RULES.get(prog)
        if rule:
            return rule(self, args)
        if prog in SCRIPT_RUNNERS or prog.endswith((".mjs", ".js", ".cjs", ".ts")):
            return self.node_script([w[0]] + args if prog.endswith((".mjs", ".js", ".cjs", ".ts")) else args)
        return None

    # ---- rules ------------------------------------------------------------------------------

    def git(self, args):
        gitdir, i = self.cwd, 0
        while i < len(args):
            a = args[i]
            if a == "-C" and i + 1 < len(args):
                gitdir = self.path(args[i + 1], gitdir)
                i += 2
            elif a in ("-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"):
                i += 2
            elif a.startswith("-"):
                i += 1
            else:
                break
        if i >= len(args) or args[i] != "push":
            return None
        return self.push(args[i + 1:], gitdir)

    def push(self, args, gitdir):
        force = every = delete = dry = tags_only = False
        explicit_repo = False
        pos, i = [], 0
        while i < len(args):
            a = args[i]
            if a == "--":
                pos.extend(args[i + 1:])
                break
            if a.startswith("--"):
                name = a.split("=", 1)[0]
                if name in ("--force", "--force-with-lease"):
                    force = True
                elif name in ("--all", "--mirror", "--branches"):
                    every = True
                elif name == "--delete":
                    delete = True
                elif name == "--dry-run":
                    dry = True
                elif name == "--tags":
                    tags_only = True
                elif name == "--repo":
                    explicit_repo = True
                    if "=" not in a:
                        i += 1
                elif name in ("--receive-pack", "--exec", "--push-option") and "=" not in a:
                    i += 1
            elif a.startswith("-") and len(a) > 1:
                cluster = a[1:]
                for k, ch in enumerate(cluster):
                    if ch == "f":
                        force = True
                    elif ch == "d":
                        delete = True
                    elif ch == "n":
                        dry = True
                    elif ch == "o":
                        if k == len(cluster) - 1:
                            i += 1
                        break
            else:
                pos.append(a)
            i += 1
        if dry:
            return None
        if force:
            return "force push"
        if every:
            return "push of every branch (--all/--mirror/--branches includes the default branch)"
        refspecs = pos if explicit_repo else pos[1:]
        for r in refspecs:
            if r.startswith("+"):
                return "force push"
            if r == ":":
                return "matching push (includes the default branch)"
            dst = r.split(":", 1)[1] if ":" in r else r
            if dst in ("HEAD", "@"):
                dst = self.branch(gitdir) or dst
            if dst.startswith("refs/heads/"):
                dst = dst[len("refs/heads/"):]
            if dst in DEFAULT_BRANCHES:
                return "delete of the default branch" if delete else "push to the default branch"
        if not refspecs and not tags_only:
            cur = self.branch(gitdir)
            if cur in DEFAULT_BRANCHES:
                return "push to the default branch (the checked-out branch is %s)" % cur
        return None

    def supabase(self, args):
        toks = positionals(args, ("--project-ref", "--workdir", "--profile", "-o", "--output", "--db-url",
                                  "--password", "-p", "--network-id", "--dns-resolver", "--env-file",
                                  "--import-map", "--schema", "-s"))
        remote = flag(args, "--linked", "--db-url")
        if has_seq(toks, "functions", "deploy"):
            return "supabase functions deploy"
        if has_seq(toks, "functions", "delete"):
            return "supabase functions delete"
        if has_seq(toks, "secrets", "set") or has_seq(toks, "secrets", "unset"):
            return "supabase secrets write"
        if has_seq(toks, "db", "push") and not flag(args, "--dry-run"):
            return "remote database migration (supabase db push)"
        if has_seq(toks, "db", "reset") and remote:
            return "remote database reset"
        if has_seq(toks, "migration", "up") and remote:
            return "remote database migration (supabase migration up)"
        if has_seq(toks, "migration", "repair") and not flag(args, "--local"):
            return "remote migration-ledger repair"
        if has_seq(toks, "config", "push"):
            return "remote project config push"
        if has_seq(toks, "projects", "delete"):
            return "project delete"
        return None

    def vercel(self, args):
        if flag(args, "--prod", "--production"):
            return "Vercel production deploy"
        for k, a in enumerate(args):
            if a == "--target" and k + 1 < len(args) and args[k + 1] == "production":
                return "Vercel production deploy"
            if a == "--target=production":
                return "Vercel production deploy"
        toks = positionals(args, ("--scope", "-S", "--token", "-t", "--cwd", "--local-config", "-A", "--global-config", "-Q", "--team", "-T"))
        if toks[:1] in (["promote"], ["rollback"]):
            return "Vercel production change (%s)" % toks[0]
        if toks[:1] == ["alias"] and toks[1:2] in (["set"], ["rm"], ["remove"]):
            return "Vercel alias change"
        return None

    def wrangler(self, args):
        toks = positionals(args, ("--env", "-e", "--config", "-c", "--name", "--cwd", "--compatibility-date", "--account-id"))
        dry = flag(args, "--dry-run")
        remote = flag(args, "--remote")
        if toks[:1] in (["deploy"], ["publish"]) and not dry:
            return "Cloudflare Worker deploy"
        if toks[:2] == ["versions", "deploy"] and not dry:
            return "Cloudflare Worker deploy"
        if toks[:1] == ["secret"] and toks[1:2] in (["put"], ["bulk"], ["delete"]):
            return "Cloudflare secret write"
        if toks[:2] == ["versions", "secret"] and toks[2:3] in (["put"], ["bulk"], ["delete"]):
            return "Cloudflare secret write"
        if toks[:2] == ["d1", "execute"] and remote:
            return "remote D1 database write"
        if toks[:3] == ["d1", "migrations", "apply"] and remote:
            return "remote D1 migration"
        return None

    def node_script(self, args):
        dry = "--dry-run" in args
        for a in args:
            if a.startswith("-"):
                continue
            b = base(a)
            if b in ("deploy-edge-fn.mjs", "deploy-changed-edge-fns.mjs"):
                return "Edge Function deploy (%s)" % b
            if b == "deploy-edge-fn-mgmt.mjs" and not dry:
                return "Edge Function deploy (deploy-edge-fn-mgmt.mjs without --dry-run)"
            if b == "manage.mjs" and any(x in ("fn:deploy", "env:set") for x in args):
                return "manage.mjs %s" % ("fn:deploy" if "fn:deploy" in args else "env:set")
            if b == "workflow.mjs" and any(x in ("deploy", "promote") for x in args):
                return "workflow.mjs deploy/promote (pushes to the production branch)"
            if b == "submit.mjs":
                return "App Store submission (submit.mjs)"
        return None

    def http(self, prog, args):
        urls = [a for a in args if re.match(r"^(https?://)?[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/|$)", a)]
        service = None
        for u in urls:
            host = re.sub(r"^https?://", "", u).split("/", 1)[0].split(":", 1)[0].lower()
            if host in GUARDED_HOSTS:
                service = GUARDED_HOSTS[host]
                break
        if not service:
            return None
        write = False
        if prog == "curl":
            method, data, get = None, False, False
            i = 0
            while i < len(args):
                a = args[i]
                if a.startswith("--"):
                    name, _, val = a.partition("=")
                    if name == "--request":
                        method = val or (args[i + 1] if i + 1 < len(args) else "")
                        i += 0 if val else 1
                    elif name in ("--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii",
                                  "--form", "--form-string", "--json", "--upload-file"):
                        data = True
                    elif name == "--get":
                        get = True
                elif a.startswith("-") and len(a) > 1:
                    cluster = a[1:]
                    for k, ch in enumerate(cluster):
                        if ch in "XdFT":
                            val = cluster[k + 1:] or (args[i + 1] if i + 1 < len(args) else "")
                            if ch == "X":
                                method = val
                            else:
                                data = True
                            if not cluster[k + 1:]:
                                i += 1
                            break
                        if ch == "G":
                            get = True
                        if ch in "HoumAebcrwKxEDUYyzQtCP":
                            if not cluster[k + 1:]:
                                i += 1
                            break
                i += 1
            if method:
                write = method.upper() not in ("GET", "HEAD", "OPTIONS")
            else:
                write = data and not get
        elif prog == "wget":
            write = any(a.split("=", 1)[0] in ("--post-data", "--post-file", "--body-data", "--body-file") for a in args) or \
                any(a.startswith("--method=") and a.split("=", 1)[1].upper() not in ("GET", "HEAD") for a in args)
        else:  # httpie / xh
            pos = [a for a in args if not a.startswith("-")]
            if pos and pos[0].upper() in ("POST", "PUT", "PATCH", "DELETE"):
                write = True
            elif any(re.match(r"^[^=:/@]+(:=|=|@)", a) for a in pos[1:] if a not in urls):
                write = not (pos and pos[0].upper() in ("GET", "HEAD"))
        return ("HTTP write to the %s" % service) if write else None

    def gh(self, args):
        toks = positionals(args, ("-R", "--repo", "-r", "--ref", "-f", "--raw-field", "-F", "--field", "-X", "--method", "-H", "--header", "--json", "-q", "--jq", "-t", "--template"))
        if toks[:2] == ["workflow", "run"] and len(toks) > 2 and PROD_WORKFLOW.search(toks[2]):
            return "owner-dispatched release workflow (gh workflow run %s)" % toks[2]
        if toks[:1] == ["api"]:
            for t in toks[1:]:
                m = re.search(r"/actions/workflows/([^/]+)/dispatches", t)
                if m and PROD_WORKFLOW.search(m.group(1)):
                    return "owner-dispatched release workflow (dispatch of %s)" % m.group(1)
        return None

    def xcrun(self, args):
        toks = [a for a in args if not a.startswith("-")]
        if toks[:1] == ["altool"] and any(a in ("--upload-app", "--upload-package") for a in args):
            return "App Store Connect upload (altool)"
        if toks[:1] == ["iTMSTransporter"] and "upload" in args:
            return "App Store Connect upload (iTMSTransporter)"
        return None

    def altool(self, args):
        if any(a in ("--upload-app", "--upload-package") for a in args):
            return "App Store Connect upload (altool)"
        return None

    def fastlane(self, args):
        toks = [a for a in args if not a.startswith("-") and ":" not in a]
        if toks[:1] in (["ios"], ["android"], ["mac"]):
            toks = toks[1:]
        if toks[:1] == ["run"]:
            toks = toks[1:]
        if toks and toks[0] in FASTLANE_UPLOADS:
            return "store upload (fastlane %s)" % toks[0]
        return None


GUARDED_HOSTS = {
    "api.supabase.com": "Supabase Management API",
    "api.vercel.com": "Vercel API",
    "api.appstoreconnect.apple.com": "App Store Connect API",
    "api.cloudflare.com": "Cloudflare API",
}
PROD_WORKFLOW = re.compile(r"(deploy|release|testflight|production|app-?store|submit|publish)", re.I)
FASTLANE_UPLOADS = {"pilot", "deliver", "supply", "upload_to_testflight", "upload_to_app_store",
                    "upload_to_play_store", "beta", "release", "deploy", "testflight"}
SCRIPT_RUNNERS = {"node", "deno", "bun", "tsx", "ts-node", "zx", "vite-node"}
RULES = {
    "git": Guard.git,
    "supabase": Guard.supabase,
    "vercel": Guard.vercel,
    "wrangler": Guard.wrangler,
    "gh": Guard.gh,
    "xcrun": Guard.xcrun,
    "altool": Guard.altool,
    "fastlane": Guard.fastlane,
    "curl": lambda g, a: g.http("curl", a),
    "wget": lambda g, a: g.http("wget", a),
    "http": lambda g, a: g.http("http", a),
    "https": lambda g, a: g.http("http", a),
    "xh": lambda g, a: g.http("http", a),
    "xhs": lambda g, a: g.http("http", a),
}


def main():
    raw = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    try:
        data = json.loads(raw)
    except Exception:
        print("ERR")
        return
    ti = data.get("tool_input") if isinstance(data, dict) else None
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str):
        print("ERR")
        return
    reason = Guard(data.get("cwd") or "").check_script(cmd)
    sys.stdout.buffer.write(("BLOCK:" + reason if reason else "OK").encode("utf-8", "replace"))


try:
    main()
except Exception:
    print("ERR")
NP_GUARD_PY_END

# 1. Shell-aware check.
if command -v python3 >/dev/null 2>&1; then
  verdict="$(printf '%s' "$input" | python3 -I -c "$NP_GUARD_PY" 2>/dev/null)" || verdict=""
  case "$verdict" in
    BLOCK:*) block "${verdict#BLOCK:}" ;;
  esac
fi

# 2. Text checks. They always run, so the shell-aware layer can add blocks but never lift one.
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
# Last resort: match against the raw JSON. The patterns below accept a closing quote as a word end.
if [ -z "$cmd" ]; then cmd="$input"; fi
has() { printf '%s' "$cmd" | grep -Eq -e "$1"; }

# End of a word: whitespace, a shell separator, a quote, or the end of the text.
E='([[:space:];&|)"'"'"'`\\]|$)'

if has "supabase[^;&|]* +(functions +(deploy|delete)|secrets +(set|unset)|db +push|migration +(up|repair)|config +push)$E"; then block "Supabase production change (deploy, secret, migration or config)"; fi
if has "supabase[^;&|]* +db +reset[^;&|]*--(linked|db-url)"; then block "remote database reset"; fi

case "$cmd" in
  *"fn:deploy"*|*"env:set"*)                     block "manage.mjs fn:deploy or env:set" ;;
  *"deploy-edge-fn.mjs"*|*"deploy-changed-edge-fns.mjs"*) block "Edge Function deploy" ;;
  *"vercel promote"*|*"vercel rollback"*|*"--target production"*|*"--target=production"*) block "Vercel production change" ;;
  *"submit.mjs"*|*"--upload-app"*|*"--upload-package"*) block "App Store upload or submission" ;;
esac

# Deploy tools whose --dry-run form is a safe preview.
if has "deploy-edge-fn-mgmt\.mjs" && ! has "--dry-run$E"; then block "Edge Function deploy (deploy-edge-fn-mgmt.mjs without --dry-run)"; fi
if has "vercel(@[^[:space:]]+)?( +[^ ;&|]+)* +--prod(uction)?$E"; then block "Vercel production deploy"; fi
if has "wrangler +(versions +)?(deploy|publish)$E" && ! has "--dry-run$E"; then block "Cloudflare Worker deploy"; fi
if has "wrangler +(versions +)?secret +(put|bulk|delete)$E"; then block "Cloudflare secret write"; fi
if has "workflow\.mjs +(deploy|promote)$E"; then block "workflow.mjs deploy/promote"; fi
if has "fastlane +((ios|android|mac) +)?(pilot|deliver|supply|beta|release|deploy|testflight|upload_to_[a-z_]+)$E"; then block "store upload (fastlane)"; fi
if has "gh +workflow +run +[^ ]*(deploy|release|testflight|production|app-?store|submit|publish)"; then block "owner-dispatched release workflow"; fi

# HTTP writes to production control-plane APIs.
if has "api\.(supabase\.com|vercel\.com|appstoreconnect\.apple\.com|cloudflare\.com)" && \
   has "(-X *|--request[= ]+|--method=)(POST|PUT|PATCH|DELETE)|[[:space:]](-d|-F|-T|--data[a-z-]*|--form[a-z-]*|--json|--upload-file|--post-data|--body-data)([[:space:]=]|$)"; then
  block "HTTP write to a production control-plane API"
fi

# Force pushes, in any argument position (a leading + on a refspec is a force push too).
if has "git +push" && has "git +push([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(--force(-with-lease)?(=[^[:space:]]*)?|-[a-zA-Z]*f[a-zA-Z]*|\+[^[:space:];&|]+)$E"; then block "force push"; fi

# Direct pushes to a default branch, with or without git -C/-c options (rulesets block them server-side too).
G='git( +-[Cc] +[^ ]+)* +push'
if has "$G( +[^ ;&|]+)* +(refs/heads/)?(main|master)$E"; then block "push to the default branch"; fi
if has "$G( +[^ ;&|]+)* +[^ ;&|]*:(refs/heads/)?(main|master)$E"; then block "push to the default branch"; fi
if has "$G( +[^ ]+)* +--(all|mirror|branches)$E"; then block "push of every branch"; fi
# A bare `git push` (or `git push origin`) while main is checked out.
if has "(^|[;&|][[:space:]]*|\"command\": *\")git push( +-u)?( +origin)? *($|[;&|\"])"; then
  cur="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  case "$cur" in main|master) block "push to the default branch (the checked-out branch is $cur)" ;; esac
fi

exit 0
