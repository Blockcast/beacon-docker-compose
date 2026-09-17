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

cd "$(dirname "$0")/.." || exit 1

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
# Every name here must be a profile some manifest actually declares -- see the
# bidirectional coverage guard below for why.
OPERATOR_ONLY=(luks relay)

# Sets known to be broken on main, each pinned to the issue tracking the fix.
# This list is asserted in BOTH directions: an entry that starts passing fails
# the run just as loudly as a passing set that breaks. That is what stops it
# silently becoming a permanent allowlist.
#
# MECHANISM, so the pin is actionable rather than just a label: the `multicast`
# PROFILE activates relay-caddy (profiles: [caddy, multicast]), not the
# multicast service -- that already runs under `managed` via x-managed. So on an
# ats/varnish backend the profile adds a SECOND cache backend, and all three
# inherit x-relay-cache, so they collide on `container_name: relay` and on
# ports 80/443: `services.relay: container name "relay" is already in use`.
# Both sets are gateway-reachable (getCDNConfig defaults to "ats").
declare -A EXPECTED_FAIL=(
  ["managed ats multicast"]="BLO-34364"
  ["managed varnish multicast"]="BLO-34364"
)

# --- Coverage guard ---------------------------------------------------------
# Enumerate the profiles the manifests actually declare and assert the matrix
# above names exactly that set, in BOTH directions.
#
# `config --profiles` is compose's own YAML-aware answer. The hand-rolled scan
# this replaces read six lines past every `profiles:` key and swept up list
# items from whatever block followed, so `depends_on: - blockcastd` at
# docker-compose.relay.yml:85-86 put `blockcastd` -- a service, never a profile
# -- into the declared set. Any `depends_on` neighbouring a `profiles:` key
# could fail this lane red without touching a profile at all.
if ! declared_raw=$(docker compose "${FILES[@]}" config --profiles 2>&1); then
  echo "FAIL  'docker compose config --profiles' failed, so matrix coverage"
  echo "      cannot be verified. Manifests may not parse at all:"
  echo "      $(head -1 <<<"$declared_raw")"
  exit 1
fi
mapfile -t DECLARED < <(grep -E '^[a-z0-9_-]+$' <<<"$declared_raw" | sort -u)

mapfile -t KNOWN < <(printf '%s\n' "${REACHABLE[@]}" "${OPERATOR_ONLY[@]}" \
  | tr ' ' '\n' | grep -E '^[a-z0-9_-]+$' | sort -u)
rc=0

# Declared but untested: a new profile nobody wired into the matrix.
for p in "${DECLARED[@]}"; do
  if ! printf '%s\n' "${KNOWN[@]}" | grep -qx "$p"; then
    echo "FAIL  profile '$p' is declared in a manifest but is in neither REACHABLE"
    echo "      nor OPERATOR_ONLY. Decide which it is and add it, so it gets tested."
    rc=1
  fi
done

# Tested but undeclared: asserts nothing, and looks exactly like coverage.
# compose accepts an unknown --profile silently and just resolves the no-profile
# baseline, so `--profile blockcastd` was byte-identical to
# `--profile zzz-does-not-exist`. Without this direction such an entry is
# invisible by construction.
for p in "${KNOWN[@]}"; do
  if ! printf '%s\n' "${DECLARED[@]}" | grep -qx "$p"; then
    echo "FAIL  '$p' is in the matrix but no manifest declares it as a profile."
    echo "      compose resolves an unknown --profile to the baseline without"
    echo "      erroring, so this entry tests nothing. Remove it, or declare it."
    rc=1
  fi
done

# --- Run --------------------------------------------------------------------
check() { # check <label>   -- label is a space-separated profile set
  local label="$1"
  local args=() p parts=()
  # Split the label here rather than relying on the caller passing $set
  # unquoted. compose ignores an unknown --profile silently and just resolves
  # the no-profile baseline, so a set that fails to split into separate flags
  # becomes one bogus profile, parses cleanly, and reports `ok` for a
  # combination that was never tested. Keeping the split inside one function
  # under a known IFS makes that unrepresentable.
  read -ra parts <<<"$label"
  for p in "${parts[@]}"; do
    if ! printf '%s\n' "${DECLARED[@]}" | grep -qx "$p"; then
      echo "FAIL  [$label] '$p' is not a profile any manifest declares, so compose"
      echo "      would ignore it and silently test the baseline instead."
      return 1
    fi
    args+=(--profile "$p")
  done

  local err; err=$(docker compose -p "$PROJECT" "${FILES[@]}" "${args[@]}" config 2>&1 >/dev/null)
  local got=$?
  local first; first=$(grep -v '^level=warning' <<<"$err" | head -1)
  local want="${EXPECTED_FAIL[$label]:-}"

  if [[ -n "$want" ]]; then
    if (( got == 0 )); then
      echo "FAIL  [$label] now resolves, but is pinned as broken under $want."
      echo "      Confirm the mechanism is actually gone before editing the pin:"
      echo "      both pinned sets fail on two cache backends colliding over"
      echo "      container_name 'relay'. If that is genuinely fixed, remove the"
      echo "      entry from EXPECTED_FAIL. If instead this set resolved to the"
      echo "      no-profile baseline, the profile names are not reaching compose"
      echo "      -- compose ignores an unknown --profile silently."
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

echo "compose: $(docker compose version 2>&1 | head -1)"
echo
echo "== gateway-reachable profile sets =="
for set in "${REACHABLE[@]}"; do
  check "$set" || rc=1
done

echo
echo "== operator-only profiles (standalone) =="
for p in "${OPERATOR_ONLY[@]}"; do
  check "$p" || rc=1
done

echo
(( rc == 0 )) && echo "PASS  all profile sets resolve as expected" \
              || echo "FAIL  see above"
exit $rc
