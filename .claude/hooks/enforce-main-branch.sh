#!/usr/bin/env bash
# TimeCapsule branch policy guard (PreToolUse, matcher: Bash)
#
# CLAUDE.md and PROJECT_HANDOFF.md both say this repo is `main`-only: no side
# branches, no pull requests, unless the human explicitly asks for that exact
# workflow. That instruction has been read and then disregarded at least once by
# an agent whose session told it to develop on a branch, so the rule is enforced
# here rather than left to good intentions. A hook is executed by the harness;
# an instruction is merely advisory.
#
# Blocks:
#   - a push while HEAD is not `main`
#   - a push naming a destination ref that is not main/HEAD
#   - PR creation via the gh CLI
# Allows:
#   - deleting a remote branch (that is cleanup, not landing work)
#
# Matching runs against a NORMALISED copy of the command: heredoc bodies and
# quoted strings are stripped first. Without that, a commit message or a doc
# that merely mentions the blocked commands is refused as if it were one --
# blocking legitimate work is the worse failure, and it happened twice on the
# very commit that introduced this file. The trade-off is that a quoted
# destination loses its explicit-ref check; it still has to pass the
# HEAD-is-main check below, which is the load-bearing one.
#
# To change or remove this policy, run /hooks -- do not work around it.

set -uo pipefail

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || printf '')
[ -n "$cmd" ] || exit 0

# Drop heredoc bodies, then quoted segments, before any matching.
scan=$(printf '%s\n' "$cmd" | awk '
  { if (skip) { if ($0 == delim) { skip = 0 }; next }
    line = $0
    if (match(line, /<<-?[[:space:]]*'"'"'?[A-Za-z_][A-Za-z0-9_]*'"'"'?/)) {
      d = substr(line, RSTART, RLENGTH)
      gsub(/^<<-?[[:space:]]*/, "", d); gsub(/'"'"'/, "", d)
      delim = d; skip = 1
    }
    print line }
' | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g')

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

policy_tail="This repo is main-only per CLAUDE.md and PROJECT_HANDOFF.md, and that applies even when your session was configured to use a branch - the project instructions win. Land the work on main instead: check out main, fast-forward it onto your commits, and push main. If the human explicitly asked for a branch or PR this turn, they can lift this with /hooks."

# --- PR creation via the gh CLI ----------------------------------------------
if printf '%s' "$scan" | grep -Eq '(^|[;&|[:space:]])gh[[:space:]]+pr[[:space:]]+(create|new)([[:space:]]|$)'; then
  deny "Blocked: pull requests are not this repo's workflow. $policy_tail"
fi

# --- pushes -------------------------------------------------------------------
if printf '%s' "$scan" | grep -Eq '(^|[;&|[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'; then

  # Removing a remote branch is cleanup, not landing work.
  if printf '%s' "$scan" | grep -Eq '(--delete([[:space:]]|=)|[[:space:]]-d[[:space:]])'; then
    exit 0
  fi

  # An explicitly named destination ref must be main.
  target=$(printf '%s' "$scan" \
    | grep -oE 'push([[:space:]]+-[^[:space:]]+)*[[:space:]]+[A-Za-z0-9._/-]+[[:space:]]+[A-Za-z0-9._/:-]+' \
    | head -n1 \
    | awk '{print $NF}')
  if [ -n "${target:-}" ]; then
    case "$target" in
      main|HEAD|HEAD:main|main:main|refs/heads/main) ;;
      *) deny "Blocked: '$target' is not main. $policy_tail" ;;
    esac
  fi

  # With no explicit ref the push follows HEAD, so HEAD must be main.
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
  if [ "$branch" != "main" ]; then
    deny "Blocked: HEAD is on '$branch', not main. $policy_tail"
  fi
fi

exit 0
