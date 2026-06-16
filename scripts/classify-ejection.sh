#!/usr/bin/env bash
set -euo pipefail

# Why was PR $PR ejected from the merge queue? Inspect the check-run conclusions
# on the most recent merge_group attempt for this PR. Sets GITHUB_OUTPUT cause to:
#   ordering = the migration ordering gate failed and nothing else did -> rebump heal
#   rfc      = the RFC collision gate failed and nothing else did -> renumber heal
#   other    = some OTHER required check failed -> do NOT auto-heal / re-queue
#   none     = nothing failed (stale race, or sibling-induced cancel) — safe to re-queue
# "other" always wins if present, so a real test failure can never ping-pong. When
# both heal-able gates fail at once, RFC is reported first; the migration gate will
# re-trigger on the next cycle if still red.

ORDERING_CHECK="${ORDERING_CHECK:-gate}"
RFC_CHECK="${RFC_CHECK:-rfc-gate}"
repo="$GITHUB_REPOSITORY"

sha=$(gh api "repos/$repo/actions/runs?event=merge_group&per_page=100" \
  --jq "[.workflow_runs[] | select(.head_branch | test(\"/pr-${PR}-\"))] | sort_by(.created_at) | last | .head_sha // empty")

if [ -z "$sha" ]; then
  echo "no merge_group attempt found for PR #$PR — cause=none"
  echo "cause=none" >> "$GITHUB_OUTPUT"; exit 0
fi
echo "inspecting merge-group commit $sha"

mapfile -t failed < <(gh api "repos/$repo/commits/$sha/check-runs" --paginate \
  --jq '.check_runs[] | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="action_required") | .name')

if [ "${#failed[@]}" -eq 0 ]; then
  echo "no failed checks on merge-group commit — cause=none"
  echo "cause=none" >> "$GITHUB_OUTPUT"; exit 0
fi

other=false; ordering=false; rfc=false
for n in "${failed[@]}"; do
  if [ "$n" = "$ORDERING_CHECK" ]; then ordering=true
  elif [ "$n" = "$RFC_CHECK" ]; then rfc=true
  else other=true; echo "non-healable failure: $n"; fi
done

if [ "$other" = true ]; then cause=other
elif [ "$rfc" = true ]; then cause=rfc
elif [ "$ordering" = true ]; then cause=ordering
else cause=none; fi

echo "failed checks: ${failed[*]} -> cause=$cause"
echo "cause=$cause" >> "$GITHUB_OUTPUT"
