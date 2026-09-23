#!/usr/bin/env bats

# Fast tests for bin/env: plan output and every validation failure mode.
#
# Nothing here starts a Conjur appliance container or contacts registry.tld, so
# the whole file runs in seconds. It does use the local docker daemon to build
# and run the small spec-validator image, because that is how bin/env converts
# YAML and applies the schema -- see docs/declarative-environments.md.
#
# Run with: bin/env-test

setup_file() {
  cd "$BATS_TEST_DIRNAME/.."

  # Build the validator up front so the first test is not timed with a docker
  # build in it.
  docker build --quiet --tag conjur-intro/env-validator:2 artifacts/env-validator > /dev/null
}

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  SPEC="$BATS_TEST_TMPDIR/spec.yml"
}

# Writes the given lines to $SPEC.
spec() {
  printf '%s\n' "$@" > "$SPEC"
}

# The commands bin/env said it would run, one per line, stripped of numbering.
plan_commands() {
  printf '%s\n' "$output" | awk '/^Commands:$/{ found = 1; next } found && !NF { exit } found' \
    | sed 's/^  [0-9]*\. //'
}

# The last run's output with column padding collapsed, so that asserting on a
# table row does not mean counting spaces.
rows() {
  printf '%s\n' "$output" | tr -s ' '
}

# The checks bin/env said it would run, one per line, stripped of numbering.
plan_checks() {
  printf '%s\n' "$output" | awk '/^Checks:$/{ found = 1; next } found && !NF { exit } found' \
    | sed 's/^  [0-9]*\. //'
}

# The preflight checks bin/env said it would run, one per line, stripped of
# numbering.
plan_preflight() {
  printf '%s\n' "$output" | awk '/^Preflight:$/{ found = 1; next } found && !NF { exit } found' \
    | sed 's/^  [0-9]*\. //'
}

#
## Plan output
#

@test "a spec with only a version plans a single leader with sample data" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --provision-master
bin/dap --wait-for-master
bin/api --load-sample-policy-and-values' ]
}

@test "the tracked example plans the same sequence as a defaults-only spec" {
  run bin/env --plan environments/examples/single-node.yml

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 5.0-stable --provision-master
bin/dap --wait-for-master
bin/api --load-sample-policy-and-values' ]
}

@test "the tracked highly-available example plans a leader, two standbys and a cluster" {
  run bin/env --plan environments/examples/highly-available.yml

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 5.0-stable --standby-count 2 --provision-master
bin/dap --wait-for-master
bin/dap --version 5.0-stable --standby-count 2 --provision-standbys
bin/dap --standby-count 2 --enable-auto-failover
bin/api --load-sample-policy-and-values' ]
}

@test "plan mode reports the defaults it filled in" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$output" == *"version              13.5"* ]]
  [[ "$output" == *"leader.standbys      0"* ]]
  [[ "$output" == *"leader.auto_failover false"* ]]
  [[ "$output" == *"followers            0"* ]]
  [[ "$output" == *"sample_data          true"* ]]
}

@test "plan mode lists the verification checks, including secret retrieval" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'leader /health reports ok'* ]]
  [[ "$(plan_checks)" == *'leader /info reports its configuration'* ]]
  [[ "$(plan_checks)" == *'leader image tag is 13.5'* ]]
  [[ "$(plan_checks)" == *'standbys running is 0'* ]]
  [[ "$(plan_checks)" == *'followers running is 0'* ]]
  [[ "$(plan_checks)" == *'auto-failover configured is false'* ]]
  [[ "$(plan_checks)" == *'staging/my-app-1/postgres-database/password is retrievable'* ]]
}

@test "standbys are provisioned after the leader, and the leader is told how many" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # --standby-count is on the leader command as well as the standby one, and not
  # for symmetry: `evoke configure master` takes the standby hostnames as
  # certificate altnames, so a leader provisioned without them issues a
  # certificate the standbys cannot be reached on.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --standby-count 2 --provision-master
bin/dap --wait-for-master
bin/dap --version 13.5 --standby-count 2 --provision-standbys
bin/api --load-sample-policy-and-values' ]
}

# bin/dap passes --version through to compose as VERSION, and every conjur-master
# service resolves its image from it. --provision-standbys starts containers, so a
# standbys command without the version gets bin/dap's own default rather than the
# spec's: a 13.5 leader with 5.0-stable standbys, which nothing downstream would
# report.
@test "standbys are provisioned from the version in the spec, not bin/dap's default" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2' '  auto_failover: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_commands)" == *'bin/dap --version 13.5 --standby-count 2 --provision-standbys'* ]]
}

@test "auto-failover enrols the cluster once the standbys are replicating" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2' '  auto_failover: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # Enrolment last but for the sample data: it needs every node it will enrol to
  # be up, and it loads cluster policy of its own, so the sample data goes in
  # afterwards and the retrievability check then speaks for the finished cluster.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --standby-count 2 --provision-master
bin/dap --wait-for-master
bin/dap --version 13.5 --standby-count 2 --provision-standbys
bin/dap --standby-count 2 --enable-auto-failover
bin/api --load-sample-policy-and-values' ]
}

@test "a follower is provisioned after the leader, and proxy trust follows it" {
  spec 'version: "13.5"' 'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # The follower before the sample data, and not only because the feature suite
  # provisions a production topology in that order: `evoke seed follower` snapshots
  # the leader's database, so a follower seeded after the sample data would serve
  # that secret out of its own snapshot whether or not replication ever worked --
  # and the retrievability check below it would pass on a broken follower.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --provision-master
bin/dap --wait-for-master
bin/dap --version 13.5 --provision-follower
bin/dap --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
}

@test "the tracked leader-and-follower example plans a follower and its proxy trust" {
  run bin/env --plan environments/examples/leader-and-follower.yml

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 5.0-stable --provision-master
bin/dap --wait-for-master
bin/dap --version 5.0-stable --provision-follower
bin/dap --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
}

# Same trap as the standbys: --provision-follower brings conjur-follower-1 up, and
# compose resolves its image from VERSION, so a follower command without the
# version gets bin/dap's own default -- a 13.5 leader with a 5.0-stable follower.
# --trust-follower-proxy starts nothing, so it needs no version.
@test "the follower is provisioned from the version in the spec, not bin/dap's default" {
  spec 'version: "13.5"' 'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_commands)" == *'bin/dap --version 13.5 --provision-follower'* ]]
  [[ "$(plan_commands)" != *'--version 13.5 --trust-follower-proxy'* ]]
}

@test "a follower is provisioned after auto-failover enrolment, not before it" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2' '  auto_failover: true' 'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # `evoke configure follower` installs the failover rebaser service, which is
  # what repoints the follower at a newly promoted leader, so the cluster wants to
  # exist before the follower is configured against it.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --standby-count 2 --provision-master
