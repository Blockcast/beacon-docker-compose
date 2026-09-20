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

# Fail closed: the restart-policy audit below is jq-only, and a missing jq would
# otherwise skip it silently while the lane stayed green.
command -v jq >/dev/null || { echo "FAIL  jq is required by the restart-policy audit"; exit 1; }

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
# compose's own accepted profile-name shape. A tighter filter drops legal names:
# `^[a-z0-9_-]+$` silently swallowed anything carrying a dot or an uppercase
# letter, so a profile named `Dev.Local_1` never reached DECLARED and neither
# direction of the coverage guard could fire on it -- the same
# invisible-by-construction hole this guard exists to close, one layer down.
PROFILE_RE='^[a-zA-Z0-9][a-zA-Z0-9_.-]*$'
mapfile -t DECLARED < <(grep -E "$PROFILE_RE" <<<"$declared_raw" | sort -u)

mapfile -t KNOWN < <(printf '%s\n' "${REACHABLE[@]}" "${OPERATOR_ONLY[@]}" \
  | tr ' ' '\n' | grep -E "$PROFILE_RE" | sort -u)
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

# --- Restart-policy audit ---------------------------------------------------
# Two hazards `docker compose config` resolves CLEANLY, so rc alone sees
# neither. Both live in getRestartPolicy (docker/compose pkg/compose/create.go):
#
#  1. `attempts, _ = strconv.Atoi(num)` DISCARDS the parse error, so a typo'd
#     count (`on-failure:l3`, or a trailing space) -- and a bare `on-failure` --
#     reaches the daemon as MaximumRetryCount 0, which Docker reads as
#     UNLIMITED. One character removes the bound with every layer green. That is
#     the retry storm BLO-29773 bounded cache-init at 13 to prevent: a
#     persistent RKS 403 would then cost unlimited fetchKey attempts per gateway
#     per hour, fleet-wide.
#  2. a `deploy.restart_policy` block is a plain ASSIGNMENT over whatever
#     `restart:` produced -- not a merge, no warning. The resolved config still
#     prints the `restart:` value while the daemon applies the deploy block, so
#     reading `.restart` alone stays green straight through it.
#
# Asserted over every service in each resolving set rather than pinned to one,
# so a service added later inherits the check instead of needing to be listed.
restart_audit() { # restart_audit <label>   -- resolved JSON on stdin
  jq -r --arg label "$1" '
    .services // {} | to_entries[]
    | .key as $svc | (.value.restart // "") as $r
    | if ($r | startswith("on-failure")) and (($r | test("^on-failure:[1-9][0-9]*$")) | not)
      then "FAIL  [\($label)] \($svc): restart \"\($r)\" has no bounded retry count.\n      compose discards the count parse error, so this reaches the daemon as\n      MaximumRetryCount 0 -- unlimited. Write on-failure:<N>."
      elif ($r != "") and (.value.deploy.restart_policy != null)
      then "FAIL  [\($label)] \($svc): declares both restart and deploy.restart_policy.\n      The deploy block silently overwrites restart:, so the policy printed by\n      `config` is not the one the daemon applies. Keep exactly one."
      else empty
      end'
}

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

  # Fail closed on the json call too. Piping it straight into jq would let a
  # failure arrive as empty input, which `restart_audit` reports as "nothing to
  # flag" -- the audit would go silent rather than red, which is the same
  # invisible-by-construction hole the jq guard at the top of this file closes
  # one call up. The YAML rc check above does not cover this: the two
  # formatters do not always agree on rc for one project.
  local resolved audit
  if ! resolved=$(docker compose -p "$PROJECT" "${FILES[@]}" "${args[@]}" config --format json 2>&1); then
    echo "FAIL  [$label] restart-policy audit could not resolve the project as json:"
    echo "      $(head -1 <<<"$resolved")"
    return 1
  fi
  audit=$(restart_audit "$label" <<<"$resolved")
  if [[ -n "$audit" ]]; then
    printf '%b\n' "$audit"
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
