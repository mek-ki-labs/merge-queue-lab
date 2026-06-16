#!/usr/bin/env bash
# COMPLEX-path proof with the FIXED heal-rfc.sh (post-commit residual scan).
# eta  (winner): 0008-eta, UNINDEXED, clean body. Claims 0008.
# theta (loser): 0008-theta, INDEXED, body references its OWN old number below the H1.
# Expect: eta merges; theta ejects at boundary; healer renumbers 0008->0009 (file+H1+index),
#         post-commit scan finds the body ref to 0008 -> complex=true -> LLM no-op (no key) ->
#         push heal + POST COMMENT + DO NOT re-queue. theta stays OPEN with 1 comment.
set -uo pipefail
cd ~/merge-queue-lab
git fetch -q origin main
git checkout -q main >/dev/null 2>&1
git reset -q --hard origin/main

mkpr() { # branch num slug title indexed bodyextra
  local br=$1 num=$2 slug=$3 title=$4 indexed=$5 extra=$6
  git checkout -q -B "$br" main
  printf '# RFC %s: %s\n\n%s\n' "$num" "$title" "$extra" > "docs/rfcs/${num}-${slug}.md"
  if [ "$indexed" = yes ]; then
    printf -- '- [%s-%s.md](%s-%s.md) — RFC %s: %s\n' "$num" "$slug" "$num" "$slug" "$num" "$title" >> docs/rfcs/README.md
  fi
  git add -A
  git commit -q -m "add RFC ${num}-${slug}"
  git push -q -f origin "$br" >/dev/null 2>&1
  gh pr create --base main --head "$br" --title "RFC ${num} ${slug}" --body "lab" 2>/dev/null \
    || gh pr edit "$br" --title "RFC ${num} ${slug}" >/dev/null 2>&1
}

enqueue() { # branch
  for i in 1 2 3 4 5; do
    gh pr merge "$1" --auto --squash >/dev/null 2>&1 && { echo "  enqueued $1"; return 0; }
    sleep 4
  done
  echo "  WARN: could not enqueue $1"
}

allgreen() { # branch -> echoes rollup states
  gh pr view "$1" --json statusCheckRollup --jq '[.statusCheckRollup[].conclusion] | join(",")'
}

echo "=== create eta (winner, unindexed, clean) ==="
mkpr eta 0008 eta "Eta" no "Plain winner body. No prior-cycle references here."
echo "=== create theta (loser, indexed, body cites its OWN number) ==="
mkpr theta 0008 theta "Theta" yes "## Background

This proposal extends the direction set out in RFC 0008 during the earlier cycle
and should be read alongside that work."

echo "=== wait both green ==="
for n in $(seq 1 40); do
  e=$(allgreen eta); t=$(allgreen theta)
  echo "[$n] eta=$e theta=$t"
  case "$e" in *FAILURE*|*CANCELLED*) echo "eta check failed"; break;; esac
  case "$t" in *FAILURE*|*CANCELLED*) echo "theta check failed"; break;; esac
  eok=$(echo "$e" | grep -c SUCCESS || true)
  tok=$(echo "$t" | grep -c SUCCESS || true)
  [ "$e" = "SUCCESS,SUCCESS,SUCCESS" ] && [ "$t" = "SUCCESS,SUCCESS,SUCCESS" ] && break
  [ "$e" = "SUCCESS,SUCCESS" ] && [ "$t" = "SUCCESS,SUCCESS" ] && break
  sleep 10
done

echo "=== merge eta first ==="
enqueue eta
for n in $(seq 1 30); do
  s=$(gh pr view eta --json state --jq .state)
  echo "[eta $n] $s"
  [ "$s" = MERGED ] && { echo "eta MERGED"; break; }
  [ "$s" = CLOSED ] && { echo "eta CLOSED unexpectedly"; break; }
  sleep 8
done

git fetch -q origin main
echo "=== main RFCs after eta ==="
git ls-tree -r --name-only origin/main -- docs/rfcs/ | grep -E '[0-9]{4}-.*\.md$'

echo "=== queue theta (expect eject -> COMPLEX heal 0008->0009 -> comment + NO re-queue) ==="
enqueue theta
prev=""
for n in $(seq 1 50); do
  read -r st head cm < <(gh pr view theta --json state,headRefOid,comments --jq '"\(.state) \(.headRefOid) \(.comments|length)"')
  [ "$st $head $cm" != "$prev" ] && echo "[$n] state=$st head=${head:0:7} comments=$cm"
  prev="$st $head $cm"
  [ "$st" = MERGED ] && { echo "theta MERGED — UNEXPECTED for complex path"; break; }
  # complex success = healed (head moved, comment posted) AND still OPEN (not re-queued)
  if [ "$st" = OPEN ] && [ "$cm" -ge 1 ]; then
    sleep 20
    read -r st2 cm2 < <(gh pr view theta --json state,comments --jq '"\(.state) \(.comments|length)"')
    if [ "$st2" = OPEN ]; then echo "COMPLEX PROVEN: healed + commented + still OPEN (not re-queued)"; break; fi
  fi
  sleep 9
done

echo "=== theta final ==="
gh pr view theta --json state,headRefOid,comments --jq '{state,head:.headRefOid,comments:(.comments|length)}'
echo "=== theta commits ==="
gh pr view theta --json commits --jq '.commits[].messageHeadline'
echo "=== theta comment body ==="
gh pr view theta --json comments --jq '.comments[].body'
echo "=== main RFCs (theta must NOT be here) ==="
git fetch -q origin main
git ls-tree -r --name-only origin/main -- docs/rfcs/ | grep -E '[0-9]{4}-.*\.md$'