bin/dap --wait-for-master
bin/dap --version 13.5 --standby-count 2 --provision-standbys
bin/dap --standby-count 2 --enable-auto-failover
bin/dap --version 13.5 --provision-follower
bin/dap --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
}

@test "a spec with no follower plans neither follower command" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_commands)" != *'follower'* ]]
}

@test "plan mode lists the follower checks, including retrieval through it" {
  spec 'version: "13.5"' 'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'followers running is 1'* ]]
  [[ "$(plan_checks)" == *'follower /health reports ok'* ]]
  [[ "$(plan_checks)" == *'follower is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'retrievable through the follower'* ]]
}

@test "a spec with no follower lists no follower checks beyond the count" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'followers running is 0'* ]]
  [[ "$(plan_checks)" != *'follower /health'* ]]
  [[ "$(plan_checks)" != *'through the follower'* ]]
}

@test "the follower tier's own host ports are part of preflight" {
  spec 'version: "13.5"' 'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # 80, 449 and 7001 are the follower load balancer's; 450 is the follower
  # appliance published directly. Grouped after the leader's rather than sorted in,
  # so the list reads as one tier then the other.
  [[ "$(plan_preflight)" == *'host ports 443, 444, 7000, 80, 449, 450, 7001 are free'* ]]
}

@test "the follower ports stay out of preflight when no follower is asked for" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_preflight)" == *'host ports 443, 444, 7000 are free'* ]]
}

@test "disabling sample data drops both loading it and checking it" {
  spec 'version: "13.5"' 'sample_data: false'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --provision-master
bin/dap --wait-for-master' ]
  [[ "$(plan_checks)" != *'retrievable'* ]]
}

@test "plan mode lists the preflight checks, naming the ports and the image" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_preflight)" == *'no environment already exists'* ]]
  [[ "$(plan_preflight)" == *'host ports 443, 444, 7000 are free'* ]]
  [[ "$(plan_preflight)" == *'registry.tld/conjur-appliance:13.5 resolves'* ]]
}

@test "plan mode lists the cluster checks, per standby and per cluster member" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2' '  auto_failover: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'standbys running is 2'* ]]
  [[ "$(plan_checks)" == *'standby 2 is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'standby 3 is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'conjur-master-1.mycompany.local is enrolled in the production cluster'* ]]
  [[ "$(plan_checks)" == *'conjur-master-3.mycompany.local is enrolled in the production cluster'* ]]
}

@test "plan mode lists no cluster membership check without auto-failover" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'standby 2 is replicating from the leader'* ]]
  [[ "$(plan_checks)" != *'enrolled'* ]]
}

@test "each standby's own host port is part of preflight" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_preflight)" == *'host ports 443, 444, 445, 446, 7000 are free'* ]]
}

@test "recreate plans a teardown first and says plainly what that destroys" {
  spec 'version: "13.5"'

  run bin/env --plan --recreate "$SPEC"

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --stop
bin/dap --version 13.5 --provision-master
bin/dap --wait-for-master
bin/api --load-sample-policy-and-values' ]

  # The destruction has to be stated in words, not left to be inferred from
  # `bin/dap --stop`: this is the one thing bin/env does that cannot be undone.
  [[ "$output" == *'destroys'* ]]
  [[ "$output" == *'seeds'* ]]
  [[ "$output" == *'master key'* ]]
  [[ "$output" == *'audit'* ]]
  [[ "$output" == *'secret'* ]]
}

@test "recreate reports that it tears the existing environment down, not reconciles it" {
  spec 'version: "13.5"'

  run bin/env --plan --recreate "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_preflight)" != *'no environment already exists'* ]]
  [[ "$(plan_preflight)" == *'torn down'* ]]
}

@test "plan mode provisions nothing" {
  # deploy_proxy writes this file on the way to starting the leader, so its
  # absence is evidence that no provisioning ran.
  if [ -e files/haproxy/master/haproxy.cfg ]; then
    skip 'an environment has already been provisioned in this working copy'
  fi

  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [ ! -e files/haproxy/master/haproxy.cfg ]
  [[ "$output" == *'Nothing was provisioned (--plan).'* ]]
}

#
## Validation -- the schema is the contract
#

@test "an unknown top level key is a hard error naming its pointer" {
  spec 'version: "13.5"' 'follower: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/follower: unknown key'* ]]
  [[ "$output" == *'nothing was provisioned'* ]]
}

@test "a misspelled nested key names the nested pointer, not its parent" {
  spec 'version: "13.5"' 'leader:' '  standby: 2'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/standby: unknown key'* ]]
}

@test "a missing version is rejected" {
  spec 'sample_data: true'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *"'version' is a required property"* ]]
}

@test "an unquoted version is rejected with a hint, not silently truncated" {
  # YAML reads 13.10 as the number 13.1, which would provision the wrong
  # appliance without saying so.
  spec 'version: 13.10'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/version'* ]]
  [[ "$output" == *'quote the version'* ]]
}

@test "a version that could reach the shell as syntax is rejected" {
  # The version is interpolated into a bin/dap invocation, so the schema's
  # pattern is the thing standing between a spec file and arbitrary arguments.
  spec 'version: "13.5 --provision-standbys"'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/version'* ]]
  [[ "$output" == *'does not match'* ]]
  [[ "$output" == *'reaches a command line'* ]]
}

@test "an empty version is rejected" {
  spec 'version: ""'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/version'* ]]
}

@test "a negative standby count is a range error" {
  spec 'version: "13.5"' 'leader:' '  standbys: -1'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/standbys'* ]]
  [[ "$output" == *'minimum of 0'* ]]
}

@test "a non-boolean sample_data is a type error" {
  spec 'version: "13.5"' 'sample_data: yes please'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/sample_data'* ]]
  [[ "$output" == *"is not of type 'boolean'"* ]]
}

@test "an empty event list validates, because the seam is reserved" {
  spec 'version: "13.5"' 'events: []'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

@test "a populated event list is refused as unimplemented" {
  spec 'version: "13.5"' 'events:' '  - upgrade: "13.6"'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/events'* ]]
  [[ "$output" == *'reserved seam'* ]]
}

@test "an empty spec is rejected" {
  : > "$SPEC"

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'spec is empty'* ]]
}

@test "unparseable YAML is rejected as YAML, not as a schema violation" {
  spec 'version: "13.5"' 'leader: [unclosed'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'not valid YAML'* ]]
}

@test "a spec that is not a mapping is rejected" {
  spec '- version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *"is not of type 'object'"* ]]
}

#
## The leader cluster -- how far the schema lets a spec go
#
# The compose topology defines conjur-master-1 through 5, so a leader and at most
# four standbys. The ceiling is the schema's, not a conditional in bin/env, so a
# hand-written spec fails exactly where a generated one does -- and it fails
# before anything is provisioned rather than halfway through a standby.

