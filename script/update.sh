#!/usr/bin/env bash
# Requires: git, curl, jq  (optionally: gh)

set -euo pipefail

GITHUB_OWNERS=(
  "doughmination"
  "clove-web"
  "clove-archives"
)

LICENSE_SOURCE="../LICENCE.md"
COMMIT_MESSAGE="chore: update licence"

EXCLUDE_REPOS=(
  "nginx-config"
  "licencing"
  "tg"
  "sandrone-web"
  "email-server"
)

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

for extra_path in /opt/homebrew/bin /usr/local/bin; do
  if [[ -d "$extra_path" && ":$PATH:" != *":$extra_path:"* ]]; then
    PATH="$extra_path:$PATH"
  fi
done

log()  { printf '\033[1;34m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }

if [[ ! -f "$LICENSE_SOURCE" ]]; then
  err "LICENSE_SOURCE '$LICENSE_SOURCE' not found. Put your up-to-date licence text there first."
  exit 1
fi

USE_GH=0
if command -v gh >/dev/null 2>&1 && gh api user >/dev/null 2>&1; then
  USE_GH=1
  log "Using gh CLI for auth (account: $(gh api user --jq .login 2>/dev/null))."
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  log "Using GITHUB_TOKEN for auth."
else
  err "No auth available. Either log in with 'gh auth login', or export GITHUB_TOKEN=<personal access token>."
  if command -v gh >/dev/null 2>&1; then
    err "(gh was found on PATH but 'gh api user' failed — your active gh account's token may be invalid. Run 'gh auth status' to check.)"
  else
    err "(gh was not found on PATH: $PATH)"
  fi
  exit 1
fi

is_excluded() {
  local owner="$1" repo="$2"
  for ex in "${EXCLUDE_REPOS[@]}"; do
    [[ "$ex" == "$repo" ]] && return 0
    [[ "$ex" == "$owner/$repo" ]] && return 0
  done
  return 1
}

clone_url() {
  local owner="$1" repo="$2"
  if [[ $USE_GH -eq 1 ]]; then
    echo "https://github.com/$owner/$repo.git"
  else
    echo "https://x-access-token:${GITHUB_TOKEN}@github.com/$owner/$repo.git"
  fi
}

default_branch_for() {
  local repo="$1"
  echo "$REPO_JSON" | jq -r --arg name "$repo" '.[] | select(.name == $name) | .defaultBranchRef.name'
}

UPDATED=()
SKIPPED=()
UNCHANGED=()
FAILED=()

for GITHUB_OWNER in "${GITHUB_OWNERS[@]}"; do

  log "Fetching repo list for $GITHUB_OWNER..."

  if [[ $USE_GH -eq 1 ]]; then
    REPO_JSON="$(gh repo list "$GITHUB_OWNER" --limit 200 --json name,defaultBranchRef,isArchived)"
  else
    REPO_JSON="$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/users/$GITHUB_OWNER/repos?per_page=200" \
      | jq '[.[] | {name: .name, defaultBranchRef: {name: .default_branch}, isArchived: .archived}]')"
  fi

  REPO_NAMES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && REPO_NAMES+=("$line")
  done < <(echo "$REPO_JSON" | jq -r '.[] | select(.isArchived == false) | .name')

  for repo in "${REPO_NAMES[@]}"; do
    label="$GITHUB_OWNER/$repo"

    if is_excluded "$GITHUB_OWNER" "$repo"; then
      log "Skipping $repo (excluded)."
      SKIPPED+=("$label")
      continue
    fi

    branch="$(default_branch_for "$repo")"
    dest="$TMP_ROOT/$GITHUB_OWNER-$repo"

    log "Cloning $repo (branch: $branch)..."
    clone_err="$TMP_ROOT/.clone-err-$GITHUB_OWNER-$repo"
    if [[ $USE_GH -eq 1 ]]; then
      if ! GIT_LFS_SKIP_SMUDGE=1 gh repo clone "$GITHUB_OWNER/$repo" "$dest" -- --depth=1 --branch "$branch" -q 2>"$clone_err"; then
        warn "Clone failed for $repo:"
        sed 's/^/    /' "$clone_err" >&2
        FAILED+=("$label")
        continue
      fi
    else
      if ! GIT_LFS_SKIP_SMUDGE=1 git clone --depth=1 --branch "$branch" "$(clone_url "$GITHUB_OWNER" "$repo")" "$dest" -q 2>"$clone_err"; then
        warn "Clone failed for $repo:"
        sed 's/^/    /' "$clone_err" >&2
        FAILED+=("$label")
        continue
      fi
    fi

    canonical="$(basename "$LICENSE_SOURCE")"   # e.g. LICENCE.md

    # Remove every root-level licence file (either spelling, any case, any ext)
    # except the canonical name, so stray variants can't pile up.
    while IFS= read -r f; do
      [[ -n "$f" && "$f" != "$canonical" ]] || continue
      log "  Removing stray licence file: $f"
      git -C "$dest" rm -q --ignore-unmatch -- "$f"
    done < <(git -C "$dest" ls-files | grep -iE '^licen[sc]e(\.[a-z0-9]+)?$' || true)

    # Write the up-to-date licence as the single canonical file.
    cp "$LICENSE_SOURCE" "$dest/$canonical"
    git -C "$dest" add -- "$canonical"

    # Skip only if nothing is staged (content identical AND no strays removed).
    if git -C "$dest" diff --cached --quiet; then
      log "$repo already up to date, nothing to commit."
      UNCHANGED+=("$label")
      continue
    fi

    git -C "$dest" commit -m "$COMMIT_MESSAGE" -q

    pushd "$dest" >/dev/null

    if [[ $USE_GH -eq 1 ]]; then
      if git push origin "HEAD:$branch" -q 2>/dev/null; then
        log "Pushed update to $repo."
        UPDATED+=("$label")
      else
        warn "Push failed for $repo."
        FAILED+=("$label")
      fi
    else
      git remote set-url origin "$(clone_url "$GITHUB_OWNER" "$repo")"
      if git push origin "HEAD:$branch" -q 2>/dev/null; then
        log "Pushed update to $repo."
        UPDATED+=("$label")
      else
        warn "Push failed for $repo."
        FAILED+=("$label")
      fi
    fi

    popd >/dev/null
  done

done

echo
log "Done."
echo "Updated:   ${#UPDATED[@]}  ${UPDATED[*]:-}"
echo "Unchanged: ${#UNCHANGED[@]}  ${UNCHANGED[*]:-}"
echo "Skipped:   ${#SKIPPED[@]}  ${SKIPPED[*]:-}"
echo "Failed:    ${#FAILED[@]}  ${FAILED[*]:-}"
