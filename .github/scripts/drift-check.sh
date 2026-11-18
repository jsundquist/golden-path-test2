#!/usr/bin/env bash
# Re-check the settings the golden path sets. Usage: drift-check.sh OWNER/REPO
set -uo pipefail

repo="${1:?usage: drift-check.sh OWNER/REPO}"
failures=0

check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    echo "ok     $1"
  else
    echo "DRIFT  $1 (expected $2, got $3)"
    failures=$((failures + 1))
  fi
}

check_visible() { # like check, but skip when GitHub does not return the field to this token
  if [ "$3" = null ]; then
    echo "skip   $1 (not visible to this token)"
  else
    check "$@"
  fi
}

# Layer 0 and 1: repository settings
r=$(gh api "repos/$repo")
check "wiki off" false "$(jq .has_wiki <<<"$r")"
check "projects off" false "$(jq .has_projects <<<"$r")"
# GitHub returns these four only to a caller with push access, so a read-only token sees null
check_visible "squash merge on" true "$(jq .allow_squash_merge <<<"$r")"
check_visible "merge commits off" false "$(jq .allow_merge_commit <<<"$r")"
check_visible "rebase merge off" false "$(jq .allow_rebase_merge <<<"$r")"
check_visible "delete branch on merge" true "$(jq .delete_branch_on_merge <<<"$r")"

# Layer 3: security features
check "secret scanning" enabled "$(jq -r .security_and_analysis.secret_scanning.status <<<"$r")"
check "push protection" enabled "$(jq -r .security_and_analysis.secret_scanning_push_protection.status <<<"$r")"
check "dependabot security updates" enabled "$(jq -r .security_and_analysis.dependabot_security_updates.status <<<"$r")"
if gh api "repos/$repo/vulnerability-alerts" --silent 2>/dev/null; then
  check "dependabot alerts" on on
else
  check "dependabot alerts" on off
fi
check "private vulnerability reporting" true "$(gh api "repos/$repo/private-vulnerability-reporting" --jq .enabled 2>/dev/null || echo off)"

# Layer 2: Actions settings
check "default token read-only" read "$(gh api "repos/$repo/actions/permissions/workflow" --jq .default_workflow_permissions)"
check "actions cannot approve PRs" false "$(gh api "repos/$repo/actions/permissions/workflow" --jq .can_approve_pull_request_reviews)"
check "actions pinned to SHA" true "$(gh api "repos/$repo/actions/permissions" --jq .sha_pinning_required)"
check "fork PR approval" all_external_contributors "$(gh api "repos/$repo/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy)"

# Layer 1 and 2: the branch ruleset
id=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name=="Protect default branch") | .id')
if [ -z "$id" ]; then
  echo "DRIFT  ruleset 'Protect default branch' (expected present, got missing)"
  failures=$((failures + 1))
else
  rj=$(gh api "repos/$repo/rulesets/$id")
  check "ruleset active" active "$(jq -r .enforcement <<<"$rj")"
  check "no bypass actors" 0 "$(jq '.bypass_actors | length' <<<"$rj")"
  for t in deletion non_fast_forward pull_request required_status_checks; do
    check "ruleset rule: $t" 1 "$(jq --arg t "$t" '[.rules[] | select(.type == $t)] | length' <<<"$rj")"
  done
  check "zero required approvals" 0 "$(jq '[.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count][0]' <<<"$rj")"
  check "squash is the only merge method" '["squash"]' "$(jq -c '[.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods][0]' <<<"$rj")"
  echo "info   required checks: $(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | join(", ")' <<<"$rj")"
fi

# Layer 0: nobody else has access
check "collaborators" 1 "$(gh api "repos/$repo/collaborators" --jq length)"
check "pending invitations" 0 "$(gh api "repos/$repo/invitations" --jq length)"
check "deploy keys" 0 "$(gh api "repos/$repo/keys" --jq length)"
check "webhooks" 0 "$(gh api "repos/$repo/hooks" --jq length)"
echo "info   repo secrets: $(gh api "repos/$repo/actions/secrets" --jq '[.secrets[].name] | join(", ")')"

# Layer 0 to 2: files that must exist
for f in SECURITY.md .github/CODEOWNERS .github/dependabot.yml; do
  if gh api "repos/$repo/contents/$f" --silent 2>/dev/null; then
    check "file $f" present present
  else
    check "file $f" present missing
  fi
done

# 6.3: workflows that stopped running
check "disabled workflows" 0 "$(gh api "repos/$repo/actions/workflows" --jq '[.workflows[] | select(.state != "active")] | length')"

echo
if [ "$failures" -eq 0 ]; then
  echo "No drift."
else
  echo "$failures check(s) drifted."
  exit 1
fi