@test "a standby count above what the compose topology defines is a schema error" {
  spec 'version: "13.5"' 'leader:' '  standbys: 5'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/standbys'* ]]
  [[ "$output" == *'maximum of 4'* ]]
  [[ "$output" == *'docker-compose.yml'* ]]
  [[ "$output" == *'nothing was provisioned'* ]]
}

@test "the largest standby count the compose topology supports validates" {
  spec 'version: "13.5"' 'leader:' '  standbys: 4'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

@test "auto-failover with one standby is refused, and the message says why" {
  spec 'version: "13.5"' 'leader:' '  standbys: 1' '  auto_failover: true'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/standbys'* ]]
  [[ "$output" == *'quorum'* ]]
  [[ "$output" == *'nothing was provisioned'* ]]
}

@test "auto-failover on its own is refused rather than taking the standby default" {
  # leader.standbys defaults to 0, so this spec asks for a cluster of one, which
  # can never elect anything. The cross-field rule is what catches it.
  spec 'version: "13.5"' 'leader:' '  auto_failover: true'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'quorum'* ]]
}

@test "auto-failover with two standbys validates" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2' '  auto_failover: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

@test "the quorum rule does not fire when auto-failover is off" {
  spec 'version: "13.5"' 'leader:' '  standbys: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

#
## The follower tier -- how far the schema lets a spec go
#
# Same mechanism again, one tier down. docker-compose.yml defines a single
# conjur-follower-1, and the follower load balancer's haproxy.cfg names one
# backend, so a second follower needs generated config as well as a new compose
# service. Two is refused here rather than provisioning one follower and
# reporting a mismatch for the other.

@test "more followers than the compose topology defines is a schema error" {
  spec 'version: "13.5"' 'followers: 2'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/followers'* ]]
  [[ "$output" == *'maximum of 1'* ]]
  [[ "$output" == *'conjur-follower-1'* ]]
  [[ "$output" == *'nothing was provisioned'* ]]
}

@test "the largest follower count the compose topology supports validates" {
  spec 'version: "13.5"' 'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

#
## Guard rail -- podman
#
# bin/podman-dap is a drifted fork of bin/dap: different host ports, no master
# key encryption, a hardcoded standby count. A spec bin/env accepts does not
# describe what that fork would build, so podman is refused rather than
# half-supported.

@test "a podman DOCKER_HOST is refused, pointing at the podman entrypoint" {
  spec 'version: "13.5"'

  DOCKER_HOST='unix:///run/user/1000/podman/podman.sock' run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'podman'* ]]
  [[ "$output" == *'bin/podman-dap'* ]]

  # Refused before the spec is even read, so there is no plan to mistake for a
  # promise that this could work.
  [[ "$output" != *'Commands:'* ]]
}

@test "a docker CLI that is really podman is refused" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # What `podman-docker` answers: the docker CLI is a shim and the daemon behind
  # it is not docker.
  _runtime_identity() {
    echo 'podman version 5.2.2'
  }

  run _refuse_podman

  [ "$status" -ne 0 ]
  [[ "$output" == *'bin/podman-dap'* ]]
}

@test "docker is not mistaken for podman" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  _runtime_identity() {
    echo 'unix:///var/run/docker.sock'
    echo 'Docker Desktop 4.92.0 (240144)'
    echo 'Docker version 29.8.0, build 88096ef'
  }

  run _refuse_podman

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

#
## Guard rail -- an environment that already exists
#
# There is no convergence. Appliance provisioning is largely non-idempotent, so
# a run against a live environment is refused rather than reconciled.

@test "an environment that already exists is refused, not reconciled" {
  spec 'version: "13.5"'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _existing_environment() {
    echo 'conjur-intro-conjur-master-1.mycompany.local-1 (running)'
  }

  run _preflight

  [ "$status" -ne 0 ]
  [[ "$output" == *'conjur-intro-conjur-master-1.mycompany.local-1 (running)'* ]]
  [[ "$output" == *'--recreate'* ]]
}

@test "the containers already here are read from this compose project, with their state" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # Stands in for the daemon, and pins what is asked of it: --all, because a
  # stopped leader is just as much an environment as a running one.
  docker() {
    case "$*" in
      'compose ps --all --quiet' ) echo 'ours0001' ;;
      *'State.Status'*'ours0001'* ) echo '/conjur-intro-conjur-master-1.mycompany.local-1 (exited)' ;;
      * ) return 1 ;;
    esac
  }

  run _existing_environment

  [ "$status" -eq 0 ]
  [ "$output" = 'conjur-intro-conjur-master-1.mycompany.local-1 (exited)' ]
}

@test "a container whose name cannot be read is still reported, by its id" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  docker() {
    case "$*" in
      'compose ps --all --quiet' ) echo 'ours0001' ;;
      # The inspect fails -- the container went away between the two calls.
      * ) return 1 ;;
    esac
  }

  run _existing_environment

  [ "$status" -eq 0 ]
  [ "$output" = 'ours0001' ]
}

@test "recreate is what gets past an environment that already exists" {
  spec 'version: "13.5"'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"
  RECREATE=true

  _existing_environment() {
    echo 'conjur-intro-conjur-master-1.mycompany.local-1 (running)'
  }
  _port_holder() {
    :
  }
  # Stands in for the image being in the local cache, so the check passes
  # without contacting registry.tld.
  _image_in_local_cache() {
    return 0
  }

  run _preflight

  [ "$status" -eq 0 ]
}

#
## Preflight -- ports
#

@test "a bound host port fails preflight, naming the port and what holds it" {
  spec 'version: "13.5"'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _existing_environment() {
    :
  }
  _port_holder() {
    if [ "$1" = 443 ]; then
      echo 'container some-other-proxy'
    fi
  }

  run _preflight

  [ "$status" -ne 0 ]
  [[ "$output" == *'443'* ]]
  [[ "$output" == *'some-other-proxy'* ]]

  # Named before the registry is contacted: the ports are free or they are not,
  # and knowing that costs nothing.
  [[ "$output" != *'resolve'* ]]
}

@test "a port held by this project's own containers is not a conflict" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # Stands in for the daemon. The container publishing the port is one of ours,
  # which --recreate tears down before the new environment needs the port.
  docker() {
    case "$*" in
      *'compose ps'* ) echo 'ours0001' ;;
      *'ps --filter publish=443'* ) echo 'ours0001' ;;
      * ) return 1 ;;
    esac
  }

  run _port_holder 443

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a port held by an unrelated container names that container" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  docker() {
    case "$*" in
      *'compose ps'* ) echo 'ours0001' ;;
      *'ps --filter publish=443'* ) echo 'other002' ;;
      *'inspect --format'* ) echo '/nginx' ;;
      * ) return 1 ;;
    esac
  }

  run _port_holder 443

  [ "$status" -eq 0 ]
  [[ "$output" == *'nginx'* ]]
}

