#!/usr/bin/env bash
set -euo pipefail

# LLM-assist for the COMPLEX RFC heal: the deterministic codemod (heal-rfc.sh) has
# already renamed the file, patched the H1, and patched the index line and committed
# that. But the OLD number still appears in prose / elsewhere in the PR, where a
# mechanical sed must not guess. This step asks Claude to rewrite those remaining
# references from OLD -> NEW, then commits the result. The workflow does NOT re-queue
# after this — a prose identity change is human-reviewed before it lands on main.
#
# Without an API key this is a deliberate no-op (exit 0): the deterministic heal still
# gets pushed and the PR is left for a human, which is the correct safe fallback. This
# is the single hook where the live LLM plugs in once ANTHROPIC_API_KEY is configured.

cd "$(git rev-parse --show-toplevel)"

: "${OLD:?OLD rfc number required}"
: "${NEW:?NEW rfc number required}"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "::notice::no ANTHROPIC_API_KEY — skipping LLM rewrite; deterministic heal (rename+H1+index) will be pushed for human review"
  exit 0
fi

prompt="A merge-queue healer renumbered an RFC from ${OLD} to ${NEW} (the file was
renamed, its H1 updated, and its index line patched, already committed). Some
references to the old number ${OLD} remain — in the RFC body prose and/or elsewhere
in this branch's changes. Update ONLY the references that denote THIS RFC's identity
(e.g. 'RFC ${OLD}', links to ${OLD}-*, 'this RFC (${OLD})') to ${NEW}. Do NOT touch
mentions of OTHER RFCs or any unrelated occurrence of the digits ${OLD}. Make the
edits directly in the working tree. Do not commit."

bunx --yes @anthropic-ai/claude-code@latest -p "$prompt" \
  --allowedTools "Edit,Read,Grep,Glob" --permission-mode acceptEdits

if ! git diff --quiet; then
  git add -A
  git -c user.name="mek-ki-labs-healer[bot]" \
      -c user.email="mek-ki-labs-healer[bot]@users.noreply.github.com" \
      commit -q -m "heal(llm): rewrite remaining RFC ${OLD} references to ${NEW}"
  echo "LLM rewrote residual references; committed for human review"
else
  echo "::warning::LLM made no edits; residual ${OLD} references may remain — human review required"
fi
