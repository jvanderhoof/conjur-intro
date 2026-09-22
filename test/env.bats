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
  docker build --quiet --tag conjur-intro/env-validator:1 artifacts/env-validator > /dev/null
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
## Topology this pass cannot build yet
#
# Same mechanism as the ceiling above, for a dimension that has no supported
# range at all yet.

@test "a follower is refused by the schema" {
  spec 'version: "13.5"' 'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/followers'* ]]
  [[ "$output" == *'followers are not provisioned yet'* ]]
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
# Only the failure side can be checked without a real appliance: with nothing
# running, every dimension must come back as a mismatch rather than as a crash
# or a pass. The happy path is a manual integration run.

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
