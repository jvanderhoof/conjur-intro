# Declarative Environments — design

This is the design record: what was decided, why, and what is deliberately out of
scope. For how to actually use the thing, see
[environments.md](environments.md).

**Status:** Partly implemented. The walking skeleton — schema, validation, `--plan`,
single-leader provisioning, verification and fast tests — is in place, and so are the
guard rails: preflight, the refusal to reconcile, `--recreate`, and the podman
refusal. So are standbys (up to 4) and auto-failover, with the quorum requirement as a
cross-field schema rule. So are up to 3 followers behind a generated load balancer,
with their health and replication checked per follower, a secret read
through the load balancer, and a check that the load balancer routes to every one of
them — pass 2, which has landed. So are the three
leader-hardening flags — master key encryption, custom certificates and generated DH
parameters — each verified off the leader itself. So is the `conjur-env` skill,
measured by an eval against a no-skill baseline rather than by tests. The schema
refuses the topology `bin/env` cannot build rather than letting it provision
something smaller.
**Date:** 2026-09-23
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
| `environments/schema.json` | yes | The contract. `additionalProperties: false`, so an unsupported or typo'd key is a hard error rather than a silent no-op. Range and cross-field constraints live here, never in `bin/env`. |
| `environments/examples/*.yml` | yes | Sanitized specs (single-node, HA-with-auto-failover, leader-and-follower, multiple-followers, hardened). Double as documentation and as test fixtures. |
| `environments/*.yml` | **no — gitignored** | Real customer specs. |
| `bin/env` | yes | The entrypoint. |
| `artifacts/env-validator/` | yes | The pinned container that converts YAML to JSON and applies the schema. |
| `test/env.bats` | yes | Plan-output and validation tests. |
| `bin/env-test` | yes | Runs `test/env.bats` in a container, so bats is not a host dependency. |
| `artifacts/bats/Dockerfile` | yes | The image `bin/env-test` runs the suite in. |
| `.claude/skills/conjur-env/` | yes | The `conjur-env` skill — customer prose to a validated spec — and its evals. |

`environments/` is gitignored because **this repo is mirrored to the public
`conjurdemos` GitHub org** (see `Jenkinsfile`). Customer appliance hostnames, customer
names in filenames, and admin passwords copied from tickets must never be tracked.
Only the schema and the sanitized examples are.

### The spec — pass 1

```yaml
version: "13.5"          # quoted: unquoted 13.10 is the YAML number 13.1
leader:
  standbys: 2            # 0-4, the compose topology's ceiling
  auto_failover: true    # requires standbys >= 2, for an etcd quorum
  master_key_encryption: true   # encrypt the leader's keys before anything is seeded
  custom_certificates: true     # bin/generate-certs' CA; requires standbys <= 2
  generate_dh: false            # the leader generates its own; see known debt
followers: 1             # 0-3, the compose topology's ceiling
sample_data: true        # default; runs bin/api --load-sample-policy-and-values

# events: []             # reserved seam, not implemented
```

The version is a string, not a number. YAML reads `13.5` as a float, and would
silently turn `13.10` into `13.1` — the wrong appliance, provisioned without
complaint, which is the one outcome a repro tool cannot afford. The schema
requires a string and the error names the fix.

Each field enters the schema as it becomes buildable, so that
`additionalProperties: false` keeps meaning "this is supported". Today that is
every field above: `version`, `leader.standbys`, `leader.auto_failover`, the three
leader-hardening booleans, `followers`, `sample_data` and the reserved `events`.

**A field's accepted *range* widens as `bin/env` learns to build it.** In pass 1
`standbys` and `followers` were `maximum: 0` and `auto_failover` was
`const: false`, so a spec asking for a cluster was rejected by the schema rather
than by a conditional in `bin/env`. Every ceiling is now the compose topology's
instead: `standbys` is `0-4`, because `docker-compose.yml` defines
`conjur-master-1` through `conjur-master-5`; `followers` is `0-3`, because it
defines `conjur-follower-1` through `conjur-follower-3` and the follower load
balancer's config is generated with a backend per follower; and `auto_failover` is
a plain boolean. Keeping the
refusal in the schema is what makes "a spec that validates is a spec that can be
provisioned" true, and what makes a hand-written spec fail exactly where a generated
one does. The validator supplies the hint a bare range error cannot — what the
ceiling *is* the schema can say, but not where it comes from or what raising it
would take.

