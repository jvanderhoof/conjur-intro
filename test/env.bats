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
## Topology this pass cannot build yet
#
# The schema's ceilings, not a conditional in bin/env, are what refuse these --
# so a hand-written spec fails exactly where a generated one does, and never
# gets far enough to build something smaller than it asked for.

@test "standbys are refused by the schema, naming the pointer" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/standbys'* ]]
  [[ "$output" == *'standbys are not provisioned yet'* ]]
  [[ "$output" == *'nothing was provisioned'* ]]
}

@test "auto-failover is refused by the schema" {
  spec 'version: "13.5"' 'leader:' '  auto_failover: true'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/auto_failover'* ]]
  [[ "$output" == *'auto-failover is not provisioned yet'* ]]
}

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
