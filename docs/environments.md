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

### 1. Run the tests (about a minute, no appliance)

```sh
bin/env-test
```

This starts no Conjur appliance and never contacts `registry.tld`, so it is the
cheapest way to confirm the tool works at all. One test by name:

```sh
bin/env-test test/env.bats --filter 'auto-failover with one standby is refused'
```

### 2. See what it would do (no side effects)

```sh
bin/env --plan environments/examples/single-node.yml
```

```
Plan for environments/examples/single-node.yml

Resolved spec:
  version                      5.0-stable
  leader.standbys              0
  leader.auto_failover         false
  leader.master_key_encryption false
  leader.custom_certificates   false
  leader.generate_dh           false
  followers                    0
  sample_data                  true

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
  4. leader server keys are not encrypted with a master key
  5. leader presents a certificate issued by its own appliance CA
  6. leader DH parameters are the pre-generated files/dhparam.pem
  7. standbys running is 0
  8. followers running is 0
  9. auto-failover configured is false
  10. sample secret staging/my-app-1/postgres-database/password is retrievable

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
| `leader.standbys` | integer | `0` | `0`–`4` — [see below](#standbys-and-auto-failover) |
| `leader.auto_failover` | boolean | `false` | `true` needs at least 2 standbys — [see below](#standbys-and-auto-failover) |
| `leader.master_key_encryption` | boolean | `false` | Encrypts the leader's server keys with a master key — [see below](#leader-hardening) |
| `leader.custom_certificates` | boolean | `false` | Replaces the leader's self-signed certificates with ones from `bin/generate-certs`; `true` allows at most 2 standbys — [see below](#leader-hardening) |
| `leader.generate_dh` | boolean | `false` | Has the leader generate its own DH parameters; does not work on 5.0-stable — [see below](#leader-hardening) |
| `followers` | integer | `0` | `0`–`3` — [see below](#followers) |
| `sample_data` | boolean | `true` | Loads the sample policy and variable values via `bin/api --load-sample-policy-and-values`. |
| `events` | array | — | `[]` only. Reserved seam for transitions (upgrades, promotions, failovers); **not implemented**. |

`sample_data` defaults to `true` because with no policy and no secrets there is
nothing to reproduce a secret-retrieval issue against.

## Standbys and auto-failover

The smallest highly available spec — a leader, two standbys and an auto-failover
cluster — is
[`environments/examples/highly-available.yml`](../environments/examples/highly-available.yml):

```yaml
version: "5.0-stable"

leader:
  standbys: 2
  auto_failover: true
```

**Two standbys is a floor, not a default.** Auto-failover is an etcd cluster, and
etcd elects a new leader by majority: with a leader and one standby, losing the
leader leaves one node out of two, which is not a majority, so nothing is
promoted. Three members is the smallest configuration that can actually fail
over. The schema refuses fewer rather than building a cluster that cannot do the
one thing it was asked for:

```
bin/env: spec error at /leader/standbys: 1 is less than the minimum of 2
bin/env:   hint: auto-failover is an etcd cluster and needs a quorum: a leader plus at least 2 standbys, so that losing the leader still leaves a majority to elect a new one. Either add standbys or set leader.auto_failover: false
bin/env: the spec was not accepted, so nothing was provisioned.
```

**The ceiling is four standbys**, and it is the compose topology's rather than
`bin/env`'s — `docker-compose.yml` defines `conjur-master-1` through
`conjur-master-5`. Asking for more is a schema error, not a failure partway
through provisioning:

```
bin/env: spec error at /leader/standbys: 5 is greater than the maximum of 4
bin/env:   hint: docker-compose.yml defines conjur-master-1 through conjur-master-5, so a leader and at most 4 standbys; more would need new compose services
```

**Each standby publishes its own host port**, so they join preflight:
`docker-compose.yml` puts each `conjur-master` node on 443 plus its number, which
makes the leader 444 and the standbys 445, 446, 447, 448. A two-standby spec
checks `443, 444, 445, 446, 7000`.

The order matters, and `bin/env` knows it — the leader has to be configured with
the standbys' hostnames in its certificate before any standby can be seeded, so
the standby count is passed to `--provision-master` as well:

```
Commands:
  1. bin/dap --version 5.0-stable --standby-count 2 --provision-master
  2. bin/dap --wait-for-master
  3. bin/dap --version 5.0-stable --standby-count 2 --provision-standbys
  4. bin/dap --standby-count 2 --enable-auto-failover
  5. bin/api --load-sample-policy-and-values