**Cross-field rules live there too.** Auto-failover is an etcd cluster and elects
by majority, so a leader with one standby cannot fail over at all: losing the
leader leaves one node out of two. The requirement of at least 2 standbys is an
`if`/`then` in the schema rather than a check in `bin/env`, which means it fires
before the first standby is seeded, and fires identically for a generated spec. It
surfaces as a bare `minimum of 2` on `/leader/standbys`, so the validator attaches
the hint that explains the quorum — a range error cannot name the field that
caused it.

Custom certificates add the second. The leader certificate `bin/generate-certs`
issues comes from `artifacts/certificate-generator/configuration/dap-master.json`,
which names the leader and `conjur-master-1` through `conjur-master-3` and nothing
else, so a third standby would serve a certificate that does not name it. The rule
is `custom_certificates: true` ⇒ `standbys <= 2`, with a validator hint pointing at
that file. Widening it is a change to the certificate configuration, not to
`bin/env`.

The version is also pattern-constrained to docker's tag grammar, because it
reaches a `bin/dap` command line. A spec file is an input, and no value out of
one should be able to turn into shell syntax or extra arguments; `bin/env`
splits the planned command into an argument vector rather than running it
through `eval`.

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
| `--plan` | yes | Prints the ordered command sequence without executing, preceded by the preflight checks it would run. |
| Preflight | yes | The requested appliance tag resolves — local cache first, then the registry under a 30s ceiling; required host ports are free; no environment already exists. Fails in seconds rather than six minutes into a run. |
| Provision | yes | Sequences existing `bin/dap` / `bin/api` flags in dependency order. |
| Verify | yes | Probes `/health` on the leader and on each follower, `/info` on the leader, standby and follower replication, cluster state, a secret read through both the leader and the follower load balancer, and which followers that load balancer routes to; prints a desired-vs-actual table; exits non-zero on mismatch. |
| Re-run | yes | **No convergence.** If anything exists, refuse and direct the user to `--recreate`. |
| `--recreate` | yes | Tears down and rebuilds, stating plainly that volumes (seeds, MKE key, audit data) are destroyed. |
| Podman | yes | **Unsupported.** Refuses with a message pointing at `bin/podman-dap`. |

Verification compares the *requested* image tag against the tag the leader
container is actually running, rather than the appliance's self-reported build.
That way a symbolic tag like `5.0-stable` verifies as cleanly as a pinned one,
while a stale container left behind by an earlier run still shows up as a
mismatch. It also reads back one of the sample variables, because "the appliance
is up" and "the appliance is usable for a repro" are different claims.

The cluster dimensions follow the same principle: count a thing, then check it is
doing its job. A standby's row is its **replication state** as the leader sees it,
from `pg_stat_replication` under `/health`, because a standby container that is up
but not being streamed to is the failure a container count cannot see. Keyed on
`usename` — the replication role `evoke seed standby <host>` creates, which carries
the hostname exactly — not on `application_name`, which is an opaque
`standby_<hex>_<hex>`. Auto-failover gets a row **per cluster member**, read from
`evoke cluster member list`: `/info` only reports that the leader thinks it is
clustered, whereas the member list is what etcd actually holds, and it names the node
that is missing. The **name** is a third row rather than being left implicit in the
first, because the two probes each answer half of it — `/info` knows the name but not
who joined, the member list knows who joined but not which cluster they are in — and a
row whose DESIRED column reads `production` verifies the name in a way that one
reading `true` only implies.

Each follower gets two rows of its own, numbered as the standbys are, and the tier
gets two more; the split is the point. **Health** is read from each
follower's own port rather than through its load balancer or from the leader: the
leader answers `/health` on the same route with the same shape and answers it `ok`,
so a probe pointed at the wrong port would report a healthy follower whether or not
one exists. **Replication** is read from the follower's own pglogical subscriptions
rather than from the leader's `pg_stat_replication`, which followers have no row in
at all — logical replication is not physical replication with a different host. The
follower's own view wins on two counts: it still answers when the leader is
unreachable, and it distinguishes receiving changes from applying them, where a
follower streaming WAL it cannot apply reads as `streaming` from the leader's side.
There is nothing to key the subscription on and no need to — the name is an
opaque `follower_<hex>_<hex>`, and a follower has exactly its own subscriptions. **Secret read** goes end to end through the follower load balancer,
because it is the only row that authenticates, and because health and replication
are both statements the follower makes about itself. **Backends used** is the
load balancer's own account of which followers it chose, off the `lbtot` column of
its stats page, across twice as many requests through it as there are followers.
The secret read is one request and so one follower, and every follower healthy on
its own port says nothing about whether the load balancer sends it anything — a
backend it never marks up, a certificate it cannot verify say, leaves the tier
serving from fewer followers than it has while every other row passes.

