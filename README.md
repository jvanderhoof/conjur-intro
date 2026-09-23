# Conjur Intro
Tools and scripts  utilities that make it easier to make, manage, and run demos

## Demos

- [AWS Cluster](demos/aws-cluster/README.md)
- [Conjur Cluster](demos/cluster/README.md)
- [Certificate Authority](demos/certificate-authority/mutual-tls/README.md)

## Tools
- [Generate Signed Certificates](tools/simple-certificates/)
- [K6 Performance Tests](tools/performance-tests/k6/)

## CLI Tools

This project includes a CLI which simplifies the process of running a variety of scenarios.

### Workflow Examples

Deploy a master auto-failover cluster (behind L4 load balancer).

```sh
$ bin/dap --provision-master
$ bin/dap --provision-standbys
$ bin/dap --enable-auto-failover
```

Given the above, to add a follower (behind L7 load balancer), add data, and validate retrieval:
```sh
$ bin/dap --provision-follower
$ bin/api --load-sample-policy-and-values
$ bin/api --fetch-secrets
```

Next, let's trigger an auto-failover event:
```sh
$ bin/dap --trigger-failover
```

Upgrade and rebuild cluster:
```sh
$ bin/dap --upgrade-master <version>
$ bin/dap --provision-standbys --version <version>
$ bin/dap --enable-auto-failover
$ bin/dap --provision-follower --version <version>
```

and finally, validate:

```sh
$ bin/api --fetch-secrets
```

Follower could be also deployed using Kind into Kubernetes cluster:

```sh
$ bin/dap --provision-k8s-follower
```

More information about way of how the Follower is deployed into Kubernetes
cluster can be found in [README.md](artifacts/k8s-follower-orchestrator/README.md)

### Integration Examples

Deploy the Conjur Provider for Secrets Store CSI Driver in Kubernetes (kind):
  
```sh
$ bin/dap --provision-csi-provider

# Print the mounted secret values:
$ docker compose exec -T csi-provider-orchestrator bash -c "kubectl exec -n test-app test-app -- cat /mnt/secrets-store/relative/path/fileA.txt"
$ docker compose exec -T csi-provider-orchestrator bash -c "kubectl exec -n test-app test-app -- cat /mnt/secrets-store/relative/path/fileB.txt"
$ docker compose exec -T csi-provider-orchestrator bash -c "kubectl exec -n test-app test-app -- cat /mnt/secrets-store/relative/path/fileC.txt"
```

Deploy the Conjur Secrets Provider in Kubernetes (kind):
  
```sh
$ bin/dap --provision-secrets-provider

# Print the mounted secret values:
$ POD_NAME=$(docker compose exec -T secrets-provider-orchestrator bash -c "kubectl get pods -n test-app -l app=test-app -o jsonpath='{.items[0].metadata.name}'")
$ docker compose exec -T secrets-provider-orchestrator bash -c "kubectl exec -n test-app $POD_NAME -- cat /opt/secrets/conjur/db-credentials.yaml"
```

Deploy Secretless Broker as a sidecar in Kubernetes (kind):
  
```sh
$ bin/dap --provision-secretless-broker

# Check secretless-broker connectivity:
$ docker compose exec -T secretless-broker-orchestrator bash -c "kubectl exec -n test-app deploy/test-app -c test-app -- nc -zv localhost 5432"

# Check secretless-broker logs:
$ docker compose exec -T secretless-broker-orchestrator bash -c "kubectl logs -n test-app deploy/test-app -c secretless-broker"
```

### Working with Podman

The project is enabled to work with Podman instead of Docker.
To use Podman the above commands can be replaced as follows:

```sh
$ bin/podman-dap --provision-master
$ bin/podman-dap --provision-standbys
$ bin/podman-dap --enable-auto-failover
```

Similarly bin/api and bin/cli can be replaced with bin/podman-api and bin/podman-cli.

To connect to the UI in the browser, use ports 10443(through HA proxy) or 10444(Conjur)
***

### bin/dap
`bin/dap` provides a dead simple mechanism for starting DAP in a variety of configurations and workflows. It provides visibility into the commands required to perform various workflows.