```

Expect 10–20 minutes for a two-standby cluster, most of it in
`evoke configure master` and the standby seeds.

**Enabling auto-failover dirties your working tree.** `bin/dap
--enable-auto-failover` rewrites the tracked `policy/cluster.yml` to list the
cluster's members, so `git status` shows it modified after the run. That is
`bin/dap`'s behaviour, not `bin/env`'s; `git checkout policy/cluster.yml` once
the environment is up.

## Followers

A leader with one follower is
[`environments/examples/leader-and-follower.yml`](../environments/examples/leader-and-follower.yml):

```yaml
version: "5.0-stable"

followers: 1
```

**Asking for a follower is the whole request.** `bin/env` provisions it and then
configures its proxy trust in the same run, so there is no manual follow-up step:

```
Commands:
  1. bin/dap --version 5.0-stable --provision-master
  2. bin/dap --wait-for-master
  3. bin/dap --version 5.0-stable --follower-count 1 --provision-follower
  4. bin/dap --follower-count 1 --trust-follower-proxy
  5. bin/api --load-sample-policy-and-values
```

`--trust-follower-proxy` tells the *follower* to trust the `X-Forwarded-For` its
load balancer sets, so that audit records and IP-restricted host identities see the
real client rather than the load balancer's own address. It is not a reachability
step — a follower serves secrets without it — but it is the kind of difference that
decides whether an authorization repro behaves like the customer's environment.
Confirm it with
`docker compose exec conjur-follower-1.mycompany.local evoke proxy list`, which
should name the follower load balancer, `12.16.23.16`.

**The follower goes in before the sample data**, and that is deliberate.
`evoke seed follower` snapshots the leader's database, so a follower seeded *after*
the secrets would serve them out of its own snapshot whether or not replication
ever started — and the retrieve-through-the-follower check below would pass on a
follower that is not replicating at all. Seeded first, the sample secret can only
reach the follower by replicating.

With standbys and auto-failover in the same spec, the follower goes in after
enrolment: `evoke configure follower` installs the failover rebaser, which is what
repoints the follower at a newly promoted leader, so the cluster wants to exist by
the time the follower is configured against it.

**More than one follower is a load-balanced tier.**
[`environments/examples/multiple-followers.yml`](../environments/examples/multiple-followers.yml)
asks for two. Each is provisioned, configured and told to trust the load balancer,
and the load balancer's config is generated with a backend per follower, balanced
round-robin:

```
Commands:
  1. bin/dap --version 5.0-stable --provision-master
  2. bin/dap --wait-for-master
  3. bin/dap --version 5.0-stable --follower-count 2 --provision-follower
  4. bin/dap --follower-count 2 --trust-follower-proxy
  5. bin/api --load-sample-policy-and-values
```

Every follower is configured from the one follower seed, each from its own copy
of it, since `evoke unpack seed` removes the file it unpacks. Only follower 1
shares its certificate directory with the load balancer (the `follower-certs`
volume) — that is where the load balancer's own certificate comes from — and the
others keep theirs to themselves, so no follower configures over another's
certificates.

**The ceiling is three followers**, and it is the compose topology's again —
`docker-compose.yml` defines `conjur-follower-1` through `conjur-follower-3`, so a
fourth needs a new compose service:

```
bin/env: spec error at /followers: 4 is greater than the maximum of 3
bin/env:   hint: docker-compose.yml defines conjur-follower-1 through conjur-follower-3, so at most 3 followers; more would need new compose services
bin/env: the spec was not accepted, so nothing was provisioned.
```

Asking for fewer leaves the rest of those services down, not started and idle.

**The follower tier's host ports join preflight**: 80, 449 and 7001 for the load
balancer, and one per follower — 450 for the first, then 452 and 453, stepping over
451, which the kubernetes follower uses. A spec with one follower checks
`443, 444, 7000, 80, 449, 450, 7001`, and with three
`443, 444, 7000, 80, 449, 450, 452, 453, 7001`. `CONJUR_FOLLOWER_PORT` moves 450;
the others are fixed in `docker-compose.yml`. Port **80** is the one most likely to
already be in use on a developer's machine, which is why it is checked rather than
discovered when compose fails.

**Each follower is verified independently of the leader and of the others**, on
two rows of its own, and the tier on two more — see
[Reading the verification table](#reading-the-verification-table). The pair that
matters per follower is health and replication: a follower whose replication
stopped right after it was seeded is up, reports itself healthy, and keeps serving
data that is quietly out of date. The pair that matters for the tier is a secret
read through the load balancer and which followers the load balancer actually
routes to.

Expect 5–10 minutes per follower on top of the leader's own time.

## Leader hardening

Three independent booleans under `leader`, each off by default, in any
combination. A production-shaped cluster with two of them on is
[`environments/examples/hardened.yml`](../environments/examples/hardened.yml):

```yaml
version: "5.0-stable"