Health and replication are separate rows because they fail separately, and the pair
is what tells the states apart: `evoke seed follower` snapshots the leader's
database, so a follower whose replication stopped right afterwards is up, calls
itself healthy, and serves data that is quietly out of date. The same fact fixes the
provisioning order — the follower goes in *before* the sample data, because a
follower seeded afterwards would serve the sample secret out of its own snapshot and
the retrieval row would pass on a follower that never replicated at all. It goes in
*after* auto-failover enrolment, because `evoke configure follower` installs the
failover rebaser that repoints it at a newly promoted leader.

Podman is out because `bin/podman-dap` is a drifted fork of `bin/dap` — no
`--standby-count` (it hardcodes 5 standbys), no MKE, no Keycloak, no k8s paths,
different host ports, and raw `podman run` instead of compose. A declarative layer
over it would misrepresent what it can actually build, and a `bin/podman-env` would
be a third copy of the same logic.

Podman is detected by string-matching whatever the runtime will say about itself —
`DOCKER_HOST`, `docker version`'s server platform, `docker --version`. There is no
single authoritative field, any one of them naming podman is enough to stop, and the
check must not depend on a daemon being reachable, since an unreachable podman socket
is exactly the case that produces the most confusing failure downstream. It runs for
every invocation including `--plan`: which runtime this is does not depend on the
spec, and a plan podman could never carry out is worse than no plan.

No convergence for a related reason: appliance provisioning is largely
non-idempotent, and per-dimension state detection is where a reconciler goes subtly
wrong. Rebuild-from-clean needs none of it, and matches how repro work actually goes.

**Preflight has no side effects, and `--recreate`'s teardown is therefore a
provisioning command rather than a preflight step.** The ordering that falls out —
every check passes, *then* the first volume is removed — is what keeps a bad tag or a
busy port from leaving an operator with a destroyed environment and no replacement.
It costs one special case: a host port held by one of this project's own containers
is not a conflict, because it is released before the new environment needs it.

The checks run cheapest-first, and the existing-environment check before the port
one: a live environment holds the ports it needs, and "port 443 is in use" is a worse
message than "you already have one of these". `--recreate` itself does not prompt.
The flag is the confirmation, the destruction is stated in words before it happens,
and the skill folds that into its single gate — a second prompt would break both
non-interactive use and that design.

### Testing

`test/env.bats` asserts the `--plan` output for every tracked example spec, plus the
validation failures. Run it with `bin/env-test`. It finishes in about a minute, starts
no appliance containers and never touches `registry.tld`, so it can genuinely run in
CI — unlike the existing cucumber suite, which `ci/bin/end-to-end-tests` can drive
but which the `Jenkinsfile` never invokes. Wiring it into the `Jenkinsfile` is
deliberately left to the separate CI effort noted under known debt.

It is not container-*free*: the spec validator is a container by design, so the
tests build and run that one small image, and `bin/env-test` runs bats itself in a
container so bats is not a host dependency. Neither needs anything beyond the
docker daemon the repo already requires.

Because the tests reach `bin/env`'s own functions, the bats image has to resemble a
host closely enough for them to mean anything. `artifacts/bats/Dockerfile` therefore
installs GNU grep: busybox grep rejects the long options every real host's grep
accepts, and under it a guard rail read as *passing* when what actually happened was
that its `grep` exited 2. Same class of trap on the other side — `_listener_on`
checks for lsof's `(LISTEN)` column rather than trusting lsof's presence, because
busybox's lsof ignores the options and lists every open file, which would name a
random process as the holder of a free port.