@test "a port held by a container whose name cannot be read names its id" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  docker() {
    case "$*" in
      *'compose ps'* ) echo 'ours0001' ;;
      *'ps --filter publish=443'* ) echo 'other002' ;;
      # The inspect fails, but the port is held either way, and the id is
      # enough for the operator to go and look.
      * ) return 1 ;;
    esac
  }

  run _port_holder 443

  [ "$status" -eq 0 ]
  [[ "$output" == *'other002'* ]]
}

@test "an unused host port is reported as free" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # A real lookup, against the real daemon: nothing in this repo binds 65321.
  run _port_holder 65321

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a process listening on a port is named, from lsof's LISTEN row" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  lsof() {
    echo 'COMMAND   PID  USER   FD   TYPE DEVICE SIZE/OFF NODE NAME'
    echo 'nginx   41234 jason    6u  IPv4 0xabcd      0t0  TCP *:443 (LISTEN)'
  }

  run _listener_on 443

  [ "$status" -eq 0 ]
  [[ "$output" == *'nginx'* ]]
  [[ "$output" == *'41234'* ]]
}

@test "an lsof that ignores its options does not name an unrelated process" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # busybox's lsof takes no options and lists every open file it can see. Taking
  # its first row would report pid 1 as the holder of a port nothing is on --
  # a guard rail that refuses to build a perfectly buildable environment.
  lsof() {
    echo $'PID\tFD\tTYPE\tDEVICE\tSIZE/OFF\tNODE\tNAME'
    echo $'1\t0\tCHR\t136,0\t0t0\t3\t/dev/pts/0'
  }

  run _listener_on 65321

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a host with no lsof at all still reaches the connect fallback" {
  # In a fresh shell rather than bats' own, because bats runs test bodies with
  # errexit off and the trap this pins only exists with it on: under
  # `set -o pipefail` a missing lsof fails the assignment, and bin/env would end
  # mid-preflight with its stderr discarded -- silently, and before the fallback.
  run bash -c '
    set -euo pipefail
    BIN_ENV_SOURCE_ONLY=1 source bin/env
    lsof() {
      return 127
    }
    _listener_on 65321
    echo reached-the-fallback
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *'reached-the-fallback'* ]]
}

#
## Preflight -- the appliance version
#

@test "a version already in the local cache does not need the registry" {
  spec 'version: "13.5"'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _image_in_local_cache() {
    return 0
  }
  _manifest_in_registry() {
    echo 'the registry was contacted' >&2
    return 1
  }

  run _preflight_version

  [ "$status" -eq 0 ]
  [[ "$output" != *'the registry was contacted'* ]]
}

@test "a version the registry does not have fails preflight" {
  spec 'version: "13.5"'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _image_in_local_cache() {
    return 1
  }
  _manifest_in_registry() {
    echo 'no such manifest: registry.tld/conjur-appliance:13.5' >&2
    return 1
  }

  run _preflight_version

  [ "$status" -ne 0 ]
  [[ "$output" == *'13.5'* ]]
  [[ "$output" == *'no such tag'* ]]
}

@test "an unreachable registry is not reported as a missing version" {
  spec 'version: "13.5"'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _image_in_local_cache() {
    return 1
  }
  _manifest_in_registry() {
    echo 'error pinging v2 registry: dial tcp: i/o timeout' >&2
    return 1
  }

  run _preflight_version

  [ "$status" -ne 0 ]
  [[ "$output" == *'VPN'* ]]
}

@test "a registry that never answers fails in seconds rather than hanging" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  run _with_timeout 1 sleep 30

  # 124 is what timeout(1) reports, and _with_timeout exists because macOS does
  # not ship timeout(1).
  [ "$status" -eq 124 ]
}

@test "the tag is looked up in the registry the appliance is pulled from, insecurely" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  docker() {
    echo "$*"
  }

  run _manifest_in_registry 13.5

  [ "$status" -eq 0 ]
  [[ "$output" == *'registry.tld/conjur-appliance:13.5'* ]]

  # Without --insecure every tag looks unresolvable: registry.tld's certificate
  # is issued for another name, and `docker manifest` does not read the daemon's
  # insecure-registries configuration.
  [[ "$output" == *'--insecure'* ]]
}

#
## The build -- the order the phases run in
#
# The guard rails are only worth having if a refusal actually stops the run, so
# the ordering is asserted rather than left to the entrypoint reading correctly.

@test "a preflight that refuses means nothing is provisioned" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  _preflight() {
    echo 'bin/env: refused' >&2
    exit 1
  }
  _provision() {
    echo provisioned
  }
  _verify() {
    echo verified
  }

  run _build

  [ "$status" -ne 0 ]
  [[ "$output" != *'provisioned'* ]]
  [[ "$output" != *'verified'* ]]
}

@test "the build checks, then provisions, then verifies" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  _preflight() {
    echo preflight
  }
  _provision() {
    echo provision
  }
  _verify() {
    echo verify
  }

  run _build

  [ "$status" -eq 0 ]
  [[ "$output" == *preflight*provision*verify* ]]
}

#
## Provisioning
#

@test "every planned command runs, even when one of them drains stdin" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # bin/dap reaches the appliance through `docker compose exec -T`, which
  # forwards stdin. A command like that, run inside the loop that reads the
  # command list, consumes the steps after it -- and the loop then ends
  # normally, so provisioning reports success having done a third of the work.
  #
  # `wc -c` stands in for it: it drains stdin just as thoroughly, but reports
  # only a byte count, so it cannot echo the later steps back and make this pass
  # by accident the way `cat` would.
  _provision_commands() {
    echo 'wc -c'
    echo 'echo second-command-ran'
    echo 'echo third-command-ran'
  }

  # /dev/null so the stand-in sees EOF rather than blocking. The loop under test
  # supplies its own stdin, so this does not mask the bug being guarded against.
  run _provision < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *'second-command-ran'* ]]
  [[ "$output" == *'third-command-ran'* ]]

  # Announced three steps, so it really attempted three rather than reporting
  # success after the first.
  [ "$(printf '%s\n' "$output" | grep -c '^==> ')" -eq 3 ]
}

#
## Verification
#
# Two kinds of test here. Against nothing running, every dimension must come back
# as a mismatch rather than as a crash or a pass. Beyond that, each probe is called
# for real against a payload the appliance returned, because the seam a stub of the
# probe offers cannot check the question the probe asks -- see the probe tests
# below. A full happy-path environment is still a manual integration run.

@test "verification of an environment that is not running mismatches on every dimension" {
  spec 'version: "13.5"' 'sample_data: false'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  run _verify

  [ "$status" -ne 0 ]
  [[ "$output" == *'DIMENSION'* ]]
  [[ "$output" == *'DESIRED'* ]]
  [[ "$output" == *'ACTUAL'* ]]
  [[ "$output" == *'leader health'*'unreachable'*'MISMATCH'* ]]
  [[ "$output" == *'leader image tag'*'not running'*'MISMATCH'* ]]
  [[ "$output" == *'does not match the spec'* ]]
}