leader:
  standbys: 2
  auto_failover: true
  master_key_encryption: true
  custom_certificates: true
  generate_dh: false

followers: 1
```

**All three are applied to the leader before anything is seeded from it.** A seed
carries the leader's keys, certificates and DH parameters to the node it seeds, so
a standby or follower seeded first would keep the leader's old ones. Certificates go
in before encryption, so the keys they import are encrypted along with the rest:

```
Commands:
  1. bin/dap --version 5.0-stable --standby-count 2 --provision-master
  2. bin/dap --wait-for-master
  3. bin/dap --import-custom-certificates
  4. bin/dap --enable-mke
  5. bin/dap --wait-for-master
  6. bin/dap --version 5.0-stable --standby-count 2 --provision-standbys
  7. bin/dap --standby-count 2 --enable-auto-failover
  8. bin/dap --version 5.0-stable --follower-count 1 --provision-follower
  9. bin/dap --follower-count 1 --trust-follower-proxy
  10. bin/api --load-sample-policy-and-values
```

`--enable-mke` restarts the leader's services, hence the second wait. Once it is
on, `bin/dap` configures every standby and follower with the same master key.

**`master_key_encryption`** — encrypts the leader's server keys under
`/opt/conjur/etc` with a master key held in `system/configuration/master-key`
(gitignored), and unlocks them.

**`custom_certificates`** — runs `bin/generate-certs` to create a root and
intermediate CA and certificates signed by them, and imports them into the leader
with `evoke ca import`. The generated files land under
`system/configuration/certificates`, which is gitignored. The leader certificate
names `conjur-master.mycompany.local` and `conjur-master-1` through
`conjur-master-3` only, so more than 2 standbys is refused:

```
bin/env: spec error at /leader/standbys: 3 is greater than the maximum of 2
bin/env:   hint: the custom leader certificate bin/generate-certs issues names conjur-master-1 through conjur-master-3 only (artifacts/certificate-generator/configuration/dap-master.json), so a third standby would serve a certificate that does not name it. Either ask for at most 2 standbys or set leader.custom_certificates: false
bin/env: the spec was not accepted, so nothing was provisioned.
```

**`generate_dh`** — configures the leader without the repo's pre-generated
`files/dhparam.pem`, so the appliance generates its own in the background, and
waits for that before seeding anything:

```
Commands:
  1. bin/dap --version 5.0-stable --generate-dh --provision-master
  2. bin/dap --wait-for-master
  3. bin/dap --wait-for-dh-params
  4. bin/api --load-sample-policy-and-values
