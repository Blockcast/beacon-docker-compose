#!/usr/bin/env bash
#
# Validates that this repo's compose manifests resolve for every profile set the
# gateway can actually ask for.
#
# WHY THIS EXISTS: main is the fleet's live fetch path. magma's compose_manager
# pulls docker-compose.yml and docker-compose.relay.yml straight from
# refs/heads/main and reconciles hourly, so an unparseable manifest reaches every
# enrolled gateway with nothing in between. See BLO-34239.
#
# WHY THE MATRIX LOOKS LIKE THIS: the gateway never invokes a single profile
# standalone. magma orc8r/gateway/go/services/magmad/compose_manager/manager.go
# computeProfilesWithBackend() always seeds ["managed"], then appends the cache
# backend when relay is enabled and "multicast" when the standalone multicast
# service is enabled. Testing profiles one at a time asserts a configuration
# that is never deployed, and misses the ones that are.
#
# Runs anywhere with the docker CLI + compose v2 plugin. `config` is parse-only
# and never dials the daemon, so no Docker daemon is required.
#
# Usage: scripts/validate-compose.sh
set -uo pipefail

cd "$(dirname "$0")/.."

FILES=(-f docker-compose.yml -f docker-compose.relay.yml)

# Pinned project name. `docker compose config` otherwise derives it from the
# working directory and emits it into the resolved output, which makes any
# before/after comparison show a spurious diff on every profile.
PROJECT=beacon-compose-validate

# --- The matrix -------------------------------------------------------------
# Profile sets computeProfilesWithBackend() can emit. "managed" is always
# present. Backend is one of ats/varnish/caddy (getCDNConfig defaults to "ats").
# [managed caddy multicast] is not reachable today -- getEnabledServices drops
# multicast when the backend is caddy -- but it is cheap to hold the line on.
REACHABLE=(
  "managed"
  "managed multicast"
  "managed ats"
  "managed varnish"
  "managed caddy"
  "managed ats multicast"
  "managed varnish multicast"
  "managed caddy multicast"
)

# Profiles the gateway never computes, reachable only by an operator running
# compose by hand. Checked standalone so they cannot rot unnoticed.
OPERATOR_ONLY=(luks blockcastd relay)

# Sets known to be broken on main, each pinned to the issue tracking the fix.
# This list is asserted in BOTH directions: an entry that starts passing fails
# the run just as loudly as a passing set that breaks. That is what stops it
# silently becoming a permanent allowlist.
declare -A EXPECTED_FAIL=(
  ["managed ats multicast"]="BLO-34239"
  ["managed varnish multicast"]="BLO-34239"
)

# --- Coverage guard ---------------------------------------------------------
# Enumerate the profiles actually declared in the manifests and fail on any this
# script does not know about. A hand-maintained list goes stale silently, and
# the gap is invisible precisely where it matters.
mapfile -t DECLARED < <(
  grep -hA6 '^\s*profiles:' docker-compose*.yml \
    | grep -oE '^\s*-\s+[a-z0-9_-]+' | awk '{print $2}' | sort -u
)
# profiles: [managed] inline-list form is not matched by the block scan above.
mapfile -t DECLARED_INLINE < <(
  grep -hoE '^\s*profiles:\s*\[[^]]+\]' docker-compose*.yml \
    | sed -E 's/.*\[//; s/\]//; s/,/ /g' | tr ' ' '\n' | grep -E '^[a-z0-9_-]+$' | sort -u
)
DECLARED+=("${DECLARED_INLINE[@]}")
mapfile -t DECLARED < <(printf '%s\n' "${DECLARED[@]}" | sort -u)

KNOWN=$(printf '%s\n' "${REACHABLE[@]}" "${OPERATOR_ONLY[@]}" | tr ' ' '\n' | sort -u)
rc=0
for p in "${DECLARED[@]}"; do
  if ! grep -qx "$p" <<<"$KNOWN"; then
    echo "FAIL  profile '$p' is declared in a manifest but is not in REACHABLE or"
    echo "      OPERATOR_ONLY. Decide which it is and add it, so it gets tested."
    rc=1
  fi
done

# --- Run --------------------------------------------------------------------
check() { # check <label> <profile...>
  local label="$1"; shift
  local args=() p
  for p in "$@"; do args+=(--profile "$p"); done

  local err; err=$(docker compose -p "$PROJECT" "${FILES[@]}" "${args[@]}" config 2>&1 >/dev/null)
  local got=$?
  local first; first=$(grep -v '^level=warning' <<<"$err" | head -1)
  local want="${EXPECTED_FAIL[$label]:-}"

  if [[ -n "$want" ]]; then
    if (( got == 0 )); then
      echo "FAIL  [$label] now resolves, but is pinned as broken under $want."
      echo "      The fix landed -- remove it from EXPECTED_FAIL in this script."
      return 1
    fi
    echo "known [$label] rc=$got (tracked by $want): $first"
    return 0
  fi

  if (( got != 0 )); then
    echo "FAIL  [$label] rc=$got: $first"
    return 1
  fi
  echo "ok    [$label]"
}

echo "== gateway-reachable profile sets =="
for set in "${REACHABLE[@]}"; do
  check "$set" $set || rc=1
done

echo
echo "== operator-only profiles (standalone) =="
for p in "${OPERATOR_ONLY[@]}"; do
  check "$p" "$p" || rc=1
done

echo
(( rc == 0 )) && echo "PASS  all profile sets resolve as expected" \
              || echo "FAIL  see above"
exit $rc