The guard-rail tests work by standing in for one seam at a time — `_existing_environment`,
`_port_holder`, `_runtime_identity`, the registry's answer, or `docker` itself where
the point is *which* command gets run. Each stub is written inline in the test that
needs it, so the seam being exercised is visible next to what is asserted about it.
What that buys is the refusal *messages* — which port, which container, which flag to
reach for — since a guard rail that fires with an unhelpful message is barely better
than one that does not fire; and the *ordering*, since a refusal that does not stop
the run is not a guard rail at all, which is why `_build` is a function rather than
four lines of entrypoint. What it does not buy is confidence in the lookups
themselves. Those were checked by hand against a live daemon and registry, bar the
two cheap enough to assert for real: that a free port reads as free, and that a
lookup still reaches its fallback on a host missing the tool it would rather use.

Provisioning a whole environment stays a manual run against a real appliance, as
today. Verification does not: what the fast tests reach is every probe, and its
behaviour against a stopped environment, which `bin/env` exposes by being sourceable.

Stubbing a probe function tests what `_verify` does with an answer, not whether the
probe asks the right question, and the replication probe proved that the hard way: a
filter keyed on `application_name` passed every stubbed test and reported a healthy
two-standby cluster as `not replicating` on the first live run. The fix came with a
test one seam lower — `curl` stubbed, the real probe called, against a body the
appliance actually returned. Where a probe's filter encodes a claim about the
appliance's JSON, that claim belongs in a test with a captured payload behind it;
the payload is the part a stub cannot invent.

So every probe now has one, each at the seam it really has: `curl` for the `/health`
and `/info` reads, `docker` for the image tag and the etcd member list, `bin/api` for
the sample data. The cases they pin are the ones where two answers could be confused
for each other, because those are the ones a wrong filter gets wrong silently — a
leader whose services are fine but whose database is not, a standalone leader versus
an appliance that did not answer with `/info` at all, a registry with a port in its
name versus the image tag after it, a secret fetch that succeeded with nothing in it.
The load balancer's `Authorization missing` is in there too, as the shape of a
request that succeeds and tells you nothing.

The follower probes add a variant of the same trap, and it is worth naming because
a captured payload alone does not catch it: the follower's answer and the leader's
are *both* valid, so a probe pointed at the wrong host reports on the wrong appliance
with nothing to show that it has. The test that pins each follower probe's host
therefore stubs `curl` to answer by **port**, which makes the host part of what is
asserted rather than an assumption — the leader's body is in the test, answering
`ok`, while the follower's says otherwise. The further cases behind each probe (the
ones walking the replication filter through `disabled`, `apply errors` and the rest)
answer regardless of port, because what they pin is the filter's reading of a body,
and the host is already pinned by the test above them.
The replication filter gets the sharpest version of it for free: the leader answers
that route with `"subscriptions": "Subscriptions are only available on Conjur
Followers."`, a sentence where a follower has a list, so the real leader payload is
the test for the type guard that stops a truthy string from reading as a healthy
follower. `bin/api`'s arguments are asserted for the same reason — it reads secrets
from whatever it is given as the leader URL, so a follower retrieval check written
with `--against-master` would pass against an environment with no follower in it.

All of them were written after the code they cover, which makes them worth a moment's
suspicion: a test written green proves only that it agrees with today's
implementation. Each was checked by breaking what it pins and confirming it went red.
That caught a genuinely empty one — asserting that an unparseable answer produces no
output passes whether or not the pipeline survived it, because a failing command
substitution does not fail the test around it. Asserting the exit status is what made
it mean anything. (And `set -o pipefail` is why that case exists at all: a jq that
cannot read its input would otherwise take the run down at the moment verification is
trying to report.)

The hardening probes follow the same rule, and each reads the leader rather than
trusting the step that configured it, because every one of these options has a way
to "succeed" while leaving the leader as it was. All three go through `docker compose
exec` on the leader, so `docker` is the seam, and each is fed what a real leader
returned:

- **Master key encryption** lists the key files under `/opt/conjur/etc` with their
  file types. An encrypted leader has `*.key.enc` files; a plaintext one has `*.key`.
  A leader whose master key has not been unlocked since a restart has `*.key` as
  dangling symlinks into a tmpfs, which reads as `locked` rather than `encrypted` —
  the keys are encrypted, but nothing can use them. A mix reads as `partly
  encrypted`.
- **Custom certificates** runs `openssl s_client` from inside the leader against its
  own name, and reads the issuer of the certificate it actually presents. `evoke ca
  import` can fail quietly and leave the appliance's self-signed certificate in
  place, which is exactly what a desired-state check exists to catch, so the row
  names the issuer: `custom CA` only when the leaf is issued by the intermediate
  `bin/generate-certs` creates *and* that intermediate is in the chain, `appliance
  CA` for the self-signed fallback, `no intermediate` for a leaf served without its
  chain, and otherwise the issuer's own CN.
