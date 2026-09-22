# Declarative environments — usage

How to describe a Conjur environment in YAML and build it with `bin/env`.

For *why* it is built this way — the decision log, what is deliberately out of
scope, and the known debt — see
[declarative-environments.md](declarative-environments.md).

## What it is, and when to reach for it

`bin/dap` is a set of lifecycle verbs: provision a master, add standbys, enable
auto-failover, trigger a failover. You drive it step by step, in the right order.

`bin/env` is a single description of the end state you want. You write down what
the environment should look like, and it works out the sequence, runs it, and
then checks that what came up is what you asked for.

Reach for `bin/env` when you want a configuration to be **reproducible** — most
often reproducing a customer issue locally, where the environment needs to be
rebuilt the same way tomorrow, or on someone else's laptop. Reach for `bin/dap`
when you are exploring, or when you need something `bin/env` cannot build yet.

## Quick start

### 1. Run the tests (seconds, no appliance)

```sh
bin/env-test
```

This starts no Conjur appliance and never contacts `registry.tld`, so it is the
cheapest way to confirm the tool works at all. One test by name:

```sh
bin/env-test test/env.bats --filter 'refused by the schema'
```

### 2. See what it would do (no side effects)

```sh
bin/env --plan environments/examples/single-node.yml
```

```
Plan for environments/examples/single-node.yml

Resolved spec:
  version              5.0-stable
  leader.standbys      0
  leader.auto_failover false
  followers            0
  sample_data          true

Preflight:
  1. no environment already exists in this working copy
  2. host ports 443, 444, 7000 are free
  3. appliance image registry.tld/conjur-appliance:5.0-stable resolves

Commands:
  1. bin/dap --version 5.0-stable --provision-master
  2. bin/dap --wait-for-master
  3. bin/api --load-sample-policy-and-values

Checks:
  1. leader /health reports ok
  2. leader /info reports its configuration
  3. leader image tag is 5.0-stable
  4. standbys running is 0
  5. followers running is 0
  6. auto-failover configured is false
  7. sample secret staging/my-app-1/postgres-database/password is retrievable

Nothing was provisioned (--plan).
```