```

**On 5.0-stable this fails, and that is the appliance's bug.** Its generator,
`/etc/my_init.d/dhgen.sh`, runs `openssl dhparam 3072 -out …`, which the image's
OpenSSL 3 refuses, so the leader keeps its bootstrap parameters for good.
`--wait-for-dh-params` notices the generator has exited and stops at once with its
log — see [Troubleshooting](#troubleshooting). It is off in `hardened.yml` for that
reason; set it to reproduce the failure, or against an appliance whose generator
works.

Each option gets its own verification row whichever way it is set, so a spec that
leaves one off also confirms it is off — see
[Reading the verification table](#reading-the-verification-table).

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
bin/env:   CONJUR_MASTER_PORT moves the leader load balancer off 443. The appliance
bin/env:   ports -- 444 for the leader, then 445 up, one per standby -- and 7000 are
bin/env:   fixed in docker-compose.yml, so those have to be freed.
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

  DIMENSION              DESIRED          ACTUAL           RESULT
  leader health          ok               ok               ok
  leader /info           reported         reported         ok
  leader image tag       5.0-stable       5.0-stable       ok
  master key encryption  not encrypted    not encrypted    ok
  leader certificate     appliance CA     appliance CA     ok
  dh parameters          pre-generated    pre-generated    ok
  standbys running       0                0                ok
  followers running      0                0                ok
  auto-failover          false            false            ok
  sample data            loaded           loaded           ok

The environment matches the spec.
Conjur is available at: 'https://localhost:443'
```

And the same table against a stopped environment, which is what every failure
mode looks like at once:

```
Verification

  DIMENSION              DESIRED          ACTUAL           RESULT
  leader health          ok               unreachable      MISMATCH
  leader /info           reported         no               MISMATCH
  leader image tag       5.0-stable       not running      MISMATCH
  master key encryption  not encrypted    unreadable       MISMATCH
  leader certificate     appliance CA     unreachable      MISMATCH
  dh parameters          pre-generated    unreadable       MISMATCH
  standbys running       0                0                ok
  followers running      0                0                ok
  auto-failover          false            unreachable      MISMATCH
  sample data            loaded           not retrievable  MISMATCH

bin/env: the environment does not match the spec.
```

A spec with standbys adds a row per standby, and one per cluster member when
auto-failover is on:

```
Verification

  DIMENSION              DESIRED          ACTUAL           RESULT
  leader health          ok               ok               ok
  leader /info           reported         reported         ok
  leader image tag       5.0-stable       5.0-stable       ok
  master key encryption  not encrypted    not encrypted    ok
  leader certificate     appliance CA     appliance CA     ok
  dh parameters          pre-generated    pre-generated    ok
  standbys running       2                2                ok
  standby 2 replication  streaming        streaming        ok
  standby 3 replication  streaming        streaming        ok
  followers running      0                0                ok
  auto-failover          true             true             ok
  cluster name           production       production       ok
  cluster member 1       enrolled         enrolled         ok
  cluster member 2       enrolled         enrolled         ok
  cluster member 3       enrolled         enrolled         ok
  sample data            loaded           loaded           ok
```

Followers add two rows each and two for the tier, none of which the leader can
answer for. From `multiple-followers.yml`:

