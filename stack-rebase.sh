#!/usr/bin/env bash
#
# stack-rebase.sh — maintain a stack of git branches after lower branches are
# updated. Replays each branch's unique commits onto its updated parent using
# `git rebase --onto`.
#
# State is stored per-branch in git config:
#   branch.<name>.stackOnto — parent branch name in the stack
#   branch.<name>.stackBase — SHA of the parent tip at the last successful
#                             rebase (the <upstream> for `git rebase --onto`)

set -euo pipefail

# Regex matching stack branch names. Override with --pattern.
NAME_RE='^logind-phase[0-9]+$'
DRY_RUN=0
CMD=""

die()  { echo "stack-rebase: $*" >&2; exit 1; }
log()  { echo "stack-rebase: $*"; }
warn() { echo "stack-rebase: $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [--pattern REGEX] [--dry-run] <command>

Commands:
  status    Show sync state for each branch in the stack.
  init      Record current parent tips for every branch whose parent is
            already an ancestor. Errors out for "stale" branches and prints
            the git config commands to set them up by hand.
  sync      Rebase any branch whose parent has moved, bottom-up. On conflict,
            stops for manual resolution; rerun after 'git rebase --continue'.

Options:
  --pattern REGEX   Match branch names against REGEX instead of the default
                    '$NAME_RE'.
  --dry-run         With 'sync', print the planned rebases without running.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pattern)  NAME_RE="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        status|init|sync)
            [[ -z "$CMD" ]] || die "multiple commands given"
            CMD="$1"; shift ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "$CMD" ]] || { usage >&2; exit 2; }

discover_stack() {
    git for-each-ref --format='%(refname:short)' refs/heads/ \
        | grep -E -- "$NAME_RE" \
        | sort -V
}

require_clean_worktree() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "working tree is dirty; commit or stash first"
    fi
}

require_no_rebase_in_progress() {
    local gd
    gd=$(git rev-parse --git-dir)
    if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; then
        die "a rebase is already in progress; finish it first"
    fi
}

short() { git rev-parse --short "$1"; }

cmd_status() {
    local prev="" curr onto base new_tip
    while read -r curr; do
        [[ -z "$curr" ]] && continue
        if [[ -z "$prev" ]]; then
            log "$curr: (base of stack)"
            prev="$curr"
            continue
        fi
        onto=$(git config --get "branch.$curr.stackOnto" || true)
        base=$(git config --get "branch.$curr.stackBase" || true)
        if [[ -z "$onto" || -z "$base" ]]; then
            log "$curr: not initialized (run 'init')"
            prev="$curr"
            continue
        fi
        new_tip=$(git rev-parse --verify "$onto")
        if [[ "$base" == "$new_tip" ]]; then
            log "$curr: in sync (onto $onto @ $(short "$new_tip"))"
        else
            log "$curr: STALE (onto $onto: $(short "$base") -> $(short "$new_tip"))"
        fi
        prev="$curr"
    done < <(discover_stack)
}

cmd_init() {
    local prev="" curr tip has_errors=0
    while read -r curr; do
        [[ -z "$curr" ]] && continue
        if [[ -z "$prev" ]]; then
            log "$curr: (base of stack, skipping)"
            prev="$curr"
            continue
        fi
        if git merge-base --is-ancestor "$prev" "$curr"; then
            tip=$(git rev-parse --verify "$prev")
            git config "branch.$curr.stackOnto" "$prev"
            git config "branch.$curr.stackBase" "$tip"
            log "$curr: onto=$prev base=$(short "$tip")"
        else
            has_errors=1
            cat >&2 <<EOF
stack-rebase: $curr is stale — parent $prev is not an ancestor.
  Fix manually by pointing stackBase at the old parent tip, e.g.:
      git config branch.$curr.stackOnto $prev
      git config branch.$curr.stackBase \$(git rev-parse $curr~N)
  where N is the number of unique commits on top of $curr (inspect with
  'git log --oneline $curr' and count commits added on top of $prev).
EOF
        fi
        prev="$curr"
    done < <(discover_stack)
    (( has_errors )) && die "init incomplete; fix stale branches above and re-run"
    log "init complete"
}

rebase_one() {
    local curr="$1" onto="$2" base="$3" new_tip="$4"
    if git merge-base --is-ancestor "$base" "$curr"; then
        log "$curr: rebasing ($(short "$base") -> $(short "$new_tip"))"
        if ! git rebase --onto "$onto" "$base" "$curr"; then
            cat >&2 <<EOF
stack-rebase: conflict while rebasing $curr onto $onto.
  Resolve conflicts, then:
      git rebase --continue
  then re-run this command to continue with the rest of the stack.
EOF
            exit 1
        fi
    else
        log "$curr: already rebased out-of-band; updating stackBase only"
    fi
    git config "branch.$curr.stackBase" "$new_tip"
}

cmd_sync() {
    (( DRY_RUN )) || require_clean_worktree
    require_no_rebase_in_progress
    declare -A will_rebase=()
    local prev="" curr onto base new_tip count=0
    while read -r curr; do
        [[ -z "$curr" ]] && continue
        if [[ -z "$prev" ]]; then
            prev="$curr"
            continue
        fi
        onto=$(git config --get "branch.$curr.stackOnto" || true)
        base=$(git config --get "branch.$curr.stackBase" || true)
        [[ -n "$onto" && -n "$base" ]] || die "$curr: not initialized (run 'init')"
        new_tip=$(git rev-parse --verify "$onto")

        # Stale if parent tip moved, or if an earlier iteration decided the
        # parent itself needs a rebase (its tip will change under us in a real
        # sync; dry-run has to predict this explicitly).
        local parent_pending=${will_rebase[$onto]:-0}
        if [[ "$base" == "$new_tip" && "$parent_pending" == "0" ]]; then
            log "$curr: in sync"
            prev="$curr"
            continue
        fi

        if (( DRY_RUN )); then
            if (( parent_pending )); then
                log "$curr: would rebase (cascades from $onto)"
            else
                log "$curr: would run: git rebase --onto $onto $(short "$base") $curr"
            fi
        else
            rebase_one "$curr" "$onto" "$base" "$new_tip"
        fi
        will_rebase[$curr]=1
        count=$((count+1))
        prev="$curr"
    done < <(discover_stack)
    if (( DRY_RUN )); then
        log "dry-run complete ($count branch(es) would be updated)"
    else
        log "sync complete ($count branch(es) updated)"
    fi
}

case "$CMD" in
    status) cmd_status ;;
    init)   cmd_init ;;
    sync)   cmd_sync ;;
esac
