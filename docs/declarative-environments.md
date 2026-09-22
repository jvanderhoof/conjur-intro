# Declarative Environments — design

**Status:** Partly implemented. The walking skeleton — schema, validation, `--plan`,
single-leader provisioning, verification and fast tests — is in place. Standbys,
auto-failover, followers, the leader-hardening flags, the guard rails and the
`conjur-env` skill are not. `bin/env` refuses the topology it cannot build rather
than provisioning something smaller.
**Date:** 2026-09-22
**Scope:** Proof of concept. End-to-end first; robustness in later passes.

## Goal

Bring a declarative element to `conjur-intro` so a Conjur configuration can be
described once, provisioned reproducibly, and replicated later — and put a skill on
top of it that turns a customer's prose description (from a support escalation) into
that description.

The primary use is **reproducing a customer issue locally**. The bar is therefore
"close enough to reproduce," with the dimensions implicated in the bug exact. This is
not a fidelity exercise for its own sake.

Two deliverables, in order:

1. A declarative environment spec plus `bin/env` in this repo — deterministic, no LLM
   involved, useful to anyone using `conjur-intro`.
2. A `conjur-env` skill that translates customer prose into a spec and hands off to
   `bin/env`.

The split is deliberate. Orchestration knowledge (what order to run `evoke` in, what
depends on what) is deterministic and testable, and belongs in code rather than in
skill prose. Translating a customer's words into a topology is what an LLM is good at,
and is small enough to keep honest.

---

## Deliverable 1 — declarative layer

### Files

| Path | Tracked? | Purpose |
|---|---|---|
| `environments/schema.json` | yes | The contract. `additionalProperties: false`, so an unsupported or typo'd key is a hard error rather than a silent no-op. Cross-field constraints live here. |
| `environments/examples/*.yml` | yes | Sanitized specs (single-node, HA-with-auto-failover, later multi-follower). Double as documentation and as test fixtures. |
| `environments/*.yml` | **no — gitignored** | Real customer specs. |
| `bin/env` | yes | The entrypoint. |
| `artifacts/env-validator/` | yes | The pinned container that converts YAML to JSON and applies the schema. |
| `test/env.bats` | yes | Plan-output and validation tests. |
| `bin/env-test` | yes | Runs `test/env.bats` in a container, so bats is not a host dependency. |

`environments/` is gitignored because **this repo is mirrored to the public
`conjurdemos` GitHub org** (see `Jenkinsfile`). Customer appliance hostnames, customer
names in filenames, and admin passwords copied from tickets must never be tracked.
Only the schema and the sanitized examples are.

### The spec — pass 1

```yaml
version: "13.5"          # quoted: unquoted 13.10 is the YAML number 13.1
leader:
  standbys: 2            # 0-4
  auto_failover: true    # requires standbys >= 2
  master_key_encryption: true
  custom_certificates: true
  generate_dh: false
followers: 1             # 0 or 1 in pass 1
sample_data: true        # default; runs bin/api --load-sample-policy-and-values

# events: []             # reserved seam, not implemented
```

The version is a string, not a number. YAML reads `13.5` as a float, and would
silently turn `13.10` into `13.1` — the wrong appliance, provisioned without
complaint, which is the one outcome a repro tool cannot afford. The schema
requires a string and the error names the fix.

Each field enters the schema as it becomes buildable, so that
`additionalProperties: false` keeps meaning "this is supported". Today that is
`version`, `leader.standbys`, `leader.auto_failover`, `followers`, `sample_data`
and the reserved `events`; the three leader-hardening flags arrive with the
ticket that wires them up.

**End state only.** The spec describes a topology, not how the customer got there.

The `events:` seam is reserved and documented as unimplemented. A large share of real
escalations are about *transitions* — "we upgraded 13.2 → 13.5 and failover stopped
working", "we promoted a standby and the follower never caught up" — and a pure
end-state document cannot express them. `bin/dap` already models these as discrete
actions (`--upgrade-master`, `--trigger-failover`, `--promote-standby`,
`--reenroll-failed-leader`). Reserving the key now means adding them later is an
extension rather than a breaking redesign. Until then the skill reports them as gaps
to run by hand.

