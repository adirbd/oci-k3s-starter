#!/usr/bin/env bash
# Catch, in seconds, the things that otherwise fail twenty minutes into an apply.
#
# WHY THIS EXISTS (#14). On a real first run these three landed one after another:
#   1. terraform.tfvars would not parse — the old example suggested file(pathexpand(...)),
#      which is illegal in a .tfvars, and `tofu plan` only says "Function calls not allowed"
#      at the very end.
#   2. Cloudflare Access was not enabled on the account, so the apply built the tunnel, DNS,
#      instance and vault and THEN died with a 403 that reads like a token problem.
#   3. The OCI session had expired, which surfaces as a confusing failure mid-apply.
#
# Each check below fails with a sentence naming the cause and the fix.
#
#   ./scripts/preflight.sh
set -uo pipefail
cd "$(dirname "$0")/../terraform" || exit 1

fail=0
ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=1; }
warn() { printf "  WARN  %s\n" "$1"; }

echo "preflight:"

# ── tools ────────────────────────────────────────────────────────────────────
for t in tofu kubectl oci git; do
    command -v "$t" >/dev/null 2>&1 && ok "$t installed" \
        || bad "$t not found. On Windows, close and reopen your terminal after winget — PATH is only picked up by new shells."
done

# ── the config parses ────────────────────────────────────────────────────────
if [ ! -f terraform.tfvars ]; then
    bad "terraform/terraform.tfvars does not exist. Copy terraform.tfvars.example to it."
else
    out=$(tofu validate -no-color 2>&1)
    if [ $? -eq 0 ]; then
        ok "terraform config and tfvars parse"
    else
        bad "terraform will not parse:"
        echo "$out" | sed 's/^/        /'
        echo "        NOTE: 'Function calls not allowed' means a .tfvars holds literal values"
        echo "        only — paste the SSH key content rather than using file()/pathexpand()."
    fi
fi

# ── the OCI session is alive ─────────────────────────────────────────────────
profile=$(grep -E '^\s*oci_config_profile' terraform.tfvars 2>/dev/null | sed 's/.*=\s*"\(.*\)".*/\1/')
profile="${profile:-DEFAULT}"
if oci session validate --profile "$profile" >/dev/null 2>&1; then
    ok "OCI session for profile '$profile' is valid"
else
    bad "OCI session for profile '$profile' is expired or missing. Fix: oci session refresh --profile $profile (or oci session authenticate). An expired session fails PART WAY through an apply."
fi

# ── Cloudflare Access, only when it is going to be used ──────────────────────
enabled=$(grep -E '^\s*enable_cloudflare\s*=' terraform.tfvars 2>/dev/null | grep -c true)
emails=$(grep -cE '^\s*access_allowed_emails' terraform.tfvars 2>/dev/null)
if [ "${enabled:-0}" -gt 0 ] && [ "${emails:-0}" -gt 0 ]; then
    acct=$(grep -E '^\s*cf_account_id' terraform.tfvars | sed 's/.*=\s*"\(.*\)".*/\1/')
    tok="${TF_VAR_cf_api_token:-$(grep -E '^\s*cf_api_token' terraform.tfvars 2>/dev/null | sed 's/.*=\s*"\(.*\)".*/\1/')}"
    if [ -n "$acct" ] && [ -n "$tok" ]; then
        body=$(curl -s -H "Authorization: Bearer $tok" \
            "https://api.cloudflare.com/client/v4/accounts/$acct/access/apps" 2>/dev/null)
        if echo "$body" | grep -q "not_enabled"; then
            bad "Cloudflare Access is NOT enabled on this account. Terraform cannot switch it on. Enable it once at https://one.dash.cloudflare.com (it asks for a team domain), then apply. Otherwise the apply builds everything else and dies at the Access resources with a 403 that looks like a token problem."
        elif echo "$body" | grep -q '"success":true'; then
            ok "Cloudflare Access is enabled"
        else
            warn "could not confirm Cloudflare Access (token scope, or network). Not blocking."
        fi
    else
        warn "enable_cloudflare is on but cf_account_id / token not readable here — skipping the Access check."
    fi
fi

echo
[ "$fail" -eq 0 ] && echo "ready: tofu apply" || echo "fix the FAIL lines above before applying."
exit "$fail"