- **Generated DH parameters** reads `/etc/ssl/dhparam.pem`, the file nginx serves
  them from, and tells apart the appliance's RFC 3526 bootstrap file (which carries
  a `BOOTSTRAP PARAMETERS` tag), the repo's `files/dhparam.pem`, and anything else
  that is a DH parameter file.

Each was mutation-checked the same way as the probes before them. What the fixtures
could not provide is a *locked* leader: that case is built from what `find -printf`
reports for a dangling symlink rather than captured from a restarted MKE leader.

`--plan` therefore serves two needs at once: it is what makes the
spec→sequence translation testable, and it is what the skill shows before provisioning.

### Pass 2 (landed)

`followers: 0..3`. Pass 1 shipped `followers: 0..1`, which sequenced existing
`bin/dap` flags the way everything else in it does; going beyond one was a different
kind of work, kept apart so the PoC's riskiest question (does the whole chain hold
together?) stayed apart from its fiddliest one. What it took:

- **Compose services.** `conjur-follower-2` and `conjur-follower-3`, published on
  452 and 453 — 450 plus the number, stepping over 451, which is
  `CONJUR_K8S_FOLLOWER_PORT`'s default. `_follower_port` in `bin/utils.sh` is the
  one place that arithmetic lives. `bin/dap --follower-count` starts only the
  followers asked for, so the rest stay down rather than up and idle.
- **The shared certificate volume.** `follower-certs` is follower 1's
  `/opt/conjur/etc/ssl`, shared with the load balancer so it can serve the follower
  certificate that `_setup_follower` copies there. A second follower mounting it
  would configure its certificates over the first one's, so followers 2 and 3 do
  not: each keeps its own, and only follower 1's copy feeds the load balancer. They
  all come from the one seed, so they all present the same certificate chained to
  the same CA, which is what the load balancer verifies them against.
- **One seed, a copy per follower.** `evoke seed follower` is run once — the seed
  carries the leader's data key and the follower certificate, nothing that ties it
  to one follower, and each follower creates its own replication subscription when
  it is configured. It is `tee`'d into a file per follower rather than shared as
  one, because `evoke unpack seed` removes the file it unpacks: the first live run
  configured follower 1 and then failed follower 2's unpack on a missing seed. One
  seed also means the master key decrypt and re-encrypt on the leader happens once
  however many followers there are.
- **A backend per follower.** `files/haproxy/follower/haproxy.cfg` was already
  generated at provisioning time, so this changed how many server lines it emits.
  The server line lost the doubled `check port 443` and `ca-file` it carried, and
  the line-per-node loop it shared in shape with three copies in `bin/dap` is now
  one `_numbered_lines` in `bin/utils.sh` that all of them call.

The verification rows became one pair per follower, the way `standby N replication`
already read, which was a change to `_verify` and to the port a follower probe asks,
not to any filter.

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

**Every field is written out.** The skill asks about every schema property the
description leaves unstated, and writes the answer into the spec even when it equals
the default. So a skill-written spec never depends on the schema's defaults, and
changing a default cannot change what an existing generated spec builds. The skill
reads its constraints from `environments/schema.json` at run time. Its vendored
`reference/vocabulary.md` holds translation only: what customers call each field,
and what they describe that no field expresses. That way a new field or a widened
range needs no edit to the skill's prose to be enforced.

**A topology larger than the schema accepts is capped and named.** When a customer
has five followers and the schema accepts three, the spec says three, and the gap
list says two more were asked for. Capping is the only choice that still validates.
Naming the shortfall at the gate keeps it from being a silent approximation.

**Testing is an eval, not a test suite.** The skill's output is a model's
translation of prose, so an exact-output test would either be fragile or assert
nothing. `.claude/skills/conjur-env/evals/` runs three invented escalations through
`claude plugin eval`, each once with the skill and once without it, and reports the
delta. The cases are a description that states everything, one that leaves most
things unstated (the skill must ask, and must not write a spec), and one full of
gaps. The baseline arm gets the same copy of the repo, so the comparison is against
an agent that could read the schema and docs itself. Most graders read one field
value out of the written spec with a line-anchored regex. Two yes/no judges check
that the right questions were asked and the right gaps named. The evals cost money
per run and are not wired into `bin/env-test`. What they do not reach — validation,
the plan in the gate, provisioning — is listed in the evals' README.

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
   The skill holds up its half by walking every property in the schema and writing
   every field. The eval's `every-field` grader checks that it did, but only for the
   fields it names. Nothing enforces keeping the eval current: a new field needs a
   grader in the `complete` case, or the skill can get it wrong unnoticed.