```
Verification

  DIMENSION              DESIRED          ACTUAL           RESULT
  leader health          ok               ok               ok
  leader /info           reported         reported         ok
  leader image tag       5.0-stable       5.0-stable       ok
  master key encryption  not encrypted    not encrypted    ok
  leader certificate     appliance CA     appliance CA     ok
  dh parameters          pre-generated    pre-generated    ok
  standbys running       0                0                ok
  followers running      2                2                ok
  follower 1 health      ok               ok               ok
  follower 1 replication replicating      replicating      ok
  follower 2 health      ok               ok               ok
  follower 2 replication replicating      replicating      ok
  follower secret read   retrievable      retrievable      ok
  follower backends used 2                2                ok
  auto-failover          false            false            ok
  sample data            loaded           loaded           ok
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
- **master key encryption** — read off the leader's key files under
  `/opt/conjur/etc`, not off the fact that `--enable-mke` returned. `encrypted`
  means `*.key.enc` files are there; `not encrypted` means plain `*.key` files.
  `locked` means the keys are encrypted but not unlocked — the `*.key` links point
  at nothing, which is what an MKE leader looks like after a restart until
  `evoke keys unlock` runs. `partly encrypted` is a mix, and `unreadable` means the
  leader could not be asked.
- **leader certificate** — the issuer of the certificate the leader actually
  presents as `conjur-master.mycompany.local:443`, read with `openssl s_client`
  from inside the leader container. `custom
  CA` means it was issued by the intermediate `bin/generate-certs` created, with
  that intermediate in the chain. `appliance CA` is the appliance's own
  self-signed CA — what a certificate import that silently did not take leaves
  behind. `no intermediate` means the right leaf served without its chain, which
  a client holding only the root cannot verify. Any other issuer is reported by
  its CN, and `unreachable` means nothing completed a handshake.
- **dh parameters** — `/etc/ssl/dhparam.pem` on the leader, the file nginx serves
  them from. `pre-generated` is the repo's `files/dhparam.pem`, `generated` is
  anything else the leader produced, and `bootstrap` is the appliance's RFC 3526
  placeholder — which is what a leader whose generator died still has. See
  [Leader hardening](#leader-hardening).
- **standbys running** / **followers running** — counted from the running
  containers, not assumed from the spec.
- **standby N replication** — the leader's own view of that standby, read from
  `pg_stat_replication` under `/health`. The desired state is `streaming`: caught
  up and receiving WAL. `not replicating` means the container is up but the leader
  is not shipping to it at all, which is the failure a container count cannot see —
  a standby that is only running is not a standby. Any other postgres state is
  reported as postgres names it rather than flattened to a yes/no, so `catchup` —
  connected but still replaying the backlog — reads as a mismatch showing
  `catchup`. That is deliberate: `bin/dap` waits for synchronous replication before
  it returns, so a standby still catching up at verification time is a real finding,
  and the distinction between "behind" and "not connected" is the first thing you
  want to know.
- **follower N health** — `/health` on that follower's *own* port, not through the
  follower load balancer and not through the leader. The leader answers `/health`
  too, and answers it `ok`, so this row only means something because it asks the
  follower directly. One per follower the spec asks for.
- **follower N replication** — that follower's own view of its pglogical
  subscriptions, under `/health`. Followers replicate *logically*, so they have no
  row in the leader's `pg_stat_replication` — this is not the standby check with a
  different host. Read from the follower rather than the leader for two reasons: it
  still answers when the leader is unreachable, and it can tell receiving changes
  apart from applying them. The desired state is `replicating`. The others:
  `not replicating` (configured as a follower, subscribed to nothing — what a
  follower whose `evoke configure follower` never completed looks like),
  `initial sync` (still copying the leader's database), `disabled` (the
  subscription exists but is not running, which is what `evoke replication stop`
  leaves behind), `apply errors` and `sync errors` (receiving changes and failing
  on them — the case the leader's own view would call `streaming`), and
  `not a follower` (the appliance answered, but it is not a follower). One state it
  cannot see: a subscription that is enabled and error-free but stalled — receiving
  nothing and reporting nothing wrong — reads as `replicating`. The row is built from
  the subscriptions' enabled and error fields, not from `received_lsn` or
  `last_msg_receipt_time`, because every healthy follower is some microseconds behind
  the leader and a threshold on that would fail runs at random. The
  `follower secret read` row is the thing that catches a stalled follower in practice:
  it reads a secret that could only have arrived by replicating. One per follower
  the spec asks for.
- **follower secret read** — the sample secret fetched back *through the follower
  load balancer*, which is the only row that authenticates. A follower whose health
  is ok and whose replication is current is still useless if nothing can
  authenticate against it. Shown when `followers` is at least 1 and `sample_data`
  is true. It is one read, and so it speaks for whichever follower answered it.
- **follower backends used** — how many followers the load balancer chose while
  `bin/env` sent twice that many requests through it, read off the `lbtot` column
  of its stats page (`http://localhost:7001/;csv`) before and after. Every
  follower passing its own rows says nothing about this: a follower the load
  balancer never marks up — one whose certificate it cannot verify, say — leaves the
  tier serving from fewer followers than it has. `unreachable` means the stats page
  did not answer. Shown when `followers` is at least 1.
- **auto-failover** — whether the leader is clustered at all, read from the cluster
  name under `/info`, the same way the rest of `bin/dap` detects a cluster. A
  cluster under an unexpected name is reported as `cluster <name>` rather than
  folded into `false`.
- **cluster name** — the same probe, stated as a name: `production` is the only
  cluster `bin/dap` enrols, and the spec has no field to override it. It gets its
  own row because the membership rows below cannot say it — etcd is asked which
  nodes are in the cluster it holds, not which cluster that is. Only shown when
  `auto_failover` is true.
