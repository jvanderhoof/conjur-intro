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
