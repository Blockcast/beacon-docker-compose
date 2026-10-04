# AGENTS.md — Blockcast/beacon-docker-compose

## `main` is the fleet's live fetch path

magma's `compose_manager` pulls **both** manifests straight from
`refs/heads/main` and reconciles **hourly** (`COMPOSE_CHECK_INTERVAL = 1h`):

- `orc8r/gateway/go/services/magmad/compose_manager/manager.go:59` —
  `COMPOSE_REMOTE_DEFAULT = ".../refs/heads/main/docker-compose.yml"`
- `:338` — `docker-compose.relay.yml` is derived from the **same directory**,
  so it ships from `refs/heads/main` too.

There is no tag, no channel, no pinned ref and no staged rollout between a
merge here and every enrolled gateway. A manifest that does not parse does not
break one service — it stops the gateway reconciling at all, because every
compose verb fails on it.

## What `main` enforces

Read 2026-10-04. Re-read before relying on it; protection settings drift. Two
rows are agent-readable and three are not — the last column says which, because
an unreadable row re-reads as *absent*, not as its value.

```
gh api repos/Blockcast/beacon-docker-compose/branches/main \
  --jq '{p:.protected, c:.protection.required_status_checks.contexts,
         e:.protection.required_status_checks.enforcement_level}'
# -> {"p":true,"c":["config"],"e":"non_admins"}
```

| setting | value | re-read |
|---|---|---|
| `required_status_checks.contexts` | `["config"]` | **live**, above |
| `enforce_admins` | `false` | **live**, above — `enforcement_level: "non_admins"` is the legacy spelling of it |
| `strict` (branch must be up to date with `main`) | `true` | not agent-readable; symptom is `mergeable_state: behind` on a PR |
| `required_pull_request_reviews` | `null` | not agent-readable; corroborated by `reviewDecision: ""` with zero approvals on a `clean` PR |
| force pushes / deletions | off | not agent-readable |

⚠ **The three unreadable rows live only on `branches/main/protection`, which is
`403 Resource not accessible by integration` to the App token** — and the merge
seat is not mounted in an agent pod (`/paperclip/.secrets/github-merge-token/`
is an empty directory), so no agent credential reaches them. `branches/main`
returns a *reduced* shape where those keys are **absent**, so
`--jq .protection.required_status_checks.strict` yields `null`, not `false`.
**That null is not drift.** Their values here are the operator's `PUT`
read-back recorded on BLO-34938 (2026-10-03T21:5xZ); re-reading them needs the
operator/admin token.

`config` is the job name in `.github/workflows/compose-validate.yml`. The
required context **is** that job name, and the coupling fails closed and
silent: rename the job and the required context never reports again, so every
PR sits `pending` forever with no failing run to point at. Rename only
together with the protection setting. The job runs
`scripts/validate-compose.sh`, which resolves the manifests against every
profile set `computeProfilesWithBackend()` can emit — not one profile at a
time, which asserts a configuration the gateway never deploys.

⚠ **Read `branches/main`, not `rules/branches/main`.** This is *classic*
branch protection, so the ruleset endpoints are blind to it: both
`rules/branches/main` and `rulesets` return `[]` on this repo **while it is
gated**. An empty read there is not evidence in either direction, and it is
not a permissions artifact. `.protected` is the discriminating surface.

## Landing posture

**An agent may merge its own PR here** once `config` is green at the exact head
and the branch is up to date with `main`. No distinct reviewer is required,
because `main` does not require one — `required_pull_request_reviews: null` is
the protection spec that was approved and applied, not an oversight.

Two things that does **not** license:

- **Merging past a `config` that is not green.** `enforce_admins: false` means
  an admin token mechanically can; no agent identity may. `pending`, `failure`
  and *absent* are all stops, not waits to be stepped over.
- **Skipping the review.** Read Ally's review at the exact head and address
  Critical/Important findings before merging. `config` is a syntactic floor —
  it proves the manifests resolve, not that the change is right.

Provenance: BLO-34239 (the gate), BLO-34938 (the protection change),
BLO-39569 (its approval).