- **cluster member N** — each node's membership in the cluster, read from
  `evoke cluster member list` on the leader. `/info` says the leader thinks it is
  clustered; this says etcd agrees about every node, and names the one that is
  `missing`. Only shown when `auto_failover` is true.
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

Every field's ceiling is the topology `bin/env` can actually build, and it rises as
`bin/env` learns to build more — so "this spec validates" and "this spec can be
provisioned" stay the same claim. Asking for more than a ceiling is a schema error
naming what raising it would take, rather than a topology quietly built smaller
than you asked for: at most 4 standbys
([see above](#standbys-and-auto-failover)) and at most 3 followers
([see above](#followers)). Beyond those, use `bin/dap` by hand.

Also not supported, by design or by not-yet:

- **Transitions.** `events:` is a reserved key, not a feature. Upgrades,
  promotions and triggered failovers are run by hand with `bin/dap`.
- **Convergence.** There is no reconcile, by design: `bin/env` builds from clean
  and refuses an environment that already exists. See
  [Rebuilding an environment](#rebuilding-an-environment).
- **Podman.** Refused on purpose — `bin/podman-dap` is a drifted fork, and a
  declarative layer over it would misrepresent what it can build. See
  [Preflight](#preflight).
- **Custom certificates with more than 2 standbys.** The generated leader
  certificate names three `conjur-master` nodes; adding hosts to
  `artifacts/certificate-generator/configuration/dap-master.json` is what would
  raise it.
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

**`standby N replication … not replicating`** — the container is up but the
leader is not streaming to it. `bin/dap --standby-count N --provision-standbys`
seeds standbys from the leader, so this usually means the seed or
`evoke replication sync start` did not complete for that node. The leader's own
view is the authority, and this is the exact read behind the row:

```sh
curl -sk https://localhost:443/health \
  | jq '.database.replication_status.pg_stat_replication'
```

Match the standby on `usename` — that is the replication role its seed created, so
it carries the hostname. `application_name` is an opaque `standby_<hex>_<hex>`.
Port 443 is the leader load balancer (`CONJUR_MASTER_PORT`), which is what `bin/env`
probes; going direct to 444 asks conjur-master-1 specifically, which is a different
question after a failover.

**`follower replication … not replicating`** (or `disabled`, `apply errors`,
`sync errors`) — the follower is up and healthy but is not applying the leader's
changes, which means it is serving whatever it had when it was seeded. Its own view
is the authority, and this is the exact read behind the row:

```sh
curl -sk https://localhost:450/health \
  | jq '.database.logical_replication_status'
```

Port 450 is follower 1 itself (`CONJUR_FOLLOWER_PORT`), which is what `bin/env`
probes for `follower 1`; followers 2 and 3 are on 452 and 453. Asking the *leader* on 443 is a different question and gives a
misleading answer: it replies with `"subscriptions": "Subscriptions are only
available on Conjur Followers."`, a sentence rather than a list, which is why the row
reads `not a follower` if the probe is ever pointed at the wrong port. Followers
replicate logically, so there is nothing about them in the leader's
`pg_stat_replication` — do not go looking there.

**`follower secret read … not retrievable` while the other follower rows pass.** The
follower itself is healthy and current, so the problem is in front of it — the
follower load balancer, or authentication. It is the only follower row that goes
through the load balancer, so compare it against the appliance directly:

```sh
curl -sk https://localhost:449/health   # through the load balancer
curl -sk https://localhost:450/health   # follower 1 itself; 452 and 453 for 2 and 3
```

Proxy trust is *not* the cause: without it the read still works, and the audit
records simply attribute it to the load balancer's address.

**`follower backends used` is short of the follower count while every follower's
own rows pass.** The followers are fine and the load balancer is not sending to
all of them. Its stats page says which it has marked down and why:

```sh
curl -s 'http://localhost:7001/;csv' | cut -d, -f1,2,18,37 | grep www-backend
```

That is each backend's status and its last health check, which is `L7OK` for a
follower it is routing to. For one that is `DOWN`, the check status says whether it
could not reach the follower, could not verify its certificate against the CA in
`follower-certs`, or got a response other than a healthy one.

**Audit records or IP-restricted hosts see the load balancer's address, not the
client's.** Proxy trust did not take. No verification row covers it — nothing the
follower answers reports its trusted proxies — so check it by hand:

```sh
docker compose exec conjur-follower-1.mycompany.local evoke proxy list
```

It should name `12.16.23.16`, the follower load balancer, on every follower — ask
`conjur-follower-2` and `-3` the same way. Anything else, or `No
proxies`, and `docker compose exec conjur-follower-1.mycompany.local evoke proxy
add 12.16.23.16` sets it. An environment provisioned before this was fixed has
`12.16.23.15` — `conjur-master-5`, which never forwards to the follower — so the
address needs replacing rather than adding to.

**`bin/dap --wait-for-dh-params` stops with `The leader's DH parameter generator exited`**
and `dhparam: Use -help for summary.` in the log it prints — the appliance's
generator is broken on this version (see [Leader hardening](#leader-hardening)),
and waiting longer will not help. Set `generate_dh: false`, or pick an appliance
version whose `/etc/my_init.d/dhgen.sh` works.

**The leader is unreachable through the load balancer after a custom certificate
import**, with `SSL handshake failure` in `docker compose logs
conjur-master.mycompany.local`. Once standbys exist, the leader load balancer
health-checks each node against a copy of the leader's CA in
`system/haproxy/certs`; a copy taken before the import still holds the appliance
CA. `bin/dap --import-custom-certificates` refreshes it now, so this means an
environment built before that fix, or certificates changed some other way.
Refresh it by hand:

```sh
docker cp "$(docker compose ps -q conjur-master-1.mycompany.local)":/opt/conjur/etc/ssl/. system/haproxy/certs
docker compose restart conjur-master.mycompany.local
```

**`leader certificate … appliance CA` with `custom_certificates: true`.** The
import did not take. `docker compose exec conjur-master-1.mycompany.local evoke ca
list` shows what the leader holds, and the exact read behind the row is:

```sh
docker compose exec conjur-master-1.mycompany.local openssl s_client \
  -connect conjur-master.mycompany.local:443 -servername conjur-master.mycompany.local \
  < /dev/null 2> /dev/null | head -8
```

**`cluster member N … missing`** — the node is not in etcd's member list even
though the leader reports a cluster. `docker compose exec
conjur-master-1.mycompany.local evoke cluster member list` shows what etcd
actually holds.

**`policy/cluster.yml` shows as modified after an auto-failover run.** Expected.
`bin/dap --enable-auto-failover` rewrites it with the cluster's members;
`git checkout policy/cluster.yml` to drop it.

**A spec validates but provisioning fails.** That gap is the interesting one —
the schema is meant to make it impossible. Worth reporting rather than working
around.

## From a customer description: the `conjur-env` skill

In Claude Code, from this repo, paste a customer's description of their environment
(or give the path to a local file holding it) and ask for a local repro. The
`conjur-env` skill works through these steps:

1. It maps the description onto the spec's fields.
2. It asks about every field the description leaves unstated.
3. It writes a spec into `environments/` and validates it with `bin/env --plan`.
4. It stops at a single gate. The gate shows the spec, everything the customer
   described that the spec cannot express (to set up by hand), the plan, and what
   `--recreate` would destroy if an environment already exists.
5. On a clear yes, it runs `bin/env` and reports the verification table.

The skill adds no provisioning logic of its own. Everything it builds, it builds
through `bin/env`. The skill is at `.claude/skills/conjur-env/`, and its evals are at
`.claude/skills/conjur-env/evals/`.

## Files

| Path | Purpose |
|---|---|
| `bin/env` | The entrypoint. |
| `bin/env-test` | Runs the tests in a container, so bats is not a host dependency. |
| `environments/schema.json` | The contract. |
| `environments/examples/` | Sanitized example specs. |
| `artifacts/env-validator/` | Pinned container that converts YAML to JSON and applies the schema, in one pass. |
| `test/env.bats` | Plan output, validation failures, the guard rails, and each verification probe against a captured appliance payload. |
| `.claude/skills/conjur-env/` | The skill that turns a customer's description into a spec, with its vendored vocabulary reference and its evals. |
