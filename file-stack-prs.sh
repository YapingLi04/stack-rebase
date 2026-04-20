#!/usr/bin/env bash
#
# file-stack-prs.sh — file GitHub PRs for a stack of branches. For each branch
# matching the pattern, creates a PR against $BASE with a templated body that
# references the tracking issue and links to the parent branch's PR.
#
# Defaults are tuned for the logind-phase* stack in systemd/systemd, but every
# defaults is overridable via flags.

set -euo pipefail

REPO="systemd/systemd"
BASE="main"
ISSUE="41560"
NAME_RE='^logind-phase[0-9]+$'
FROM=3
TO=""
REPO_PATH="/home/yapingli/systemd"
HEAD_OWNER=""
DRY_RUN=0

PLACEHOLDER='<describe what this phase does>'

die()  { echo "file-stack-prs: $*" >&2; exit 1; }
log()  { echo "file-stack-prs: $*"; }
warn() { echo "file-stack-prs: $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Files GitHub PRs for each branch matching --pattern, one per phase, skipping
any branch that already has a PR. Each PR body is prefilled with a template
referencing the tracking issue and the parent phase's PR, and \$EDITOR is
opened so you can write the per-phase description before the PR is created.

Options:
  --repo REPO            Target repo (default: $REPO)
  --head-owner OWNER     Source fork owner (default: parsed from 'origin' URL)
  --base BRANCH          Base branch (default: $BASE)
  --issue NUMBER         Tracking issue # for body template (default: $ISSUE)
  --pattern REGEX        Branch name regex (default: $NAME_RE)
  --from N               Start phase (default: $FROM)
  --to N                 End phase (default: highest matching branch)
  --repo-path DIR        Where to run git/gh (default: $REPO_PATH)
  --dry-run              Print the plan, don't open editor or create PRs
  -h|--help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        REPO="$2"; shift 2 ;;
        --head-owner)  HEAD_OWNER="$2"; shift 2 ;;
        --base)        BASE="$2"; shift 2 ;;
        --issue)       ISSUE="$2"; shift 2 ;;
        --pattern)     NAME_RE="$2"; shift 2 ;;
        --from)        FROM="$2"; shift 2 ;;
        --to)          TO="$2"; shift 2 ;;
        --repo-path)   REPO_PATH="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
[[ -d "$REPO_PATH/.git" ]] || die "not a git repo: $REPO_PATH"

cd "$REPO_PATH"

if [[ -z "$HEAD_OWNER" ]]; then
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    [[ -n "$origin_url" ]] || die "no 'origin' remote; pass --head-owner"
    # matches git@github.com:OWNER/REPO(.git) and https://github.com/OWNER/REPO(.git)
    if [[ "$origin_url" =~ github\.com[:/]([^/]+)/[^/]+(\.git)?$ ]]; then
        HEAD_OWNER="${BASH_REMATCH[1]}"
    else
        die "can't parse owner from origin URL '$origin_url'; pass --head-owner"
    fi
fi

log "repo=$REPO base=$BASE head-owner=$HEAD_OWNER issue=$ISSUE"

discover_branches() {
    git for-each-ref --format='%(refname:short)' refs/heads/ \
        | grep -E -- "$NAME_RE" \
        | sort -V
}

# Extract the trailing integer from a branch name. Used to order phases and to
# locate the parent (N-1) branch.
phase_num() {
    local b="$1"
    [[ "$b" =~ ([0-9]+)$ ]] || { echo ""; return; }
    echo "${BASH_REMATCH[1]}"
}

# Print existing PR number for a given head branch, or empty if none.
find_pr_for_branch() {
    local branch="$1"
    gh pr list --repo "$REPO" \
        --head "$branch" \
        --state all \
        --json number,headRepositoryOwner \
        --jq ".[] | select(.headRepositoryOwner.login == \"$HEAD_OWNER\") | .number" \
        | head -n1
}

build_body() {
    local phase_n="$1" parent_pr="$2"
    cat <<EOF
This implements phase $phase_n of https://github.com/systemd/systemd/issues/$ISSUE.

$PLACEHOLDER

This is stacked onto https://github.com/systemd/systemd/pull/$parent_pr.
EOF
}

file_one() {
    local branch="$1" phase_n="$2" parent_pr="$3"
    local title="logind: migrate to Varlink (phase $phase_n)"
    local head="$HEAD_OWNER:$branch"

    if (( DRY_RUN )); then
        log "$branch: would file PR"
        log "  title: $title"
        log "  parent PR: #$parent_pr"
        log "  gh pr create --repo $REPO --base $BASE --head $head --title '$title' --body-file <tmp>"
        log "  body template:"
        build_body "$phase_n" "$parent_pr" | sed 's/^/    | /' >&2
        return 0
    fi

    local tmp
    tmp=$(mktemp -t "pr-body-$branch.XXXXXX")
    # Use double-quotes so $tmp expands NOW; trap body is literal filename.
    # Also clear the trap at end of this function so it doesn't fire on
    # unrelated later returns.
    trap "rm -f '$tmp'" RETURN
    build_body "$phase_n" "$parent_pr" > "$tmp"

    "${EDITOR:-vi}" "$tmp"

    if grep -qF "$PLACEHOLDER" "$tmp"; then
        warn "$branch: body still contains placeholder; skipping PR creation"
        return 0
    fi

    if ! [[ -s "$tmp" ]]; then
        warn "$branch: body is empty; skipping PR creation"
        return 0
    fi

    local url
    if url=$(gh pr create \
                --repo "$REPO" \
                --base "$BASE" \
                --head "$head" \
                --title "$title" \
                --body-file "$tmp"); then
        log "$branch: filed $url"
    else
        warn "$branch: gh pr create failed"
        return 1
    fi
}

main() {
    local filed=0 skipped=0 failed=0
    local branches
    mapfile -t branches < <(discover_branches)

    (( ${#branches[@]} > 0 )) || die "no branches match pattern: $NAME_RE"

    local branch n
    for branch in "${branches[@]}"; do
        n=$(phase_num "$branch")
        [[ -n "$n" ]] || { warn "$branch: can't parse phase number; skipping"; continue; }
        if (( n < FROM )); then
            continue
        fi
        if [[ -n "$TO" ]] && (( n > TO )); then
            continue
        fi

        local existing
        existing=$(find_pr_for_branch "$branch" || true)
        if [[ -n "$existing" ]]; then
            log "$branch: PR #$existing already exists, skipping"
            skipped=$((skipped+1))
            continue
        fi

        local parent="${branch%%[0-9]*}$((n-1))"
        local parent_pr
        parent_pr=$(find_pr_for_branch "$parent" || true)
        if [[ -z "$parent_pr" ]]; then
            if (( DRY_RUN )); then
                parent_pr="<pending>"
                warn "$branch: parent '$parent' has no PR yet (would be filed earlier in this run)"
            else
                warn "$branch: no PR found for parent '$parent'; stopping (file parent first)"
                failed=$((failed+1))
                break
            fi
        fi

        if file_one "$branch" "$n" "$parent_pr"; then
            filed=$((filed+1))
        else
            failed=$((failed+1))
            break
        fi
    done

    log "done: filed=$filed skipped=$skipped failed=$failed"
    (( failed == 0 ))
}

main