2. **A third copy of ordering knowledge.** `bin/env` duplicates sequencing that
   `ci/providers/docker_compose.rb` already encodes, which itself duplicates
   `bin/dap`. The PoC knowingly adds a third copy. Recording it here so it is known
   debt rather than a later discovery. Consolidation is its own piece of work. The
   Ruby copy has already drifted: it provisions a single follower its own way, and
   reaches into `bin/utils.sh` for `_set_follower_proxy_config` through `bash -c`,
   which makes an underscore-prefixed helper a cross-language interface. It still
   works, because the helper defaults to one follower, but it is the thing to
   replace with `bin/dap --provision-follower` rather than to keep in step.
3. **Nothing here is in CI.** `Jenkinsfile` runs only `bin/upgrade-test FROM TO`. It
   invokes neither `ci/bin/end-to-end-tests` nor `bin/env-test`, so there is no
   automated integration coverage of provisioning at all, and the fast suite — which
   was built to be CI-able and needs nothing but a docker daemon — runs only when
   someone runs it. Wiring both in is a separate effort.
4. **`bin/dap --enable-auto-failover` dirties a tracked file.** It rewrites
   `policy/cluster.yml` to match the cluster it is building, so any auto-failover spec
   leaves `git status` modified. That breaks the "never edit a tracked file" rule in
   the decision log below, but it is `bin/dap`'s behaviour and not `bin/env`'s to fix;
   `docs/environments.md` tells the operator to `git checkout` it. Worth fixing in
   `bin/dap` — generate that policy to a gitignored path — rather than documenting
   forever.
5. **Proxy trust is provisioned but not verified.** `bin/env` runs
   `bin/dap --trust-follower-proxy` and then asserts nothing about it, so a follower
   whose trusted proxy is wrong passes every row. The follower rows read `/health`,
   a secret and the load balancer's stats, and none of them changes with the
   trusted proxy list —
   what would have to be probed is `evoke proxy list`, which is `docker compose exec`
   rather than an HTTP route and so is a different shape of probe from every other
   check here. Worth adding, and the reason it was not added in this pass is that the
   step it would cover was itself broken until this one: `--trust-follower-proxy` ran
   `evoke proxy add 12.16.23.15`, which is `conjur-master-5` rather than the follower
   load balancer's `12.16.23.16`, so the command succeeded and trusted a host that
   never forwards to the follower. Fixed here in `bin/dap`, which is a change outside
   `bin/env`'s remit made because the acceptance criterion — a follower provisioned
   and proxy-trusted in the same run, no manual follow-up — could not otherwise hold.
   Environments built before the fix still carry the wrong address; `evoke proxy list`
   on the follower shows it.
6. **`bin/api --fetch-secrets` always reads from the leader URL.** `--against-master`
   only changes where it *authenticates*; `fetch_secrets` curls the master URL either
   way. So the only way to read through a follower is
   `--leader-url https://conjur-follower.mycompany.local`, which is what the follower
   retrieval check does, and the flag names are actively misleading about it. The
   argument is asserted in `test/env.bats` precisely because the obvious spelling
   passes against an environment with no follower in it. Worth renaming or splitting
   in `artifacts/api-client/api-script`.
7. **`generate_dh: true` cannot pass on 5.0-stable.** The appliance's own generator,
   `/etc/my_init.d/dhgen.sh`, runs `openssl dhparam 3072 -out ...`. OpenSSL 3 (the
   image ships 3.0.13) wants the options before the size, answers `dhparam: Use -help
   for summary.` and exits, so the leader keeps its RFC 3526 bootstrap parameters for
   good. `bin/dap --wait-for-dh-params` used to poll for the full timeout and then
   report nothing; it now tells a finished generator from a dead one and fails at
   once with `/var/log/dhgen.log`, and verification reports `bootstrap`. It is not
   worked around here — generating the file ourselves would make the row pass
   without the appliance feature it describes working — which is why
   `environments/examples/hardened.yml` leaves `generate_dh` off. It is an appliance
   bug, and the fix belongs in the appliance's script.