#### Flags
|Flag|Type|Outcome|Notes|
|-|-|-|-|
|--create-backup|action|• Creates a backup|Requires configured master|
|--dry-run|configuration|Only print configuration commands|
|--enable-auto-failover|action|• Configures Master cluster with auto-failover|Requires configured master and standbys|
|--enable-mke|action|• Generates a master key<br>• Encrypts and unlocks the Master's server keys with it|Requires configured master, before any standby or follower|
|--follower-count `<count>`|configuration|Number of followers for `--provision-follower` and `--trust-follower-proxy` (defaults to 1, at most 3)|
|--generate-dh|configuration|• Disables the mounting of pre-generated DH params inside the master so they're generated on the fly|
|--help||Shows all available arguments||
|--import-custom-certificates|action|• Imports pre-generated 3rd-party certificates|Requires configured master|
|--promote-standby|action|• Stops the current master<br>• Promotes a standby| Requires configured standbys and no auto-failover|
|--provision-follower|action|• Removes followers if present<br>• Starts a DAP container per follower and a Layer 7 load balancer across them<br>• Generates a follower seed<br>• Configures each follower|Requires configured master|
|--provision-k8s-follower|action|• Removes follower if present<br>• Configures follower inside kubernetes cluster ran by kind|Requires configured master|
|--provision-master|action|• Starts a DAP container and Layer 4 load balancer<br>• Configures with account `demo` and password `MySecretP@ss1`||
|--provision-standbys|action|• Removes standbys if present<br>• Starts two DAP containers<br>• Generates standby seed files<br>• Configures standbys<br>• Enable Synchronous Standby|Requires configured master|
|--provision-csi-provider|action|• Configures Conjur CSI Provider inside kubernetes cluster ran by kind|Requires configured master|
|--provision-secrets-provider|action|• Configures Conjur Secrets Provider inside kubernetes cluster ran by kind|Requires configured master|
|--provision-secretless-broker|action|• Configures Secretless Broker as a sidecar inside kubernetes cluster ran by kind|Requires configured master|
|--restore-from-backup|action|• Removes auto-failover (if enabled)<br>• Stops and renames master<br>• Starts new DAP container<br>• Restores master from backup|Requires a previously created backup|
|--stop|action|Stops and removes all containers||
|--trigger-failover|action|• Stops current master|Requires an auto-failover cluster|
|--trust-follower-proxy|action|• Adds Follower load balancer as a trusted proxy on each follower|Requires configured followers|
|--upgrade-master `<version>`|action|• Removes auto-failover (if enabled)<br>• Generates a backup<br>• Stops and removes master<br>• Starts new DAP container<br>• Restores master from backup|Requires configured master|
|--version `<version>`|configuration|Version of DAP to use (defaults to latest)|
|--wait-for-dh-params|action|Blocks until the Master has replaced its bootstrap DH parameters with generated ones|Use after `--generate-dh --provision-master`|
|--k8s-follower-version `<version>`|configuration|Version of K8S-Follower to use (defaults to latest)|
|--follower-to-master-connection `<on/off>`|action|Pauses or unpauses follower connection to master|Requires a configured master|

### bin/api

`bin/api` enables some common policy and API flows.

#### Flags

|Flag|Type|Outcome|Notes|
|-|-|-|-|
|--against-master|configuration|Runs read actions against the master||
|--authenticate-user|action|• Authenticates with default user and password<br>• Displays the resulting authentication token||
|--fetch-secrets|action|• Authenticates<br>• Retrieves variable values|Run against follower unless `--against-master` flag is present|
|--load-policy|action|• Authenticates<br>• Loads policy|Run against master|
|--load-sample-policy-and-values|action|• Authenticates<br>• Loads policy and variable values|Run against master, equivalent to running '--load-sample-policy' and '--set-secrets'|
|--password `<password>`|configuration|Uses a non-default password for authentication||
|--set-secrets|action|• Authenticates<br>• Sets variable values|Requires `--load-policy` before running|
|--user `<conjur-user>`|configuration|Uses a non-default (`admin`) user for authentication||

