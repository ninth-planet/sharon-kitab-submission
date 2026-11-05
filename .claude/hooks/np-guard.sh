#!/usr/bin/env bash
# np-guard: Ninth Planet production-write guard for Claude Code (PreToolUse, matcher Bash).
# Exit code 2 blocks the tool call and returns the message to Claude.
# Any other outcome lets the normal permission flow decide, so a parse problem never locks a session.
set -u
input="$(cat 2>/dev/null || true)"
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
if [ -z "$cmd" ]; then cmd="$input"; fi

block() {
  printf 'np-guard blocked this command: %s.\nIt is a production write (or a default-branch push) under the Ninth Planet org rules: it needs the owner'"'"'s go and a record first. Prepare the change, verify it, and stop at the point where the owner runs it.\n' "$1" >&2
  exit 2
}

case "$cmd" in
  *"supabase functions deploy"*)                 block "supabase functions deploy" ;;
  *"supabase secrets set"*|*"supabase secrets unset"*) block "supabase secrets write" ;;
  *"supabase db push"*|*"supabase migration up"*) block "remote database migration" ;;
  *"supabase db reset --linked"*)                block "remote database reset" ;;
  *"fn:deploy"*)                                 block "manage.mjs fn:deploy" ;;
  *"vercel --prod"*|*"vercel deploy --prod"*|*"vercel promote"*|*"vercel rollback"*) block "Vercel production change" ;;
  *"git push --force"*|*"git push -f "*|*"--force-with-lease"*) block "force push" ;;
esac

# Direct pushes to a default branch (rulesets block them server-side too; this saves the round trip).
if printf '%s' "$cmd" | grep -Eq 'git +push( +-[^ ]+)* +(origin|upstream) +(main|master)( |$)'; then block "push to the default branch"; fi
if printf '%s' "$cmd" | grep -Eq 'git +push( +[^ ]+)* +[^ ]+:(main|master)( |$)'; then block "push to the default branch"; fi

exit 0
