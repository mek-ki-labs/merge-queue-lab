#!/usr/bin/env bash
set -euo pipefail

# Heal an RFC number collision by renumbering the NEWLY-ADDED colliding RFC to the
# next free number. This is the codemod Mek specified:
#   1. rename the file            NNNN-slug.md -> MMMM-slug.md
#   2. patch the H1               "# RFC NNNN: ..." -> "# RFC MMMM: ..." (if numbered)
#   3. patch the one index line   the README line that cites NNNN-slug (if present)
# then decide clean vs complex by scanning for ANY OTHER reference to the old number:
#   - clean   (complex=false): the old number survives nowhere -> the three mechanical
#             sites were the whole story. Healer auto-re-queues. Zero-touch.
#   - complex (complex=true):  the old number still appears (in the RFC body prose, or
#             elsewhere in the PR's diff). A deterministic codemod must NOT guess at
#             prose identity, so this is where an LLM assists — and the result WAITS
#             for a human to merge (healer does NOT re-queue).
#
# Why next-free (main_max+1) and not a PR-number block like migrations: an RFC number
# is human-meaningful and sequential, so we keep it small. The required check
# (check-rfc.sh) prevents a duplicate from ever LANDING on main, so under rare
# concurrency two healers may both pick the same number, the loser re-ejects, and the
# loop converges across cycles instead of in one pass. Migrations use throwaway
# timestamps so they buy one-pass convergence with disjoint PR blocks; RFCs trade that
# for readable numbers. Different artifact, different right answer.
#
# Sets GITHUB_OUTPUT: changed, complex, old, new, slug.

cd "$(git rev-parse --show-toplevel)"

rfc_num() { basename "$1" | grep -oE '^[0-9]{4}' || true; }

main_nums=$(git ls-tree -r --name-only origin/main -- docs/rfcs/ 2>/dev/null \
  | grep -E '^docs/rfcs/[0-9]{4}-.*\.md$' \
  | sed -E 's|.*/([0-9]{4})-.*|\1|' | sort -u || true)
main_max=$(printf '%s\n' "$main_nums" | grep -v '^$' | sort | tail -n1 || true)
[ -z "$main_max" ] && main_max=0

branch_added=$(git diff --diff-filter=AR -M --name-only origin/main...HEAD -- 'docs/rfcs/*.md' 2>/dev/null \
  | grep -E '^docs/rfcs/[0-9]{4}-.*\.md$' || true)

readme="docs/rfcs/README.md"
changed=false
complex=false
old=""; new=""; slug=""
next=$((10#$main_max))

while IFS= read -r f; do
  [ -z "$f" ] && continue
  n=$(rfc_num "$f")
  [ -z "$n" ] && continue
  # heal only a number that actually collides with main (reuse), not a mere gap
  printf '%s\n' "$main_nums" | grep -qx "$n" || continue

  next=$((next + 1))
  newn=$(printf '%04d' "$next")
  slug=$(basename "$f" | sed -E 's/^[0-9]{4}-//; s/\.md$//')
  newf="docs/rfcs/${newn}-${slug}.md"
  old="$n"; new="$newn"

  git mv "$f" "$newf"

  # 2. H1: only if the H1 carries the number (some RFCs use "# RFC: Title" — skip those)
  sed -i.bak -E "1,3 s/^# RFC ${n}:/# RFC ${newn}:/" "$newf" && rm -f "${newf}.bak"

  # 3. the one index line: rewrite link + label on lines that cite the old stem
  if [ -f "$readme" ] && grep -q "${n}-${slug}" "$readme"; then
    sed -i.bak -E "s/${n}-${slug}/${newn}-${slug}/g; s/RFC ${n}:/RFC ${newn}:/g" "$readme" && rm -f "${readme}.bak"
  fi

  git add "$newf" "$readme" 2>/dev/null || git add "$newf"
  changed=true

  # complex scan: does the OLD number survive anywhere the heal should have a say?
  #   (a) in the renamed RFC body, below the H1 we patched
  #   (b) anywhere else this PR added/changed lines (code/docs citing the old number)
  # Bias to safety: a bare \bNNNN\b match routes to human review. Over-matching just
  # asks for a human; under-matching would auto-merge a dangling reference.
  body_refs=$(tail -n +2 "$newf" | grep -w "$n" || true)
  diff_refs=$(git diff origin/main...HEAD -- . ":(exclude)${newf}" ":(exclude)${readme}" \
    | sed -n 's/^+//p' | grep -v '^+' | grep -w "$n" || true)
  if [ -n "$body_refs" ] || [ -n "$diff_refs" ]; then
    complex=true
    echo "complex: old number ${n} still referenced after codemod:"
    [ -n "$body_refs" ] && printf '  body: %s\n' "$body_refs"
    [ -n "$diff_refs" ] && printf '  diff: %s\n' "$diff_refs"
  fi

  echo "renumbered ${f} -> ${newf} (RFC ${n} -> ${newn})"
done <<< "$branch_added"

if [ "$changed" = true ]; then
  if [ "$complex" = false ]; then
    # TRUST GUARD (clean path only): the staged change set must be exactly the renamed
    # RFC file (rename + an H1 line edit) and at most the README index line. Anything
    # else means the codemod assumption is wrong — refuse the clean auto-path. The
    # complex path skips this because the LLM step (run by the workflow) will edit
    # prose, and that result is human-gated, not auto-merged.
    while IFS=$'\t' read -r status path rest; do
      case "$status" in
        R*) echo "$path" | grep -qE '^docs/rfcs/[0-9]{4}-.*\.md$' || { echo "trust guard: unexpected rename $path"; exit 1; } ;;
        M*) [ "$path" = "$readme" ] || echo "$path" | grep -qE '^docs/rfcs/[0-9]{4}-.*\.md$' || { echo "trust guard: unexpected edit $path"; exit 1; } ;;
        A*) echo "$path" | grep -qE '^docs/rfcs/[0-9]{4}-.*\.md$' || { echo "trust guard: unexpected add $path"; exit 1; } ;;
        "") : ;;
        *)  echo "trust guard: unexpected change ($status $path)"; exit 1 ;;
      esac
    done < <(git diff --cached -M --name-status)
  fi

  git -c user.name="mek-ki-labs-healer[bot]" \
      -c user.email="mek-ki-labs-healer[bot]@users.noreply.github.com" \
      commit -q -m "heal: renumber colliding RFC ${old} -> ${new}"
fi

{
  echo "changed=${changed}"
  echo "complex=${complex}"
  echo "old=${old}"
  echo "new=${new}"
  echo "slug=${slug}"
} >> "$GITHUB_OUTPUT"