`sample_data` defaults to `true`: without policy and secrets loaded there is nothing
to reproduce a secret-retrieval issue against, so an empty appliance is rarely what
you want.

### `bin/env`

Bash, consistent with the rest of `bin/`. YAML→JSON conversion **and** JSON Schema
validation happen in a single pinned-container pass, so there is no new host
dependency; `jq` reads the resulting JSON. Validation failures name the offending
pointer and abort before anything is provisioned.

| Behavior | Shipped? | Detail |
|---|---|---|
| `--plan` | yes | Prints the ordered command sequence without executing. |
| Preflight | no | The requested appliance tag resolves in `registry.tld`; required host ports are free. Fails in seconds rather than six minutes into a run. |
| Provision | yes | Sequences existing `bin/dap` / `bin/api` flags in dependency order. |
| Verify | yes | Probes `/health`, `/info`, replication and cluster state; prints a desired-vs-actual table; exits non-zero on mismatch. |
| Re-run | no | **No convergence.** If anything is running, refuse and direct the user to `--recreate`. |
| `--recreate` | no | Tears down and rebuilds, stating plainly that volumes (seeds, MKE key, audit data) are destroyed. |
| Podman | no | **Unsupported.** Refuses with a message pointing at `bin/podman-dap`. |

Verification compares the *requested* image tag against the tag the leader
container is actually running, rather than the appliance's self-reported build.
That way a symbolic tag like `5.0-stable` verifies as cleanly as a pinned one,
while a stale container left behind by an earlier run still shows up as a
mismatch. It also reads back one of the sample variables, because "the appliance
is up" and "the appliance is usable for a repro" are different claims.

Podman is out because `bin/podman-dap` is a drifted fork of `bin/dap` — no
`--standby-count` (it hardcodes 5 standbys), no MKE, no Keycloak, no k8s paths,
different host ports, and raw `podman run` instead of compose. A declarative layer
over it would misrepresent what it can actually build, and a `bin/podman-env` would
be a third copy of the same logic.

No convergence for a related reason: appliance provisioning is largely
non-idempotent, and per-dimension state detection is where a reconciler goes subtly
wrong. Rebuild-from-clean needs none of it, and matches how repro work actually goes.

### Testing

`test/env.bats` asserts the `--plan` output for every tracked example spec, plus the
validation failures. Run it with `bin/env-test`. It takes about nine seconds, starts
no appliance containers and never touches `registry.tld`, so it can genuinely run in
CI — unlike the existing cucumber suite, which `ci/bin/end-to-end-tests` can drive
but which the `Jenkinsfile` never invokes.

It is not container-*free*: the spec validator is a container by design, so the
tests build and run that one small image, and `bin/env-test` runs bats itself in a
container so bats is not a host dependency. Neither needs anything beyond the
docker daemon the repo already requires.

Integration testing stays a manual run against a real appliance, as today. The one
part of verification the fast tests can reach is its failure side: against a
stopped environment every dimension must report a mismatch rather than crash or
pass, which `bin/env` exposes by being sourceable.

`--plan` therefore serves two needs at once: it is what makes the
spec→sequence translation testable, and it is what the skill shows before provisioning.

### Pass 2 — first increment

`followers: 2..N`. Requires new compose services, generated follower haproxy backend
lines, and moving `files/haproxy/follower/haproxy.cfg` to the generated-and-gitignored
side — the master equivalent is already handled that way.

This is deliberately *not* in pass 1. It is the only item in scope needing new compose
services rather than sequencing existing flags, and separating it keeps the PoC's
riskiest question (does the whole chain hold together?) apart from its fiddliest one
(compose services, haproxy generation, the shared `follower-certs` volume).

---

## Deliverable 2 — the `conjur-env` skill

Lives at `.claude/skills/conjur-env/`, tracked. It ships to the public mirror too,
which is fine: it holds no customer data.