@test "verification counts standbys and followers rather than assuming them" {
  spec 'version: "13.5"' 'sample_data: false'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  run _verify

  # Nothing is running, so the actual counts are the 0 the spec asked for and
  # these two rows are the only ones that agree.
  [[ "$(rows)" == *'standbys running 0 0 ok'* ]]
  [[ "$(rows)" == *'followers running 0 0 ok'* ]]
}

# The probe itself, rather than a stub of it, because the trap this catches is in
# the jq filter. The body below is one the appliance really returned for a
# two-standby cluster: pg_stat_replication names the standby in `usename` -- the
# replication role `evoke seed standby <host>` creates for it -- while
# `application_name` is an opaque `standby_<hex>_<hex>` with no hostname in it.
# The seam is curl, which is the boundary this probe actually has.
@test "replication state is read from the leader's own view of each standby" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  curl() {
    cat <<'JSON'
{
  "ok": true,
  "database": {
    "replication_status": {
      "pg_stat_replication": [
        {
          "usename": "conjur-master-2.mycompany.local",
          "application_name": "standby_af7a67_d2558d33014e",
          "client_hostname": "conjur-intro-conjur-master-2.mycompany.local-1.dap_net",
          "state": "streaming",
          "sync_state": "sync"
        },
        {
          "usename": "conjur-master-3.mycompany.local",
          "application_name": "standby_f5f31e_71aca651338b",
          "client_hostname": "conjur-intro-conjur-master-3.mycompany.local-1.dap_net",
          "state": "catchup",
          "sync_state": "potential"
        }
      ]
    }
  }
}
JSON
  }

  [ "$(_standby_replication_state 2)" = 'streaming' ]

  # Reported as it is, not flattened into ok/not ok: a standby still catching up
  # is a different problem from one the leader is not shipping to at all.
  [ "$(_standby_replication_state 3)" = 'catchup' ]

  # Absent from the leader's view entirely, which is what a standby that is up
  # but never seeded looks like.
  [ "$(_standby_replication_state 4)" = 'not replicating' ]
}

@test "verification reports replication state for each standby" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  standbys: 2'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _standby_replication_state() {
    echo streaming
  }

  run _verify

  [[ "$(rows)" == *'standby 2 replication streaming streaming ok'* ]]
  [[ "$(rows)" == *'standby 3 replication streaming streaming ok'* ]]
}

@test "a standby that is up but not replicating fails verification" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  standbys: 2'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  # Both containers are up, so the count alone says the environment is fine.
  _running_standbys() {
    echo 2
  }
  _standby_replication_state() {
    if [ "$1" = 3 ]; then
      echo 'not replicating'
    else
      echo streaming
    fi
  }

  run _verify

  [ "$status" -ne 0 ]
  [[ "$(rows)" == *'standbys running 2 2 ok'* ]]
  [[ "$(rows)" == *'standby 2 replication streaming streaming ok'* ]]
  [[ "$(rows)" == *'standby 3 replication streaming not replicating MISMATCH'* ]]
}

@test "verification reports the follower's health and replication as rows of their own" {
  spec 'version: "13.5"' 'followers: 1'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _running_followers() {
    echo 1
  }
  _follower_health() {
    echo ok
  }
  _follower_replication_state() {
    echo replicating
  }
  _follower_secret_state() {
    echo retrievable
  }
  _leader_health() {
    echo ok
  }
  _leader_cluster_name() {
    echo none
  }
  _leader_image_tag() {
    echo 13.5
  }
  _sample_data_state() {
    echo loaded
  }

  run _verify

  # The one test here that asserts a clean exit, so that the follower rows are shown
  # to be capable of passing and not only of mismatching.
  [ "$status" -eq 0 ]
  [[ "$(rows)" == *'followers running 1 1 ok'* ]]
  [[ "$(rows)" == *'follower health ok ok ok'* ]]
  [[ "$(rows)" == *'follower replication replicating replicating ok'* ]]
  [[ "$(rows)" == *'follower secret read retrievable retrievable ok'* ]]
}

@test "a follower that is up but behind fails verification while the leader passes" {
  spec 'version: "13.5"' 'followers: 1'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  # The container is up and the appliance calls itself healthy, so the count and the
  # health row both agree with the spec. Replication is the only thing that does not
  # -- every other row is stubbed to pass, which is what makes the non-zero status
  # below say something about the follower rather than about an unstubbed probe.
  _running_followers() {
    echo 1
  }
  _follower_health() {
    echo ok
  }
  _follower_replication_state() {
    echo 'apply errors'
  }
  _follower_secret_state() {
    echo retrievable
  }
  _leader_health() {
    echo ok
  }
  _leader_cluster_name() {
    echo none
  }
  _leader_image_tag() {
    echo 13.5
  }
  _sample_data_state() {
    echo loaded
  }

  run _verify

  [ "$status" -ne 0 ]
  [ "$(rows | grep --count MISMATCH)" -eq 1 ]
  [[ "$(rows)" == *'leader health ok ok ok'* ]]
  [[ "$(rows)" == *'follower health ok ok ok'* ]]
  [[ "$(rows)" == *'follower replication replicating apply errors MISMATCH'* ]]
}

@test "a follower serving a stale snapshot is caught even though the secret reads back" {
  spec 'version: "13.5"' 'followers: 1'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  # `evoke seed follower` snapshots the leader's database, so a follower whose
  # replication stopped straight afterwards still answers for every secret that
  # existed at seed time. Retrievability alone would report this environment as good.
  _running_followers() {
    echo 1
  }
  _follower_health() {
    echo ok
  }
  _follower_replication_state() {
    echo disabled
  }
  _follower_secret_state() {
    echo retrievable
  }
  _leader_health() {
    echo ok
  }
  _leader_cluster_name() {
    echo none
  }
  _leader_image_tag() {
    echo 13.5
  }
  _sample_data_state() {
    echo loaded
  }

  run _verify

  [ "$status" -ne 0 ]
  [ "$(rows | grep --count MISMATCH)" -eq 1 ]
  [[ "$(rows)" == *'follower secret read retrievable retrievable ok'* ]]
  [[ "$(rows)" == *'follower replication replicating disabled MISMATCH'* ]]
}

@test "a follower the spec did not ask for gets no follower rows beyond the count" {
  spec 'version: "13.5"' 'sample_data: false'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  # A follower left running from an earlier environment. The count row reports it, so
  # it is not hidden, but the spec asked for no follower and so there is nothing for
  # the health, replication or retrieval rows to be desired against. Every other row
  # is stubbed to pass, so that none of them reaches a real curl or docker.
  _running_followers() {
    echo 1
  }
  _running_standbys() {
    echo 0
  }
  _leader_health() {
    echo ok
  }
  _leader_cluster_name() {
    echo none
  }
  _leader_image_tag() {
    echo 13.5
  }

  run _verify

  [ "$status" -ne 0 ]
  [[ "$(rows)" == *'followers running 0 1 MISMATCH'* ]]
  [[ "$(rows)" != *'follower health'* ]]
  [[ "$(rows)" != *'follower replication'* ]]
  [[ "$(rows)" != *'follower secret read'* ]]
}