### bin/env

`bin/env` provisions an environment from a declarative spec, so that a
configuration can be described once, built reproducibly, and rebuilt later —
typically to reproduce a customer issue locally. Where `bin/dap` is a set of
lifecycle verbs, `bin/env` is a single description of the end state you want.

```sh
# Show the commands and checks without running any of them
$ bin/env --plan environments/examples/single-node.yml

# Provision, then print a desired-vs-actual table
$ bin/env environments/examples/single-node.yml

# Destroy the environment already here and build the spec from clean
$ bin/env --recreate environments/examples/single-node.yml
```

A spec is YAML, validated against [`environments/schema.json`](environments/schema.json).
The smallest useful one is a single line:

```yaml
version: "5.0-stable"
```

Everything else takes a documented default: one leader, no standbys, no
follower, no auto-failover, no leader hardening (master key encryption, custom
certificates, generated DH parameters), and the sample policy and secrets loaded. Quote the
version — unquoted `13.10` is the YAML number `13.1`.

The schema is the contract, so an unknown or misspelled key is a hard error
naming the offending field rather than a silent no-op:

```
$ bin/env --plan my-spec.yml
bin/env: spec error at /leader/standby: unknown key; the schema does not define it
bin/env: the spec was not accepted, so nothing was provisioned.
```

Specs written into `environments/` are gitignored, because this repo is mirrored
to the public `conjurdemos` GitHub org and real specs carry customer hostnames
and admin passwords. Only the schema and the sanitized examples under
`environments/examples/` are tracked.

A leader can have up to four standbys, optionally enrolled in an auto-failover
cluster — which the schema will not accept with fewer than two of them, because
an etcd cluster of two nodes cannot elect a new leader when it loses one.
[`environments/examples/highly-available.yml`](environments/examples/highly-available.yml)
is the smallest such spec. It can also have up to three followers behind the
follower load balancer, provisioned and proxy-trusted in the same run, each
verified on its own health and replication, and the tier on a secret read through
the load balancer and on how many followers it actually routes to —
[`environments/examples/leader-and-follower.yml`](environments/examples/leader-and-follower.yml)
and
[`environments/examples/multiple-followers.yml`](environments/examples/multiple-followers.yml).
A fourth follower would need a new compose service, so the schema refuses it
rather than letting `bin/env` quietly build something smaller than you asked for.

The leader can be hardened with three independent booleans — master key
encryption, custom certificates and generated DH parameters — each applied before
anything is seeded from it, and each verified off the leader itself: its key
files, the certificate chain it presents, and the DH parameters nginx serves.
[`environments/examples/hardened.yml`](environments/examples/hardened.yml) puts
the first two together with standbys, auto-failover and a follower.

Nothing is reconciled. A preflight checks up front that the appliance version
resolves and the host ports are free, and an environment that already exists is
refused rather than half-configured — rebuild it with `--recreate`, which states
plainly that it destroys the data, the replication seeds, the master key and the
audit history. Podman is refused too, pointing at `bin/podman-dap`.

Run the fast tests with `bin/env-test`; they start no appliance containers and
need no `registry.tld` access.

In Claude Code, the `conjur-env` skill (`.claude/skills/conjur-env/`) writes the
spec for you from a customer's description of their environment. It asks about
anything the description leaves out and names what the spec cannot express. It
then shows one confirmation before running `bin/env`.

- **[docs/environments.md](docs/environments.md)** — usage: writing a spec, the
  field reference, reading the verification table, troubleshooting.
- **[docs/declarative-environments.md](docs/declarative-environments.md)** —
  design: the decision log, non-goals, and known debt.

## Start a single DAP instance

To start a single DAP instance:

```sh
$ bin/dap --provision-master
```

