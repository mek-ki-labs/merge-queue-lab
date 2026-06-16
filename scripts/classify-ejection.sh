#!/usr/bin/env bash
set -euo pipefail

# Why was PR $PR ejected from the merge queue? Inspect the check-run conclusions
# on the most recent merge_group attempt for this PR. Sets GITHUB_OUTPUT cause to:
#   ordering = the ordering gate failed and NO other required check failed
#   other    = a non-ordering required check failed — do NOT auto-heal / re-queue
#   none     = nothing failed (stale race, or sibling-induced cancel) — safe to re-queue
# The healer only heals+re-queues for ordering|none; "other" is left for a human,
# so a real test failure can never ping-pong through the queue.

ORDERING_CHECK="${ORDERING_CHECK:-gate}"
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

other=false; ordering=false
for n in "${failed[@]}"; do
  if [ "$n" = "$ORDERING_CHECK" ]; then ordering=true; else other=true; echo "non-ordering failure: $n"; fi
done

if [ "$other" = true ]; then cause=other
elif [ "$ordering" = true ]; then cause=ordering
else cause=none; fi

echo "failed checks: ${failed[*]} -> cause=$cause"
echo "cause=$cause" >> "$GITHUB_OUTPUT"