8. **Three `bin/dap` fixes the hardening criteria needed.** All are outside `bin/env`'s
   remit, and made because a hardened spec could not otherwise provision in one run.
   - *The leader load balancer's CA went stale on certificate import.* Once standbys
     exist, HAProxy health-checks the leader with `check-ssl` against a snapshot of
     the leader's CA, which `bin/dap` copies into `system/haproxy/certs` when it
     deploys the proxy. After `--import-custom-certificates` that snapshot still
     holds the appliance CA, every backend fails its check with `SSL handshake
     failure`, and the leader is unreachable through the load balancer. Import now
     refreshes the snapshot and reloads the proxy.
     `_rotate_certificates` very likely has the same problem and was not touched.
   - *A follower under MKE raced the load balancer.* Seeding a follower from an
     MKE leader re-encrypts and unlocks the *leader's* keys, which restarts its
     nginx, and `evoke configure follower` then ran while HAProxy was still marking
     the leader down, failing with `Replication connection could not be
     established`. `_setup_follower` now waits for the leader to be healthy through
     the load balancer first.
   - *Verification raced proxy trust.* `evoke proxy add` returns before the
     follower's services restart to pick the proxy up, so on a fast run the
     follower rows read a follower that was briefly down — `follower health not
     ok` and `follower secret read not retrievable`, on a follower that was fine
     ten seconds later. Nothing about this is specific to hardening; the hardened
     run just reached verification sooner. `--trust-follower-proxy` now waits for
     the follower to be healthy again before returning.

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
| Unbuilt topology | Refused by the schema's ranges, not by a check in `bin/env` | Keeps "validates" and "is buildable" one claim, and makes hand-written and generated specs fail identically. |
| Checks | Preflight plus desired-vs-actual verification | A repro is only useful if the environment really is what the ticket described. |
| Preflight side effects | None; `--recreate`'s teardown is a provisioning command | Every check passes before the first volume is removed. |
| `--recreate` confirmation | The flag itself, plus the destruction stated in words | Keeps non-interactive use working, and the skill's single gate the only gate. |
| Tag resolution | Local image cache first, then the registry under a 30s ceiling | `bin/dap` does not force a pull, so a cached tag needs no VPN; an unbounded TCP timeout is not a fast failure. |
| Podman | Unsupported, explicitly | Avoids a third fork of drifted provisioning logic. |
| Podman detection | String-match `DOCKER_HOST`, the server platform and `docker --version` | No single authoritative field, and the check cannot depend on the daemon being up. |
| Testing | `--plan` plus bats; integration manual | Tests what will regress, without pretending to cover what CI can't reach. |
| Multi-follower | Pass 2, landed with a ceiling of 3 | Separates the riskiest question from the fiddliest. |
| Follower certificates | Follower 1 shares its certificate directory with the load balancer; the others keep their own | Two followers on one volume configure over each other's certificates. |
| Follower seeds | One seed, `tee`'d into a copy per follower | Nothing in it is per-follower, and the leader's MKE decrypt/re-encrypt then happens once; the copies because unpacking a seed removes it. |
| Load balancer routing | Verified off HAProxy's own `lbtot`, not inferred from follower health | A follower can be healthy on its own port and never routed to. |
| KB access | Vendored reference | No path dependency on a single machine's clone. |
| Skill gate | One gate: spec, gaps, plan, destruction warning | Folds the destructive confirm into the same decision point. |
| Unstated dimensions | Ask about every one | A repro is worth the extra turns; there are only a handful of fields. |
| Skill-written specs | Every field explicit, never a default | A generated spec's behaviour cannot shift when a schema default does. |
| Over-ceiling topology | Cap at the schema's maximum, name the rest as a gap | The only choice that validates; naming it keeps it from being a silent approximation. |
| Skill testing | `claude plugin eval` with a no-skill baseline, not bats | Prose translation has no exact output to assert; the delta is what shows the skill earns its place. |
| Hardening verification | Read the leader's key files, presented chain and DH file | Each option can "succeed" while leaving the leader as it was; a silent fallback has to fail a row. |
| Appliance DH bug | Surfaced, not worked around | Generating the file ourselves would make the row pass without the feature it describes. |