# Retrieval through the follower is a claim about the sample data, so it only means
# something when the spec asked for the sample data to be there.
@test "a follower in a spec with no sample data gets no retrieval row" {
  spec 'version: "13.5"' 'followers: 1' 'sample_data: false'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _running_followers() {
    echo 1
  }
  _follower_health() {
    echo ok
  }
  _follower_replication_state() {
    echo replicating
  }
  _running_standbys() {
    echo 0
  }
  _leader_health() {
    echo ok
  }
  _leader_cluster_name() {
    echo none
  }
  _leader_image_tag() {
    echo 13.5
  }

  run _verify

  # A clean exit as well as the missing row, since a retrieval row that was still
  # probed and failed would otherwise go unnoticed.
  [ "$status" -eq 0 ]
  [[ "$(rows)" == *'follower health ok ok ok'* ]]
  [[ "$(rows)" == *'follower replication replicating replicating ok'* ]]
  [[ "$(rows)" != *'follower secret read'* ]]
}

# The other probe whose filter encodes a claim about what the appliance returns,
# and so the other one that a stub of the probe itself cannot check. The JSON below
# is what `evoke cluster member list` really printed for a three-node cluster: an
# array of etcd members, the node hostname under `name`, and not in node order --
# which is why membership is a lookup rather than a positional read.
@test "cluster membership is read from etcd's own member list" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  standbys: 2' '  auto_failover: true'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  docker() {
    case "$*" in
      *'evoke cluster member list'* )
        echo '[{"id":"3a2a0df29e279581","name":"conjur-master-2.mycompany.local","peerURLs":["http://conjur-master-2.mycompany.local:2380"],"clientURLs":["http://127.0.0.1:2379"]},{"id":"a68a1d7f860d5e20","name":"conjur-master-3.mycompany.local","peerURLs":["http://conjur-master-3.mycompany.local:2380"],"clientURLs":["http://127.0.0.1:2379"]},{"id":"b8684da58a8cba14","name":"conjur-master-1.mycompany.local","peerURLs":["http://conjur-master-1.mycompany.local:2380"],"clientURLs":["http://127.0.0.1:2379"]}]' ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_cluster_member_names | sort)" = 'conjur-master-1.mycompany.local
conjur-master-2.mycompany.local
conjur-master-3.mycompany.local' ]

  local members
  members="$(_cluster_member_names)"

  [ "$(_cluster_membership_state 1 "$members")" = 'enrolled' ]
  [ "$(_cluster_membership_state 3 "$members")" = 'enrolled' ]

  # Node 4 is in no cluster because the spec asked for two standbys, and the
  # hostname is a prefix of nothing in the list -- the match has to be the whole
  # line, not a substring of one.
  [ "$(_cluster_membership_state 4 "$members")" = 'missing' ]
}

# An appliance that answers with something other than a member list must read as
# nothing enrolled rather than crash the run or, worse, pass: `set -o pipefail`
# plus a jq that cannot parse is exactly the combination that took bin/env down
# once before.
@test "an unparseable member list reads as nothing enrolled" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  docker() {
    echo 'Error: etcdserver: request timed out'
  }

  run _cluster_member_names

  # The status as much as the output: bin/env runs under `set -o pipefail`, so a
  # jq that cannot parse takes the whole pipeline down with it -- at the exact
  # moment verification is trying to report what it found.
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_cluster_membership_state 1 "$output")" = 'missing' ]
}

@test "an enrolled cluster is verified node by node, not just by the leader's health" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  standbys: 2' '  auto_failover: true'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _cluster_member_names() {
    echo 'conjur-master-1.mycompany.local'
    echo 'conjur-master-2.mycompany.local'
    echo 'conjur-master-3.mycompany.local'
  }

  run _verify

  [[ "$(rows)" == *'cluster member 1 enrolled enrolled ok'* ]]
  [[ "$(rows)" == *'cluster member 2 enrolled enrolled ok'* ]]
  [[ "$(rows)" == *'cluster member 3 enrolled enrolled ok'* ]]
}

@test "a node missing from the cluster fails verification, naming the node" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  standbys: 2' '  auto_failover: true'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  # The enrolment of the last standby did not take. etcd has a quorum without it,
  # so the cluster is up and the leader is healthy -- and a failover would have
  # one fewer node to elect from than the spec asked for.
  _cluster_member_names() {
    echo 'conjur-master-1.mycompany.local'
    echo 'conjur-master-2.mycompany.local'
  }

  run _verify

  [ "$status" -ne 0 ]
  [[ "$(rows)" == *'cluster member 2 enrolled enrolled ok'* ]]
  [[ "$(rows)" == *'cluster member 3 enrolled missing MISMATCH'* ]]
}

@test "a spec without auto-failover is not checked for cluster membership" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  standbys: 2'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  run _verify

  [[ "$output" != *'cluster member'* ]]
}

# The membership rows say a node is in the cluster etcd holds; they do not say
# which cluster that is. The name gets its own row so the expected value is on the
# table rather than implied by the auto-failover row reading `true`.
@test "the cluster's name is verified as a row of its own" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  standbys: 2' '  auto_failover: true'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _leader_cluster_name() {
    echo staging
  }

  run _verify

  [ "$status" -ne 0 ]
  [[ "$(rows)" == *'cluster name production staging MISMATCH'* ]]
}

@test "a spec without auto-failover has no cluster name row" {
  spec 'version: "13.5"' 'sample_data: false'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  run _verify

  [[ "$output" != *'cluster name'* ]]
}

@test "a cluster enrolled under an unexpected name is reported by that name" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # bin/dap enrols into `production`, and /info reports no cluster at all on a
  # standalone leader. Anything else is neither, and naming it is more use than
  # the word `unknown` -- the name is the thing the operator has to reconcile.
  [ "$(_auto_failover_state production)" = 'true' ]
  [ "$(_auto_failover_state none)" = 'false' ]
  [ "$(_auto_failover_state staging)" = 'cluster staging' ]
  [ "$(_auto_failover_state unreachable)" = 'unreachable' ]
}

@test "a standby the spec did not ask for gets no replication row" {
  spec 'version: "13.5"' 'sample_data: false'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  run _verify

  [[ "$output" != *'replication'* ]]
}

# The rest of the probes, each called for real against the seam it actually has:
# curl for the two API reads, docker for the image tag, bin/api for the sample data.
# Stubbing a probe checks what _verify does with an answer, never whether the probe
# asked the right question -- which is how a filter keyed on the wrong field once
# reported a healthy cluster as not replicating. Payloads below came off a live
# appliance; where a case cannot be captured from a working environment, the comment
# says what was changed and why that is all the code under test reads.

