#!/usr/bin/env bash
# np-guard: Ninth Planet production-write guard for Claude Code (PreToolUse, matcher Bash).
# Exit code 2 blocks the tool call and returns the message to Claude.
# Any other outcome lets the normal permission flow decide, so a parse problem never locks a session.
set -u
input="$(cat 2>/dev/null || true)"
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
elif command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    pass' 2>/dev/null || true)"
fi
# Last resort: match against the raw JSON. The patterns below accept a closing quote as a word end.
if [ -z "$cmd" ]; then cmd="$input"; fi

block() {
  printf 'np-guard blocked this command: %s.\nIt is a production write (or a default-branch push) under the Ninth Planet org rules: it needs the owner'"'"'s go and a record first. Prepare the change, verify it, and stop at the point where the owner runs it.\n' "$1" >&2
  exit 2
}
has() { printf '%s' "$cmd" | grep -Eq -e "$1"; }

# End of a word: whitespace, a shell separator, a quote, or the end of the text.
E='([[:space:];&|)"'"'"']|$)'

case "$cmd" in
  *"supabase functions deploy"*)                 block "supabase functions deploy" ;;
  *"supabase secrets set"*|*"supabase secrets unset"*) block "supabase secrets write" ;;
  *"supabase db push"*|*"supabase migration up"*) block "remote database migration" ;;
  *"supabase db reset --linked"*)                block "remote database reset" ;;
  *"fn:deploy"*)                                 block "manage.mjs fn:deploy" ;;
  *"deploy-edge-fn.mjs"*|*"deploy-changed-edge-fns.mjs"*) block "Edge Function deploy" ;;
  *"vercel --prod"*|*"vercel deploy --prod"*|*"vercel promote"*|*"vercel rollback"*) block "Vercel production change" ;;
esac

# Deploy tools whose --dry-run form is a safe preview.
if has "deploy-edge-fn-mgmt\.mjs" && ! has "--dry-run$E"; then block "Edge Function deploy (deploy-edge-fn-mgmt.mjs without --dry-run)"; fi
if has "wrangler +(versions +)?(deploy|publish)$E" && ! has "--dry-run$E"; then block "Cloudflare Worker deploy"; fi
if has "wrangler +secret +(put|bulk|delete)$E"; then block "Cloudflare secret write"; fi

# Force pushes, in any argument position (a leading + on a refspec is a force push too).
if has "git +push" && has "git +push([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(--force(-with-lease)?(=[^[:space:]]*)?|-f|\+[^[:space:];&|]+)$E"; then block "force push"; fi

# Direct pushes to a default branch (rulesets block them server-side too; this saves the round trip).
if has "git +push( +-[^ ]+)* +(origin|upstream) +(main|master)$E"; then block "push to the default branch"; fi
if has "git +push( +[^ ]+)* +[^ ]+:(refs/heads/)?(main|master)$E"; then block "push to the default branch"; fi

exit 0