`--plan` touches nothing. **Resolved spec** is your spec with every default
filled in, so you can see what you got by omission as well as what you asked
for. **Preflight** is what gets checked before the first command runs — see
[Preflight](#preflight).

### 3. Build it

```sh
bin/env environments/examples/single-node.yml
```

Runs the preflight checks, then the commands above in order, then prints the
verification table. Expect a few minutes, most of it inside
`evoke configure master`. When it finishes you have a leader at
`https://localhost`, account `demo`, user `admin`, password `MySecretP@ss1` — the
same environment `bin/dap --provision-master` gives you, plus the sample policy
and secrets.

Tear it down with `bin/dap --stop`, or rebuild it with
[`--recreate`](#rebuilding-an-environment).

## Writing a spec

The smallest useful spec is one line:

```yaml
version: "5.0-stable"
```

Everything else takes a documented default. Write specs into `environments/`,
which is gitignored — see [Where specs live](#where-specs-live). Start by copying
[`environments/examples/single-node.yml`](../environments/examples/single-node.yml).

**Quote the version.** Unquoted `13.5` is a YAML number, and unquoted `13.10`
becomes `13.1` — a different appliance, provisioned without complaint, which is
the one outcome a repro tool cannot afford. The schema requires a string so this
fails loudly instead.

### Fields

| Field | Type | Default | Accepted today |
|---|---|---|---|
| `version` | string, **required** | — | An appliance image tag, as passed to `bin/dap --version`. Letters, digits, dots, dashes, underscores. |
| `leader.standbys` | integer | `0` | `0` only — [see below](#not-supported-yet) |
| `leader.auto_failover` | boolean | `false` | `false` only — [see below](#not-supported-yet) |
| `followers` | integer | `0` | `0` only — [see below](#not-supported-yet) |
| `sample_data` | boolean | `true` | Loads the sample policy and variable values via `bin/api --load-sample-policy-and-values`. |
| `events` | array | — | `[]` only. Reserved seam for transitions (upgrades, promotions, failovers); **not implemented**. |

`sample_data` defaults to `true` because with no policy and no secrets there is
nothing to reproduce a secret-retrieval issue against.

## The schema is the contract

Every spec is validated against
[`environments/schema.json`](../environments/schema.json) before anything runs.
An unknown key, a wrong type, or a value outside the accepted range is a hard
error that names the offending [JSON pointer](https://www.rfc-editor.org/rfc/rfc6901)
and provisions nothing.

A misspelled key is named precisely, not blamed on its parent:

```
$ bin/env --plan my-spec.yml
bin/env: spec error at /leader/standby: unknown key; the schema does not define it
bin/env: the spec was not accepted, so nothing was provisioned.
```

An unquoted version, caught with a hint. Note the reported value — YAML had
already turned `13.10` into `13.1` before validation ever saw it:

```
bin/env: spec error at /version: 13.1 is not of type 'string'
bin/env:   hint: quote the version so YAML keeps it a string, e.g. version: "13.5"
bin/env: the spec was not accepted, so nothing was provisioned.
```

Constraints live in the schema rather than in `bin/env`, which means a spec you
hand-wrote fails in exactly the same place as one a tool generated for you.

## Preflight

Three read-only checks run before the first provisioning command, so that an
environment which cannot come up fails in seconds rather than six minutes into
`evoke configure master`:

```
Preflight

  ok  no environment already exists in this working copy
  ok  host ports 443, 444, 7000 are free
  ok  appliance image registry.tld/conjur-appliance:5.0-stable resolves (local cache)
```

**The appliance version has to resolve.** The local image cache is checked
first — `bin/dap` does not force a pull, so a tag you already have provisions
without the VPN. Otherwise the registry is asked, and a tag it does not have is
distinguished from a registry that did not answer:

```
bin/env: appliance version 13.5 does not resolve as registry.tld/conjur-appliance:13.5.
bin/env:   the registry answered, and has no such tag. Check the version in the spec.
bin/env:   A tag already pulled needs neither: docker images | grep conjur-appliance
```

The registry gets 30 seconds. Off VPN `registry.tld` does not answer at all, and
without a ceiling that is a TCP timeout rather than a check.

**The host ports have to be free**, because `docker compose` discovers a port it
cannot bind only after pulling the appliance image:

```
bin/env: a host port this environment needs is already in use:
  port 443 is held by container some-other-proxy
bin/env:   CONJUR_MASTER_PORT moves the leader load balancer off 443; 444 and 7000
bin/env:   are fixed in docker-compose.yml, so those have to be freed.
```

A port held by one of *this* project's own containers is not a conflict — those
are torn down before the new environment needs the port.

**Podman is refused** before the spec is even read. `bin/podman-dap` builds a
Conjur environment under podman, but it is a drifted fork of `bin/dap` — different
host ports, no master key encryption, a hardcoded standby count — so a spec
`bin/env` accepts does not describe what it would build. Use it directly.

## Rebuilding an environment

`bin/env` does not reconcile. Run it against an environment that already exists
and it refuses rather than half-configuring what is there:

```
bin/env: an environment already exists in this working copy:
  conjur-intro-conjur-master-1.mycompany.local-1 (running)
  conjur-intro-conjur-master.mycompany.local-1 (running)
bin/env: nothing is reconciled, so this is refused rather than half-configured.
bin/env:   Rebuild it from clean with --recreate, which destroys its data, its
bin/env:   replication seeds, its master key and its audit history.
bin/env:   Or tear it down yourself with bin/dap --stop.
```

Appliance provisioning is largely non-idempotent, and per-dimension state
detection is where a reconciler goes subtly wrong. Rebuilding from clean needs
none of it, and matches how repro work actually goes.

```sh
bin/env --recreate environments/examples/single-node.yml
```

`--recreate` makes `bin/dap --stop` the first command in the plan, and says in
words what that costs before running it:

```
--recreate destroys the environment already here before building the new one.
'bin/dap --stop' removes this compose project's volumes, and with them:

  - every policy and secret value loaded into the leader
  - the replication seeds held for any standby or follower
  - the master key
  - the audit database, and the audit history in it

Nothing is backed up first, and none of it can be recovered afterwards. Passing
--recreate is the confirmation; there is no second prompt.
```

Passing the flag *is* the confirmation — nothing prompts — so read what
`bin/env --plan --recreate <spec>` prints if you are unsure. The teardown is a
provisioning command rather than part of preflight, which is what keeps a failed
check from leaving you with a destroyed environment and no replacement.

## Reading the verification table

After provisioning, `bin/env` probes the environment and compares what it finds
against what you asked for. Any mismatch exits non-zero. A successful run:

```
Verification

  DIMENSION            DESIRED          ACTUAL           RESULT
  leader health        ok               ok               ok
  leader /info         reported         reported         ok
  leader image tag     5.0-stable       5.0-stable       ok
  standbys running     0                0                ok
  followers running    0                0                ok
  auto-failover        false            false            ok
  sample data          loaded           loaded           ok

The environment matches the spec.
Conjur is available at: 'https://localhost:443'
```

And the same table against a stopped environment, which is what every failure
mode looks like at once:

```
Verification

  DIMENSION            DESIRED          ACTUAL           RESULT
  leader health        ok               unreachable      MISMATCH
  leader /info         reported         no               MISMATCH
  leader image tag     5.0-stable       not running      MISMATCH
  standbys running     0                0                ok
  followers running    0                0                ok
  auto-failover        false            unknown          MISMATCH
  sample data          loaded           not retrievable  MISMATCH

bin/env: the environment does not match the spec.
```

What the dimensions mean:

- **leader health** — `/health` reports ok. `unreachable` means nothing answered
  on the port; `unparseable` means something answered but not with the JSON
  expected, which usually means you reached the load balancer's error page rather
  than Conjur.
- **leader /info** — the appliance reports its configuration, so it is not just
  listening but actually configured.
- **leader image tag** — the tag the leader container is *actually* running,
  compared against the tag you asked for. This deliberately compares the
  requested tag rather than the appliance's self-reported build, so a symbolic
  tag like `5.0-stable` verifies as cleanly as a pinned one — and a stale
  container left behind by an earlier run shows up as a mismatch.
- **standbys running** / **followers running** — counted from the running
  containers, not assumed from the spec.
- **auto-failover** — read from the cluster name under `/info`, the same way the
  rest of `bin/dap` detects a cluster.
- **sample data** — a known sample secret is fetched back. Only shown when
  `sample_data` is true. `"the appliance is up"` and `"the appliance is usable
  for a repro"` are different claims, and this is the one that matters.

## Where specs live

| Path | Tracked? |
|---|---|
| `environments/schema.json` | yes |
| `environments/examples/*.yml` | yes — sanitized |
| `environments/*.yml` | **no — gitignored** |

**This repo is mirrored to the public `conjurdemos` GitHub org** (see
`Jenkinsfile`). Real specs hold appliance hostnames and admin passwords copied
out of customer tickets, so `environments/*.yml` is gitignored and only the
schema and the sanitized examples are tracked. If you add an example, sanitize it.

## Not supported yet

Standbys, auto-failover and followers are **refused by the schema**, rather than
quietly built smaller than you asked for:

```
bin/env: spec error at /followers: 1 is greater than the maximum of 0
bin/env:   hint: followers are not provisioned yet; build this by hand with bin/dap for now, and see docs/environments.md
bin/env: the spec was not accepted, so nothing was provisioned.
```

Each field's ceiling rises as `bin/env` learns to build it, so "this spec
validates" and "this spec can be provisioned" stay the same claim. Until then,
use `bin/dap --provision-standbys`, `--enable-auto-failover` and
`--provision-follower` by hand.

Also not supported, by design or by not-yet:

- **Transitions.** `events:` is a reserved key, not a feature. Upgrades,
  promotions and triggered failovers are run by hand with `bin/dap`.
- **Convergence.** There is no reconcile, by design: `bin/env` builds from clean
  and refuses an environment that already exists. See
  [Rebuilding an environment](#rebuilding-an-environment).
- **Podman.** Refused on purpose — `bin/podman-dap` is a drifted fork, and a
  declarative layer over it would misrepresent what it can build. See
  [Preflight](#preflight).
- **Authenticators, DR nodes, custom accounts, hostnames and passwords.** All
  outside the spec. See the non-goals in the design doc.

## Troubleshooting

**`no such spec: …`** — the path is resolved relative to where you ran the
command, so a typo or a wrong working directory lands here.

**`the registry did not answer within 30s`** — `registry.tld` is internal and
needs VPN. A tag already in your local image cache is used as-is, so check
`docker images | grep conjur-appliance` before assuming you need the network.

**`an environment already exists in this working copy`** — expected, and not a
bug. `bin/env` does not reconcile: rebuild with `--recreate`, or tear the
environment down with `bin/dap --stop`. Note that stopped leftover containers
count, because a half-removed environment is not a clean slate either.

**A port conflict you do not recognise.** `lsof -nP -iTCP:443 -sTCP:LISTEN`
names the holder in full; `bin/env` prints only the first listener it finds.

**Verification mismatches immediately after a successful-looking run.** Most
often a stale container from an earlier version, which the image-tag row is there
to catch. `bin/dap --stop` and rebuild.

**Alarming-looking errors partway through provisioning.** Lines like
`nginx: [emerg] cannot load certificate … no such file` followed by
`WARN: command nginx -t failed` are the appliance's own bootstrap noise — the
certificate genuinely does not exist at that point in `evoke configure master`,
and it is generated a few steps later. They come from the appliance, not from
`bin/env`, and a run that ends with `Configuration successful` was fine. Trust
the verification table over anything in the middle.

**A spec validates but provisioning fails.** That gap is the interesting one —
the schema is meant to make it impossible. Worth reporting rather than working
around.

## Files

| Path | Purpose |
|---|---|
| `bin/env` | The entrypoint. |
| `bin/env-test` | Runs the tests in a container, so bats is not a host dependency. |
| `environments/schema.json` | The contract. |
| `environments/examples/` | Sanitized example specs. |
| `artifacts/env-validator/` | Pinned container that converts YAML to JSON and applies the schema, in one pass. |
| `test/env.bats` | Plan-output, validation and verification-failure tests. |