@test "leader health is read from the flag /health sets, not from the request succeeding" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # Trimmed to what the filter can see. Note `services.ok`: the appliance rolls the
  # service list up under its own `ok`, and reading that one would call a leader
  # healthy while its database or its cluster was not. The top-level flag is the
  # one that accounts for those, so it is the one this reads.
  curl() {
    cat <<'JSON'
{
  "ok": true,
  "degraded": false,
  "role": "master",
  "services": { "possum": "ok", "ui": "ok", "ldap-sync": "disabled", "ok": true }
}
JSON
  }

  [ "$(_leader_health)" = 'ok' ]

  # The same body with the flag flipped, which is all this filter reads. An
  # appliance reporting itself unhealthy still answers the request, so the body is
  # the only signal there is.
  curl() {
    cat <<'JSON'
{
  "ok": false,
  "degraded": true,
  "role": "master",
  "services": { "possum": "ok", "ui": "ok", "ldap-sync": "disabled", "ok": true }
}
JSON
  }

  [ "$(_leader_health)" = 'not ok' ]
}

@test "an answer that is not the JSON expected is distinguished from no answer" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # What the load balancer in front of the leader really returns for a route it
  # will not serve: a bare string, and a request that succeeded. Every probe goes
  # through this, so getting it wrong would print `null` into the table instead.
  curl() {
    printf 'Authorization missing'
  }

  [ "$(_leader_health)" = 'unparseable' ]
  [ "$(_leader_cluster_name)" = 'unparseable' ]

  # Nothing listening is a different finding, and the operator acts on it
  # differently: unreachable means bring the environment up, unparseable means look
  # at what answered instead.
  curl() {
    return 7
  }

  [ "$(_leader_health)" = 'unreachable' ]
}

@test "the cluster name is read from the leader's own configuration" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # Captured from the enrolled cluster, trimmed to the configuration block.
  # cluster_name is the field bin/dap itself reads to decide a cluster exists.
  curl() {
    cat <<'JSON'
{
  "release": "13.10.0",
  "role": "master",
  "configuration": {
    "conjur": {
      "account": "demo",
      "cluster_leader": "conjur-master-1.mycompany.local",
      "cluster_machine_name": "conjur-master-1.mycompany.local",
      "cluster_name": "production",
      "role": "master"
    }
  }
}
JSON
  }

  [ "$(_leader_cluster_name)" = 'production' ]

  # A standalone leader answers with a configuration that has no cluster in it. That
  # has to read as `none` and not as a broken probe, because it is the answer every
  # single-node environment gives.
  curl() {
    cat <<'JSON'
{
  "release": "13.10.0",
  "role": "master",
  "configuration": { "conjur": { "account": "demo", "role": "master" } }
}
JSON
  }

  [ "$(_leader_cluster_name)" = 'none' ]

  # JSON, but not /info at all. Reporting `none` here would be a wrong answer
  # stated confidently -- `no cluster` and `no idea` are not the same finding.
  curl() {
    echo '{"error":"service unavailable"}'
  }

  [ "$(_leader_cluster_name)" = 'unparseable' ]
}

@test "the leader's image tag is read off the running container" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # Both calls answering as the live leader's did.
  docker() {
    case "$*" in
      *'compose ps --quiet'* ) echo '396b878841751df0aa5a37920181343d7028d8f643466cfcf8479ec51a05fe9f' ;;
      *inspect* ) echo 'registry.tld/conjur-appliance:5.0-stable' ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_image_tag)" = '5.0-stable' ]

  # A registry with a port in it has two colons, so the tag is what follows the
  # last one. Splitting on the first would report the tag as `5000/conjur-...`.
  docker() {
    case "$*" in
      *'compose ps --quiet'* ) echo 'a6e6ff3b1c0a' ;;
      *inspect* ) echo 'registry.tld:5000/conjur-appliance:13.5' ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_image_tag)" = '13.5' ]

  # A container that exists but that docker will not describe. Distinct from `not
  # running`, which is the answer when there is no container at all.
  docker() {
    case "$*" in
      *'compose ps --quiet'* ) echo 'a6e6ff3b1c0a' ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_image_tag)" = 'unknown' ]
}

# A follower answers /health on its own port, and the probe has to ask it there.
# This is the one probe where the payloads below differ between hosts in a way that
# hides a mistake: the leader answers /health too, and answers it `ok`, so a
# follower probe pointed at the leader would report a healthy follower whether or
# not one exists. The stub therefore answers by port rather than unconditionally.
@test "follower health is read from the follower, not from whatever answers /health" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # Both bodies as the live pair returned them, trimmed to what the filters see.
  curl() {
    case "$*" in
      *localhost:450* ) echo '{"ok":true,"degraded":false,"role":"follower"}' ;;
      *localhost:443* ) echo '{"ok":true,"degraded":false,"role":"master"}' ;;
      * ) return 7 ;;
    esac
  }

  [ "$(_follower_health)" = 'ok' ]

  # Only the follower is unhealthy. A probe reading the leader's answer would still
  # say ok here, which is the whole point of the check.
  curl() {
    case "$*" in
      *localhost:450* ) echo '{"ok":false,"degraded":true,"role":"follower"}' ;;
      *localhost:443* ) echo '{"ok":true,"degraded":false,"role":"master"}' ;;
      * ) return 7 ;;
    esac
  }

  [ "$(_follower_health)" = 'not ok' ]
  [ "$(_leader_health)" = 'ok' ]

  # And the follower down while the leader is up, which is the state the whole row
  # exists to surface.
  curl() {
    case "$*" in
      *localhost:443* ) echo '{"ok":true,"degraded":false,"role":"master"}' ;;
      * ) return 7 ;;
    esac
  }

  [ "$(_follower_health)" = 'unreachable' ]
}