- **Input:** pasted prose, or a path to a local file. No Jira fetch in the PoC.
- **Knowledge:** a vendored `reference/` distilled from `product-knowledge-base` — a
  customer-vocabulary → spec-field table drawn from `overview.md`, `follower.md`,
  `operations.md` and `system-requirements.md`. Self-contained, with no path
  dependency on a KB clone that only exists on one machine. Hard constraints belong in
  the schema, not in prose.
- **Flow:**
  1. Read the description.
  2. **Ask about every dimension the description does not state.** No silent defaults.
  3. Write a validated spec to `environments/`.
  4. **One gate**, showing: the derived spec; the dimensions it could not express;
     `bin/env --plan`; and, if an environment is already running, what `--recreate`
     will destroy.
  5. On a clear yes, provision and report the verification table.

**Gaps are reported, never faked.** Anything outside the spec — authn-ldap, a DR node,
a non-`demo` account, a specific admin password, custom hostnames, a described upgrade
— is named explicitly as "set up by hand," never bent into a supported field. The
schema's `additionalProperties: false` means an invented key fails loudly rather than
passing quietly.

---

## Non-goals for the PoC

Authenticators of any kind, including the Keycloak OIDC and kind-based `authn-jwt`
paths that already exist in `bin/dap`; account name, admin password and hostnames (all
currently hardcoded to `demo` / `MySecretP@ss1` / `*.mycompany.local`, including in the
CLI containers); DR nodes (present in `demos/cluster/bin/start`, never ported to
`bin/dap`); convergence; event sequences; Podman; and exporting a running environment
back into a spec.

---

## Known debt and open items

1. **Schema defaults vs. skill questions.** The schema defines defaults so a
   hand-written spec is usable, but the skill never relies on them — it asks instead,
   so every spec it writes is complete. These two facts must stay consistent as fields
   are added, or a hand-written spec and a skill-written one will behave differently.
2. **A third copy of ordering knowledge.** `bin/env` duplicates sequencing that
   `ci/providers/docker_compose.rb` already encodes, which itself duplicates
   `bin/dap`. The PoC knowingly adds a third copy. Recording it here so it is known
   debt rather than a later discovery. Consolidation is its own piece of work.
3. **The cucumber suite is not in CI.** `Jenkinsfile` runs only
   `bin/upgrade-test FROM TO`. Wiring `ci/bin/end-to-end-tests` in is a separate
   effort, and until it happens there is no automated integration coverage of
   provisioning at all.

---

## Decision log

| Decision | Chosen | Why |
|---|---|---|
| Primary job | Reproduce a customer issue | Sets "close enough to repro" as the fidelity bar. |
| Mutation limit for the skill | Compose flags, untracked overlays, raw `evoke` when no flag fits — never edit a tracked file | Keeps `git status` clean and the environment reproducible from the spec. |
| Declarative layer | In scope, and shipped first | Puts orchestration where it can be tested; gives a replication mechanism independent of any AI. |
| Spec shape | End state now, `events:` seam reserved | Shippable pass 1 without foreclosing transitions. |
| Re-run behavior | Clean rebuild behind a destructive gate | No per-dimension state detection against a non-idempotent appliance. |
| Pass-1 scope | Core topology (existing flags) + `sample_data` | Cheap, high value, proves the chain. |
| Spec location | `environments/` gitignored; examples and schema tracked | The repo is publicly mirrored. |
| Implementation | Bash, like the rest of `bin/` | Consistency; no new host dependency. |
| Validation | JSON Schema, enforced in the YAML-conversion container | The schema is the contract, not documentation that drifts. |
| Checks | Preflight plus desired-vs-actual verification | A repro is only useful if the environment really is what the ticket described. |
| Podman | Unsupported, explicitly | Avoids a third fork of drifted provisioning logic. |
| Testing | `--plan` plus bats; integration manual | Tests what will regress, without pretending to cover what CI can't reach. |
| Multi-follower | Pass 2 | Separates the riskiest question from the fiddliest. |
| KB access | Vendored reference | No path dependency on a single machine's clone. |
| Skill gate | One gate: spec, gaps, plan, destruction warning | Folds the destructive confirm into the same decision point. |
| Unstated dimensions | Ask about every one | A repro is worth the extra turns; there are only a handful of fields. |
