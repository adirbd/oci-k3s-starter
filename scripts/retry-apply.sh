#!/usr/bin/env bash
# Keep asking Oracle for the instance until a machine is free.
#
# WHY THIS EXISTS. `LaunchInstance` answering
#
#     500-InternalError, Out of host capacity
#
# is the NORMAL first answer when you ask for a free Ampere A1. It is transient and
# unpredictable — it can clear in minutes or take a day — and Oracle offers no queue, no
# reservation and no notification. The only mechanism available is asking again. Telling
# you to "retry every few minutes" and leaving you to do it by hand is not a plan.
#
# Everything except the instance is created on the first apply and stays in state, so each
# attempt here is a single LaunchInstance call.
#
# ── IT ROTATES AVAILABILITY *AND* FAULT DOMAINS, WHICH IS THE POINT ──────────────────
# Capacity is tracked per availability domain AND per fault domain. Retrying the same
# spot is asking the same full rack over and over; asking somewhere else is a genuinely
# different question. Each attempt cycles the fault domain (starting with "let Oracle
# pick", the best first ask), and every full cycle advances the AD index. In a 1-AD
# region — many home regions — the AD index wraps to the same AD every time, and the
# fault domain is the ONLY axis a retry can actually vary.
#
# ── ON RATE LIMITING ─────────────────────────────────────────────────────────────────
# Oracle throttles LaunchInstance deliberately, to discourage exactly this kind of polling,
# and answers 429 when you cross the line. Three things keep this on the right side:
#   1. A 5-minute default (12 requests/hour). Community scripts poll every 60s; there is no
#      prize for being fast, and being rude gets you throttled rather than served.
#   2. ONE API call per attempt — no `tofu plan` in between, which would double the request
#      rate against the very API being throttled.
#   3. Exponential backoff on 429 SPECIFICALLY. A capacity failure and a throttle failure
#      are not the same thing and must not be retried at the same cadence.
#
# ── USAGE ────────────────────────────────────────────────────────────────────────────
#   ./scripts/retry-apply.sh                   # every 5 minutes, rotating ADs, forever
#   INTERVAL=600 ./scripts/retry-apply.sh      # gentler
#   MAX_ATTEMPTS=20 ./scripts/retry-apply.sh   # give up eventually
#   ./scripts/retry-apply.sh -var ocpus=1 -var memory_gb=6    # escalate: ask for less
#
# Asking for a smaller shape genuinely helps — a 1-core box fits where a 2-core one does
# not. Extra arguments pass straight through to `tofu apply`.
set -uo pipefail

INTERVAL="${INTERVAL:-300}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"   # 0 = forever
TF="${TF:-tofu}"; command -v "$TF" >/dev/null 2>&1 || TF=terraform

cd "$(dirname "$0")/../terraform" || exit 1

attempt=0
throttle_backoff="$INTERVAL"
# API names, NOT the console's "FD-1" labels — those return 400-InvalidParameter.
# The empty first entry means "let Oracle choose", which is the best first ask.
FAULT_DOMAINS=("" FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3)

while :; do
    idx=$attempt
    attempt=$((attempt + 1))
    fd="${FAULT_DOMAINS[$((idx % 4))]}"
    ad=$(( (idx / 4) % 3 ))         # a full FD cycle per AD; both wrap, so any region works

    echo "── attempt $attempt (AD index $ad, fault domain ${fd:-oracle-picks}) — $(date '+%H:%M:%S')"

    out=$("$TF" apply -auto-approve -input=false \
            -var "availability_domain_index=$ad" -var "fault_domain=$fd" "$@" 2>&1)
    rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "$out" | tail -20
        echo
        echo "✅ instance created on attempt $attempt."
        echo "   Next: ./scripts/connect.sh   (it may take a few minutes for k3s to be ready)"
        exit 0
    fi

    # Oracle says the same thing two ways: a clean OutOfHostCapacity, or a generic
    # InternalError whose message merely reads "Out of host capacity". Matching only the
    # tidy one would abort on a failure that is entirely retryable.
    if echo "$out" | grep -qiE "out of host capacity|OutOfHostCapacity"; then
        echo "   no capacity there — retrying in ${INTERVAL}s"
        throttle_backoff="$INTERVAL"
        sleep "$INTERVAL"
    elif echo "$out" | grep -qiE "429|TooManyRequests|rate limit"; then
        throttle_backoff=$(( throttle_backoff * 2 ))
        [ "$throttle_backoff" -gt 3600 ] && throttle_backoff=3600
        echo "   ⚠ throttled by Oracle — backing off ${throttle_backoff}s"
        sleep "$throttle_backoff"
    else
        # Anything else is a real problem: a bad variable, an expired session, a policy.
        # Retrying would bury it.
        echo
        echo "❌ this is not a capacity failure — stopping so you can read it:"
        # The Error block, not the last 30 lines of a plan — the signal, not the scroll.
        echo "$out" | grep -A5 -iE '^│ Error:|Error:' || echo "$out" | tail -30
        exit "$rc"
    fi

    if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "reached MAX_ATTEMPTS=$MAX_ATTEMPTS without success."
        exit 1
    fi
done