This instance runs behind an HAProxy load balancer and is available at: [https://localhost].  Login:

- Account `demo`
- User: `admin`
- Password: `MySecretP@ss1`

## Start a DAP Cluster with Follower

To start a basic HA DAP cluster (self-signed certificates, no Master Key encryption) and a Follower:

```sh
$ bin/dap --provision-master
$ bin/dap --provision-standbys
$ bin/dap --provision-follower
```

This instance runs behind an HAProxy load balancer and is available at: [https://localhost].  Login:

- Account `demo`
- User: `admin`
- Password: `MySecretP@ss1`

#### Available Flags

The following flags are available:

```
Usage: bin/dap single [options]

    --create-backup                   Creates a backup|Requires configured master
    --dry-run                         Print configuration commands with executing
    --enable-auto-failover            Configures Master cluster with auto-failover (Requires configured master and standbys)
    --enable-mke                      Encrypts the Master's server keys with a master key (Requires configured master, before any standby or follower)
    --follower-count <count>          Number of followers for --provision-follower and --trust-follower-proxy (defaults to 1, at most 3)
    --h, --help                       Shows this help message
    --import-custom-certificates      Imports pre-generated 3rd-party certificates (Requires configured master)
    --promote-standby                 Stops the current master and promotes a standby (Requires configured standbys and no auto-failover)
    --provision-follower              Configures followers behind a Layer 7 load balancer (Requires configured master)
    --provision-k8s-follower          Configures follower inside kubernetes cluster ran by kind (Requires configured master)
    --provision-master                Configures a DAP Master with account `demo` and password `MySecretP@ss1` behind a Layer 4 load balancer
    --provision-standbys              Deploys and configures two standbys (Requires configured master)
    --provision-csi-provider          Configures Conjur CSI provider inside kubernetes cluster ran by kind (Requires configured master)
    --provision-secrets-provider      Configures Conjur Secrets Provider for Kubernetes inside a kind cluster (Requires configured master)
    --provision-secretless-broker     Configures Secretless Broker as a sidecar inside a kind cluster (Requires configured master)
    --restore-from-backup             Restores a master from backup|Requires a previously created backup
    --provision-keycloak              Configures Keycloak OIDC authenticator (Requires configured master)
    --stop                            Stops all containers and cleans up cached files
    --trigger-failover                Stops current master (Requires an auto-failover cluster)
    --trust-follower-proxy            Adds Follower load balancer as a trusted proxy on each follower (Requires configured followers)
    --upgrade-master <version>        Restores master from backup (Requires configured master)
    --version <version>               Version of DAP to use (defaults to latest build)
    --k8s-follower-version <version>  Version of K8S-Follower to use (defaults to latest build)
    --wait-for-dh-params              Blocks until the Master has replaced its bootstrap DH parameters with generated ones
```

### `bin/cli`
`bin/cli` is a proxy script, sending all subsequent arguments to a Conjur CLI container. This provides a simple mechanism for loading policy and interacting with Conjur.

#### Loading policy
The policy folder contains sample policy which can be loaded with:
```sh
$ bin/cli conjur policy replace -b root -f policy/users.yml
$ bin/cli conjur policy load -b root -f policy/policy.yml
$ bin/cli conjur policy load -b staging -f policy/apps/myapp.yml
$ bin/cli conjur policy load -b production -f policy/apps/myapp.yml
$ bin/cli conjur policy load -b root -f policy/application_grants.yml
$ bin/cli conjur policy load -b root -f policy/hosts.yml
```

#### Setting/Retrieving a Variable
```
bin/cli conjur variable set -i production/myapp/database/username -v my-username
bin/cli conjur variable set -i production/myapp/database/password -v my-password
bin/cli conjur variable set -i production/myapp/database/url -v https://my-database.mycompany.com
bin/cli conjur variable set -i production/myapp/database/port -v 5432
```

#### Validating Packages
This project can also be used to verify PRs, by installing the branch specific package (created by Jenkins).  To begin, download the `.deb` package.  After starting Conjur, packages can be installed with:

```
# Start Conjur
$ bin/dap --provision-master --version 5.11.0
```
Next in a new tab:

```
$ bin/install ~/Downloads/conjur-ui_2.10.9.1-e389f20_amd64.deb
```
The install script will install the package into the running Conjur appliance and restart the Conjur service.

You can view the contents of this package by running:

```
$ docker compose exec conjur-master-1.mycompany.local ls -a /opt/conjur/possum/
```

## Performance Tests

Conjur Intro includes support for running a simple load test against a running instance.

```sh
# Start Conjur
$ bin/dap --provision-master
$ bin/dap --provision-follower

# Run datadog agent
$ ./tools/performance-tests/k6/bin/metrics --start

# Optionally, load policies and 150k secrets (this might take around an hour)
$ ./bin/load-benchmark-data --accounts_per_safe 200 --safes 15 --hosts 300 --users 150 --all-properties-synchronized

# To integrate with statsD, set ENABLE_STATSD to true:
$ ENABLE_STATSD=true ./bin/load-benchmark-data --accounts_per_safe 200 --safes 15 --hosts 300 --users 150 --all-properties-synchronized

# Run load test without StatsD (default)
$ TEST_FILE=tools/performance-tests/k6/scenarios/read-individually.js ./bin/load-test

# Or run load test with StatsD enabled
$ ENABLE_STATSD=true TEST_FILE=tools/performance-tests/k6/scenarios/read-individually.js ./bin/load-test

# To get raw results in json format set ENABLE_JSON_OUTPUT flag (disabled by default)
# Additionally, when ENABLE_JSON_OUTPUT flag is enabled, standard deviation will be calculated
# Note: resulted json file can have hundreds of megabytes
$ ENABLE_JSON_OUTPUT=true TEST_FILE=tools/performance-tests/k6/scenarios/read-individually.js ./bin/load-test

# Run benchmark for number of authenticators
$ bin/dap --provision-keycloak
$ ./bin/authenticators-benchmark

```

The above test generates a report in the folder:

`tmp/{TIMESTAMP}-test-name`

Load is applied using k6. The k6 files are located at:

`tools/performance-tests/k6`

Scenarios for load testing are located at:

`tools/performance-tests/k6/scenarios`

Number of VUs can be configured by setting `K6_CUSTOM_VUS` environment variable.

Currently supported scenarios are: 

- `tools/performance-tests/k6/scenarios/read-individually.js` - Read one secret at a time from Conjur by 12 VUs

- `tools/performance-tests/k6/scenarios/read-batch-2-secrets.js` - Read two secrets at a time from Conjur by 12 VUs

- `tools/performance-tests/k6/scenarios/read-batch-4-secrets.js` - Read four secrets at a time from Conjur by 12 VUs

- `tools/performance-tests/k6/scenarios/create-policy.js` - Create unique policies in Conjur by 1 VU in 500 iterations.

- `tools/performance-tests/k6/scenarios/write-secrets.js` - Write secrets to Conjur by 20 VUs. <br>
  - Secrets are located at `tools/performance-tests/k6/data/test-variable-secrets.csv` <br>

- `tools/performance-tests/k6/scenarios/policy-number-test.js` - Load simple policies into Conjur by 5 VUs. <br>
  - Duration of the test can be configured by setting K6_CUSTOM_DURATION environment variable.

- `tools/performance-tests/k6/scenarios/policy-depth-test.js` - Keep loading nested policies until max depth is reached

- `tools/performance-tests/k6/scenarios/list-and-batch-read.js` - List all secrets in Conjur and then read a portion of them.
  - The purpose of this is to imitate how External Secrets Operator works when using the Find by Name or Find by Tag features.
    See <https://github.com/external-secrets/external-secrets/pull/3364.

Note: for read scenarios, we can specify the desired safe and lob to read from by setting the `DESIRED_SAFE` and `DESIRED_LOB` environment variables. <br>

Benchmark scenario for number of authenticators:
- `bin/authenticators-benchmark` - Load test for number of authenticators. <br>
  - Runs a loop that: adds authenticators to Conjur, run `read-individually.js` scenario,
    measure the performance and save the results. 

## Contributing

We welcome contributions of all kinds to this repository. For instructions on
how to get started and descriptions of our development workflows, please see our
[contributing guide](CONTRIBUTING.md).

## License

This repository is licensed under Apache License 2.0 - see [`LICENSE`](LICENSE) for more details.