# Followers replicate logically, over pglogical subscriptions, so there is no row
# for them in the leader's pg_stat_replication -- which is why this is a second
# probe rather than a reuse of the standby one. It reads the follower's own view for
# two reasons: it still answers when the leader is unreachable, and a follower can
# be receiving WAL while failing to apply it, which the leader's view calls
# `streaming`. The subscription name is an opaque `follower_<hex>_<hex>` with no
# hostname in it, so there is nothing to key on -- a follower has exactly its own
# subscriptions.
@test "follower replication is read from the follower's own subscriptions" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # Both hosts answering as the live pair really did, keyed on port so that the host
  # is part of what is asserted. The leader's body is the interesting half:
  # `subscriptions` comes back as a *sentence*, not an array. Reading it as an empty
  # list would report `not replicating` for a cluster that is fine, and a filter that
  # only counted a non-empty array would call the leader a replicating follower.
  curl() {
    case "$*" in
      *localhost:450* )
        cat <<'JSON'
{
  "ok": true,
  "role": "follower",
  "database": {
    "ok": true,
    "logical_replication_status": {
      "subscriptions": [
        {
          "name": "follower_41f474_532e785c995b",
          "enabled": true,
          "received_lsn": "0/68C2D58",
          "last_msg_send_time": "2026-09-23 01:02:05 +0000",
          "last_msg_receipt_time": "2026-09-23 01:02:05 +0000",
          "apply_error_count": 0,
          "sync_error_count": 0,
          "replication_sets": ["default", "full"]
        }
      ],
      "initial_replication_in_progress": false
    }
  }
}
JSON
        ;;
      *localhost:443* )
        cat <<'JSON'
{
  "ok": true,
  "role": "master",
  "database": {
    "logical_replication_status": {
      "subscriptions": "Subscriptions are only available on Conjur Followers.",
      "initial_replication_in_progress": false
    }
  }
}
JSON
        ;;
      * ) return 7 ;;
    esac
  }

  [ "$(_follower_replication_state)" = 'replicating' ]

  # The same probe pointed at the leader, which is the mistake this guards against.
  # Verified live as well: it reads `not a follower` against conjur-master-1.
  CONJUR_FOLLOWER_PORT="$CONJUR_MASTER_PORT"

  [ "$(_follower_replication_state)" = 'not a follower' ]
}

# The failure cases, each derived from the captured body above by changing only the
# field the filter reads. A follower that is up, healthy and serving from a stale
# snapshot answers `ok` on /health, so these are the rows that tell the difference.
@test "a follower that is up but behind or disconnected fails its replication check" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  follower_health_body() {
    cat <<JSON
{ "ok": true, "role": "follower", "database": { "logical_replication_status": {
  "subscriptions": $1, "initial_replication_in_progress": ${2:-false} } } }
JSON
  }

  # Configured as a follower, subscribed to nothing: what a follower brought up
  # without `evoke configure follower` ever completing looks like.
  curl() { follower_health_body '[]'; }
  [ "$(_follower_replication_state)" = 'not replicating' ]

  # Still copying the leader's database. Reported as its own state rather than as a
  # failure of replication, because it is a stage every follower passes through.
  curl() { follower_health_body '[{"enabled":true,"apply_error_count":0,"sync_error_count":0}]' true; }
  [ "$(_follower_replication_state)" = 'initial sync' ]

  # The subscription exists but is not running, which is what `evoke replication
  # stop` leaves behind -- and the state in which the follower keeps serving the
  # data it already has.
  curl() { follower_health_body '[{"enabled":false,"apply_error_count":0,"sync_error_count":0}]'; }
  [ "$(_follower_replication_state)" = 'disabled' ]

  # Receiving changes and failing to apply them. This is the case the leader's own
  # pg_stat_replication would call `streaming`.
  curl() { follower_health_body '[{"enabled":true,"apply_error_count":3,"sync_error_count":0}]'; }
  [ "$(_follower_replication_state)" = 'apply errors' ]

  curl() { follower_health_body '[{"enabled":true,"apply_error_count":0,"sync_error_count":2}]'; }
  [ "$(_follower_replication_state)" = 'sync errors' ]

  # No replication block at all, which is what an older appliance answers. Distinct
  # from every state above: the probe has no view, rather than a bad one.
  curl() { echo '{"ok":true,"role":"follower","database":{"ok":true}}'; }
  [ "$(_follower_replication_state)" = 'unparseable' ]
}

@test "sample data is verified by retrieving a secret, not by the fetch succeeding" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # What bin/api --fetch-secrets really prints against a leader carrying the sample
  # policy: the values themselves.
  bin/api() {
    cat <<'JSON'
{
  "demo:variable:staging/my-app-1/postgres-database/password": "secret-p@ssword-staging-my-app-1",
  "demo:variable:staging/my-app-1/postgres-database/port": "5432",
  "demo:variable:staging/my-app-1/postgres-database/url": "staging.my-app-1.staging.mycompany-postgres.com/my-app",
  "demo:variable:staging/my-app-1/postgres-database/username": "my-app-1"
}
JSON
  }

  [ "$(_sample_data_state)" = 'loaded' ]

  # The same fetch succeeding with nothing to show, which is what a leader whose
  # policy loaded but whose values never got set looks like. The exit status alone
  # would call this loaded.
  bin/api() {
    echo '{}'
  }

  [ "$(_sample_data_state)" = 'not retrievable' ]

  # And the fetch failing outright, where there is no output to grep at all.
  bin/api() {
    return 1
  }

  [ "$(_sample_data_state)" = 'not retrievable' ]
}

# The check the ticket asks for is that the secret comes back *through the
# follower*, and the trap is that bin/api will happily answer without going near
# one. Its fetch_secrets always reads from the master URL, so --against-master only
# changes where it authenticates: a follower check written that way passes against a
# follower that was never provisioned. Pointing --leader-url at the follower load
# balancer is what makes the read go through the follower, so that argument is the
# thing under test here.
@test "the sample secret is read through the follower, not through the leader" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  bin/api() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/api-args"
    cat <<'JSON'
{
  "demo:variable:staging/my-app-1/postgres-database/password": "secret-p@ssword-staging-my-app-1",
  "demo:variable:staging/my-app-1/postgres-database/username": "my-app-1"
}
JSON
  }

  [ "$(_follower_secret_state)" = 'retrievable' ]

  run cat "$BATS_TEST_TMPDIR/api-args"
  [[ "$output" == *'--leader-url https://conjur-follower.mycompany.local'* ]]
  [[ "$output" == *'--fetch-secrets'* ]]
  [[ "$output" != *'--against-master'* ]]
}

@test "a follower that answers the fetch with nothing is not retrievable" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # A follower whose own database is empty authenticates and answers, so the exit
  # status says the read worked. The value is the only evidence that it did.
  bin/api() {
    echo '{}'
  }

  [ "$(_follower_secret_state)" = 'not retrievable' ]

  bin/api() {
    return 1
  }

  [ "$(_follower_secret_state)" = 'not retrievable' ]
}

#
## Usage
#

@test "a spec is required" {
  run bin/env --plan

  [ "$status" -ne 0 ]
  [[ "$output" == *'spec file is required'* ]]
}

@test "a missing spec file is reported as such" {
  run bin/env --plan "$BATS_TEST_TMPDIR/absent.yml"

  [ "$status" -ne 0 ]
  [[ "$output" == *'no such spec'* ]]
}

@test "an unrecognised option is refused" {
  run bin/env --recreate-everything "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'not a valid option'* ]]
}

@test "two specs are refused rather than one being ignored" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC" "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'only one spec'* ]]
}

@test "help mentions the plan flag and exits cleanly" {
  run bin/env --help

  [ "$status" -eq 0 ]
  [[ "$output" == *'--plan'* ]]
}
