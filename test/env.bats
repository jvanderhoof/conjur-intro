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
  # build in it. The tag is bin/env's VALIDATOR_IMAGE and has to move with it.
  docker build --quiet --tag conjur-intro/env-validator:5 artifacts/env-validator > /dev/null
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

# Stubs the three hardening probes with the answers a leader provisioned without
# any of them gives, for verification tests about something else that need every
# other row to pass.
stub_unhardened_leader() {
  _leader_key_encryption_state() {
    echo 'not encrypted'
  }
  _leader_certificate_state() {
    echo 'appliance CA'
  }
  _leader_dh_params_state() {
    echo 'pre-generated'
  }
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
  [[ "$(rows)" == *"version 13.5"* ]]
  [[ "$(rows)" == *"leader.standbys 0"* ]]
  [[ "$(rows)" == *"leader.auto_failover false"* ]]
  [[ "$(rows)" == *"followers 0"* ]]
  [[ "$(rows)" == *"sample_data true"* ]]
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
bin/dap --version 13.5 --follower-count 1 --provision-follower
bin/dap --follower-count 1 --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
}

@test "the tracked leader-and-follower example plans a follower and its proxy trust" {
  run bin/env --plan environments/examples/leader-and-follower.yml

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 5.0-stable --provision-master
bin/dap --wait-for-master
bin/dap --version 5.0-stable --follower-count 1 --provision-follower
bin/dap --follower-count 1 --trust-follower-proxy
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
  [[ "$(plan_commands)" == *'bin/dap --version 13.5 --follower-count 1 --provision-follower'* ]]
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
bin/dap --version 13.5 --follower-count 1 --provision-follower
bin/dap --follower-count 1 --trust-follower-proxy
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
  [[ "$(plan_checks)" == *'follower 1 /health reports ok'* ]]
  [[ "$(plan_checks)" == *'follower 1 is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'retrievable through the follower load balancer'* ]]
  [[ "$(plan_checks)" == *'follower load balancer routes to 1 follower'* ]]
}

# Each follower is its own finding, the way each standby is: one that is down or
# behind has to be named, not averaged into the tier.
@test "plan mode lists health and replication checks for each follower" {
  spec 'version: "13.5"' 'followers: 3'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'followers running is 3'* ]]
  [[ "$(plan_checks)" == *'follower 1 /health reports ok'* ]]
  [[ "$(plan_checks)" == *'follower 2 /health reports ok'* ]]
  [[ "$(plan_checks)" == *'follower 3 /health reports ok'* ]]
  [[ "$(plan_checks)" == *'follower 1 is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'follower 2 is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'follower 3 is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'follower load balancer routes to 3 followers'* ]]
}

@test "every follower asked for is provisioned, and trusts its load balancer" {
  spec 'version: "13.5"' 'followers: 2'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --provision-master
bin/dap --wait-for-master
bin/dap --version 13.5 --follower-count 2 --provision-follower
bin/dap --follower-count 2 --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
}

@test "the tracked multiple-followers example plans two followers behind the load balancer" {
  run bin/env --plan environments/examples/multiple-followers.yml

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 5.0-stable --provision-master
bin/dap --wait-for-master
bin/dap --version 5.0-stable --follower-count 2 --provision-follower
bin/dap --follower-count 2 --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
  [[ "$(plan_checks)" == *'follower 2 is replicating from the leader'* ]]
  [[ "$(plan_checks)" == *'follower load balancer routes to 2 followers'* ]]
}

@test "a spec with no follower lists no follower checks beyond the count" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'followers running is 0'* ]]
  [[ "$(plan_checks)" != *'follower 1'* ]]
  [[ "$(plan_checks)" != *'follower load balancer'* ]]
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

# docker-compose.yml publishes follower 1 on CONJUR_FOLLOWER_PORT and the others on
# 450 plus their number, stepping over 451 -- CONJUR_K8S_FOLLOWER_PORT's default.
@test "each follower's own host port is part of preflight" {
  spec 'version: "13.5"' 'followers: 3'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_preflight)" == *'host ports 443, 444, 7000, 80, 449, 450, 452, 453, 7001 are free'* ]]
}

@test "the follower ports stay out of preflight when no follower is asked for" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_preflight)" == *'host ports 443, 444, 7000 are free'* ]]
}

#
## Leader hardening -- master key encryption, custom certificates, DH parameters
#
# Three independent booleans that share one insertion point: each is done to the
# leader around configure time, and before any other node is seeded from it,
# because a seed carries the leader's keys, certificates and DH parameters to
# whatever it seeds. Getting that ordering wrong is the whole risk, which is why
# the plan is what these pin.

@test "a spec with no hardening flags plans none of the hardening steps" {
  spec 'version: "13.5"'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(rows)" == *"leader.master_key_encryption false"* ]]
  [[ "$(rows)" == *"leader.custom_certificates false"* ]]
  [[ "$(rows)" == *"leader.generate_dh false"* ]]
  [[ "$(plan_commands)" != *'--enable-mke'* ]]
  [[ "$(plan_commands)" != *'--import-custom-certificates'* ]]
  [[ "$(plan_commands)" != *'--generate-dh'* ]]
  [[ "$(plan_commands)" != *'--wait-for-dh-params'* ]]
}

@test "generated DH parameters are asked for at configure time, then waited for" {
  spec 'version: "13.5"' 'leader:' '  generate_dh: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # --generate-dh is not a step of its own: it changes what --provision-master does,
  # by keeping the pre-generated parameters out of the place `evoke configure
  # master` looks for them. The appliance then generates its own in the background,
  # at idle priority, which is why there is a wait -- a leader checked the moment
  # it is healthy is still serving the bootstrap group.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --generate-dh --provision-master
bin/dap --wait-for-master
bin/dap --wait-for-dh-params
bin/api --load-sample-policy-and-values' ]
}

@test "custom certificates are imported once the leader is configured and healthy" {
  spec 'version: "13.5"' 'leader:' '  custom_certificates: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # `evoke ca import` replaces a certificate the leader already has, so it needs a
  # configured leader -- and it needs to precede the sample data only for the
  # retrievability check to have been made over the certificate the spec asked for.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --provision-master
bin/dap --wait-for-master
bin/dap --import-custom-certificates
bin/api --load-sample-policy-and-values' ]
}

@test "master key encryption is enabled on the configured leader, and waited out" {
  spec 'version: "13.5"' 'leader:' '  master_key_encryption: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # Unlocking the encrypted keys restarts nginx, postgres and conjur, so the leader
  # is waited for again before anything else talks to it.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --provision-master
bin/dap --wait-for-master
bin/dap --enable-mke
bin/dap --wait-for-master
bin/api --load-sample-policy-and-values' ]
}

@test "all three hardening options are applied to the leader before any node is seeded" {
  spec 'version: "13.5"' \
    'leader:' \
    '  standbys: 2' \
    '  auto_failover: true' \
    '  master_key_encryption: true' \
    '  custom_certificates: true' \
    '  generate_dh: true' \
    'followers: 1'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]

  # Certificates before encryption, so the keys they import are encrypted along
  # with the rest -- imported afterwards, they would sit on disk in plaintext
  # beside keys that are not. Encryption before any seed, because bin/dap
  # configures a standby or follower with the master key only when the leader
  # already has one. And the DH wait before any seed too, so the standbys and the
  # follower inherit the generated parameters rather than the bootstrap group.
  [ "$(plan_commands)" = 'bin/dap --version 13.5 --standby-count 2 --generate-dh --provision-master
bin/dap --wait-for-master
bin/dap --import-custom-certificates
bin/dap --enable-mke
bin/dap --wait-for-master
bin/dap --wait-for-dh-params
bin/dap --version 13.5 --standby-count 2 --provision-standbys
bin/dap --standby-count 2 --enable-auto-failover
bin/dap --version 13.5 --follower-count 1 --provision-follower
bin/dap --follower-count 1 --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
}

@test "the tracked hardened example plans certificates and encryption before any seed" {
  run bin/env --plan environments/examples/hardened.yml

  [ "$status" -eq 0 ]
  [ "$(plan_commands)" = 'bin/dap --version 5.0-stable --standby-count 2 --provision-master
bin/dap --wait-for-master
bin/dap --import-custom-certificates
bin/dap --enable-mke
bin/dap --wait-for-master
bin/dap --version 5.0-stable --standby-count 2 --provision-standbys
bin/dap --standby-count 2 --enable-auto-failover
bin/dap --version 5.0-stable --follower-count 1 --provision-follower
bin/dap --follower-count 1 --trust-follower-proxy
bin/api --load-sample-policy-and-values' ]
}

# Checked whether or not they were asked for, like auto-failover: a leader that
# is encrypted, or serving a custom chain, when the spec said it would not be is
# as much a different environment as the reverse.
@test "plan mode lists a hardening check for each option, whichever way it is set" {
  spec 'version: "13.5"' 'leader:' '  custom_certificates: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'leader server keys are not encrypted with a master key'* ]]
  [[ "$(plan_checks)" == *'leader presents a certificate issued by the custom CA'* ]]
  [[ "$(plan_checks)" == *'leader DH parameters are the pre-generated files/dhparam.pem'* ]]

  spec 'version: "13.5"' 'leader:' '  master_key_encryption: true' '  generate_dh: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
  [[ "$(plan_checks)" == *'leader server keys are encrypted with a master key'* ]]
  [[ "$(plan_checks)" == *'leader presents a certificate issued by its own appliance CA'* ]]
  [[ "$(plan_checks)" == *'leader DH parameters were generated by the leader'* ]]
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

@test "custom certificates with more standbys than the certificate names are refused" {
  spec 'version: "13.5"' 'leader:' '  standbys: 3' '  custom_certificates: true'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/standbys'* ]]
  [[ "$output" == *'maximum of 2'* ]]
  [[ "$output" == *'dap-master.json'* ]]
  [[ "$output" == *'nothing was provisioned'* ]]
}

@test "custom certificates with as many standbys as the certificate names validate" {
  spec 'version: "13.5"' 'leader:' '  standbys: 2' '  custom_certificates: true'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

@test "the certificate rule does not fire when custom certificates are off" {
  spec 'version: "13.5"' 'leader:' '  standbys: 4'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

@test "the hardening flags are booleans" {
  spec 'version: "13.5"' 'leader:' '  master_key_encryption: yes please'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/leader/master_key_encryption'* ]]
  [[ "$output" == *"is not of type 'boolean'"* ]]
}

#
## The follower tier -- how far the schema lets a spec go
#
# Same mechanism again, one tier down. docker-compose.yml defines
# conjur-follower-1 through conjur-follower-3, so a fourth follower would need a
# new compose service. Four is refused here rather than provisioning three and
# reporting a mismatch for the other.

@test "more followers than the compose topology defines is a schema error" {
  spec 'version: "13.5"' 'followers: 4'

  run bin/env --plan "$SPEC"

  [ "$status" -ne 0 ]
  [[ "$output" == *'/followers'* ]]
  [[ "$output" == *'maximum of 3'* ]]
  [[ "$output" == *'conjur-follower-3'* ]]
  [[ "$output" == *'nothing was provisioned'* ]]
}

@test "the largest follower count the compose topology supports validates" {
  spec 'version: "13.5"' 'followers: 3'

  run bin/env --plan "$SPEC"

  [ "$status" -eq 0 ]
}

#
## The follower load balancer's config
#
# Generated at provisioning time, the way the leader's is, with one backend per
# follower. bin/dap and bin/podman-dap both mount it, so the generator lives in
# bin/utils.sh, and reads the count from FOLLOWER_COUNT -- bin/dap's
# --follower-count -- defaulting to the single follower bin/podman-dap builds.

# The server lines of the follower load balancer's www-backend.
follower_backend_servers() {
  source bin/utils.sh
  _follower_proxy_config | awk '/^backend www-backend$/{ found = 1; next } found && /^#/{ exit } found' \
    | grep '^  server '
}

@test "the follower load balancer's config has one backend by default, conjur-follower-1" {
  run follower_backend_servers

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == '  server conjur-follower-1 conjur-follower-1.mycompany.local:443 '* ]]
}

@test "the follower load balancer's config has a backend per follower asked for" {
  FOLLOWER_COUNT=3 run follower_backend_servers

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == '  server conjur-follower-1 conjur-follower-1.mycompany.local:443 '* ]]
  [[ "${lines[1]}" == '  server conjur-follower-2 conjur-follower-2.mycompany.local:443 '* ]]
  [[ "${lines[2]}" == '  server conjur-follower-3 conjur-follower-3.mycompany.local:443 '* ]]
}

# The whole line rather than fragments of it: every option once. It used to carry
# `check port 443` twice and `ca-file` twice, which HAProxy accepted silently --
# and which a fragment match passes either way. check-ssl takes its CA from the
# server's own `ca-file`, so the one covers both the traffic and the health check.
@test "the follower backend is health-checked and verified against the leader's CA" {
  FOLLOWER_COUNT=2 run follower_backend_servers

  [ "${lines[0]}" = '  server conjur-follower-1 conjur-follower-1.mycompany.local:443 check port 443 check-ssl ssl ca-file /etc/ssl/certs/ca.pem resolvers docker init-addr none' ]
  [ "${lines[1]}" = '  server conjur-follower-2 conjur-follower-2.mycompany.local:443 check port 443 check-ssl ssl ca-file /etc/ssl/certs/ca.pem resolvers docker init-addr none' ]
}

@test "the follower load balancer balances its backends round-robin" {
  source bin/utils.sh
  run _follower_proxy_config

  [[ "$output" == *$'backend www-backend\n  balance roundrobin\n'* ]]
}

# The load balancer starts before the follower is necessarily resolvable, so
# the backend is resolved through docker's DNS at runtime rather than at start.
@test "the follower backend is resolved through docker's DNS after the load balancer starts" {
  source bin/utils.sh
  run _follower_proxy_config

  [[ "$output" == *$'resolvers docker\n  nameserver dns1 127.0.0.11:53'* ]]

  run follower_backend_servers
  [[ "${lines[0]}" == *' resolvers docker init-addr none' ]]
}

@test "the follower load balancer terminates TLS with the follower's certificate" {
  source bin/utils.sh
  run _follower_proxy_config

  [[ "$output" == *'  bind *:443 ssl crt /etc/ssl/certs/conjur-follower.mycompany.local.pem'* ]]
}

@test "writing the follower load balancer's config creates its directory" {
  source bin/utils.sh
  dir="$BATS_TEST_TMPDIR/haproxy/follower"

  _set_follower_proxy_config "$dir"

  [ "$(cat "$dir/haproxy.cfg")" = "$(_follower_proxy_config)" ]
}

# bin/dap itself, one level below bin/env's plan: that --follower-count brings up
# the followers asked for and only those. It runs against a docker that records
# what it was asked to do and does nothing, and under --dry-run, which makes
# bin/dap echo what it would run inside a container rather than run it. Neither
# is enough alone: --dry-run still starts and removes compose services for real.

# Runs bin/dap with the given arguments against a docker that logs every call to
# $DOCKER_LOG. `docker compose exec` fails, which is what bin/dap reads as the
# leader having no master key, so the MKE steps stay out of the way.
run_dap_with_fake_docker() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  cat > "$BATS_TEST_TMPDIR/bin/docker" << EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$DOCKER_LOG"
[[ "\$1 \$2" != 'compose exec' ]]
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bin/dap --dry-run "$@"
}

@test "bin/dap --provision-follower starts only the followers asked for" {
  run_dap_with_fake_docker --follower-count 2 --provision-follower

  [ "$status" -eq 0 ]
  grep -qx 'docker compose up --no-deps --detach conjur-follower-1.mycompany.local' "$DOCKER_LOG"
  grep -qx 'docker compose up --no-deps --detach conjur-follower-2.mycompany.local' "$DOCKER_LOG"
  ! grep -q 'conjur-follower-3' "$DOCKER_LOG"
}

# One seed, so that the leader's master key is decrypted and re-encrypted once
# however many followers there are -- but a copy of it per follower, because
# `evoke unpack seed` removes the file it unpacks. Followers sharing one file got as
# far as the second, which found nothing to unpack.
@test "bin/dap --provision-follower configures every follower from its own copy of one seed" {
  run_dap_with_fake_docker --follower-count 2 --provision-follower

  [ "$status" -eq 0 ]
  [ "$(grep -c 'evoke seed follower' <<< "$output")" -eq 1 ]
  [[ "$output" == *'(on conjur-master-1.mycompany.local): docker exec cyberark-dap set -o pipefail; evoke seed follower conjur-follower.mycompany.local | tee /opt/cyberark/dap/seeds/follower-seed-1.tar /opt/cyberark/dap/seeds/follower-seed-2.tar > /dev/null'* ]]
  [[ "$output" == *'(on conjur-follower-1.mycompany.local): docker exec cyberark-dap evoke unpack seed /opt/cyberark/dap/seeds/follower-seed-1.tar && evoke configure follower'* ]]
  [[ "$output" == *'(on conjur-follower-2.mycompany.local): docker exec cyberark-dap evoke unpack seed /opt/cyberark/dap/seeds/follower-seed-2.tar && evoke configure follower'* ]]
  [[ "$output" != *'on conjur-follower-3'* ]]
  [[ "$output" != *'follower-seed-3'* ]]
}

# The follower-certs volume is shared by follower 1 and the load balancer only;
# the load balancer's certificate is copied out of follower 1 and nowhere else.
@test "bin/dap --provision-follower copies the load balancer's certificate from follower 1 alone" {
  run_dap_with_fake_docker --follower-count 3 --provision-follower

  [ "$status" -eq 0 ]
  [ "$(grep -c 'conjur-follower.mycompany.local.pem' <<< "$output")" -eq 3 ]
  [ "$(grep 'conjur-follower.mycompany.local.pem' <<< "$output" | grep -vc 'on conjur-follower-1.mycompany.local')" -eq 0 ]
}

@test "bin/dap --provision-follower defaults to the one follower" {
  run_dap_with_fake_docker --provision-follower

  [ "$status" -eq 0 ]
  grep -qx 'docker compose up --no-deps --detach conjur-follower-1.mycompany.local' "$DOCKER_LOG"
  ! grep -q 'conjur-follower-2' "$DOCKER_LOG"
}

@test "bin/dap --trust-follower-proxy trusts the load balancer on every follower" {
  run_dap_with_fake_docker --follower-count 3 --trust-follower-proxy

  [ "$status" -eq 0 ]
  [[ "$output" == *'(on conjur-follower-1.mycompany.local): docker exec cyberark-dap evoke proxy add 12.16.23.16'* ]]
  [[ "$output" == *'(on conjur-follower-2.mycompany.local): docker exec cyberark-dap evoke proxy add 12.16.23.16'* ]]
  [[ "$output" == *'(on conjur-follower-3.mycompany.local): docker exec cyberark-dap evoke proxy add 12.16.23.16'* ]]
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

  # The spec asked for none of the hardening, so a probe that fell back to its
  # "off" answer when there was no leader to ask would pass here.
  [[ "$(rows)" == *'master key encryption not encrypted unreadable MISMATCH'* ]]
  [[ "$(rows)" == *'leader certificate appliance CA unreachable MISMATCH'* ]]
  [[ "$(rows)" == *'dh parameters pre-generated unreadable MISMATCH'* ]]
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
  _follower_backends_used() {
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
  stub_unhardened_leader
  _sample_data_state() {
    echo loaded
  }

  run _verify

  # The one test here that asserts a clean exit, so that the follower rows are shown
  # to be capable of passing and not only of mismatching.
  [ "$status" -eq 0 ]
  [[ "$(rows)" == *'followers running 1 1 ok'* ]]
  [[ "$(rows)" == *'follower 1 health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 1 replication replicating replicating ok'* ]]
  [[ "$(rows)" == *'follower secret read retrievable retrievable ok'* ]]
  [[ "$(rows)" == *'follower backends used 1 1 ok'* ]]
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
  _follower_backends_used() {
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
  stub_unhardened_leader
  _sample_data_state() {
    echo loaded
  }

  run _verify

  [ "$status" -ne 0 ]
  [ "$(rows | grep --count MISMATCH)" -eq 1 ]
  [[ "$(rows)" == *'leader health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 1 health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 1 replication replicating apply errors MISMATCH'* ]]
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
  _follower_backends_used() {
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
  stub_unhardened_leader
  _sample_data_state() {
    echo loaded
  }

  run _verify

  [ "$status" -ne 0 ]
  [ "$(rows | grep --count MISMATCH)" -eq 1 ]
  [[ "$(rows)" == *'follower secret read retrievable retrievable ok'* ]]
  [[ "$(rows)" == *'follower 1 replication replicating disabled MISMATCH'* ]]
}

# Stubs a leader with no standbys and the sample data loaded, and $1 followers that
# are all up, healthy, replicating and routed to -- for the multi-follower tests,
# which then override the one probe each is about.
stub_healthy_followers() {
  local count="$1"

  eval "_running_followers() { echo $count; }"
  eval "_follower_backends_used() { echo $count; }"
  _follower_health() {
    echo ok
  }
  _follower_replication_state() {
    echo replicating
  }
  _follower_secret_state() {
    echo retrievable
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
  stub_unhardened_leader
  _sample_data_state() {
    echo loaded
  }
}

@test "verification reports health and replication for each follower" {
  spec 'version: "13.5"' 'followers: 3'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"
  stub_healthy_followers 3

  run _verify

  [ "$status" -eq 0 ]
  [[ "$(rows)" == *'followers running 3 3 ok'* ]]
  [[ "$(rows)" == *'follower 1 health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 2 health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 3 health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 1 replication replicating replicating ok'* ]]
  [[ "$(rows)" == *'follower 2 replication replicating replicating ok'* ]]
  [[ "$(rows)" == *'follower 3 replication replicating replicating ok'* ]]
  [[ "$(rows)" == *'follower secret read retrievable retrievable ok'* ]]
  [[ "$(rows)" == *'follower backends used 3 3 ok'* ]]
}

# The probes are asked by number, so that a stub answering for every follower
# alike could not hide one that is not being asked at all.
@test "one unhealthy follower fails verification, and is the one named" {
  spec 'version: "13.5"' 'followers: 3'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"
  stub_healthy_followers 3
  _follower_health() {
    if [ "$1" = 2 ]; then
      echo 'not ok'
    else
      echo ok
    fi
  }

  run _verify

  [ "$status" -ne 0 ]
  [ "$(rows | grep --count MISMATCH)" -eq 1 ]
  [[ "$(rows)" == *'follower 1 health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 2 health ok not ok MISMATCH'* ]]
  [[ "$(rows)" == *'follower 3 health ok ok ok'* ]]
}

@test "one follower behind fails verification, and is the one named" {
  spec 'version: "13.5"' 'followers: 2'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"
  stub_healthy_followers 2
  _follower_replication_state() {
    if [ "$1" = 2 ]; then
      echo 'initial sync'
    else
      echo replicating
    fi
  }

  run _verify

  [ "$status" -ne 0 ]
  [ "$(rows | grep --count MISMATCH)" -eq 1 ]
  [[ "$(rows)" == *'follower 1 replication replicating replicating ok'* ]]
  [[ "$(rows)" == *'follower 2 replication replicating initial sync MISMATCH'* ]]
}

# Every follower healthy and replicating on its own port says nothing about the
# load balancer in front of them: a backend it never marks up -- a certificate it
# cannot verify, say -- leaves the tier serving from fewer followers than it has,
# with every other row passing.
@test "a load balancer routing to fewer followers than there are fails verification" {
  spec 'version: "13.5"' 'followers: 2'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"
  stub_healthy_followers 2
  _follower_backends_used() {
    echo 1
  }

  run _verify

  [ "$status" -ne 0 ]
  [ "$(rows | grep --count MISMATCH)" -eq 1 ]
  [[ "$(rows)" == *'follower backends used 2 1 MISMATCH'* ]]
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
  _follower_backends_used() {
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
  stub_unhardened_leader

  run _verify

  [ "$status" -ne 0 ]
  [[ "$(rows)" == *'followers running 0 1 MISMATCH'* ]]
  [[ "$(rows)" != *'follower 1 health'* ]]
  [[ "$(rows)" != *'follower 1 replication'* ]]
  [[ "$(rows)" != *'follower secret read'* ]]
  [[ "$(rows)" != *'follower backends used'* ]]
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
  _follower_backends_used() {
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
  stub_unhardened_leader

  run _verify

  # A clean exit as well as the missing row, since a retrieval row that was still
  # probed and failed would otherwise go unnoticed.
  [ "$status" -eq 0 ]
  [[ "$(rows)" == *'follower 1 health ok ok ok'* ]]
  [[ "$(rows)" == *'follower 1 replication replicating replicating ok'* ]]
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

@test "each hardening option is verified against what the leader actually has" {
  spec 'version: "13.5"' 'sample_data: false' 'leader:' '  master_key_encryption: true' '  generate_dh: true'

  BIN_ENV_SOURCE_ONLY=1 source bin/env
  _read_spec "$(_resolve_spec "$SPEC")"

  _leader_key_encryption_state() {
    echo encrypted
  }
  # Custom certificates the spec did not ask for, and a generator that never
  # finished: both leaders are healthy, and neither is the one described.
  _leader_certificate_state() {
    echo 'custom CA'
  }
  _leader_dh_params_state() {
    echo bootstrap
  }

  run _verify

  [ "$status" -ne 0 ]
  [[ "$(rows)" == *'master key encryption encrypted encrypted ok'* ]]
  [[ "$(rows)" == *'leader certificate appliance CA custom CA MISMATCH'* ]]
  [[ "$(rows)" == *'dh parameters generated bootstrap MISMATCH'* ]]
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

# Read off the key files themselves rather than off `bin/dap --enable-mke` having
# succeeded, because what the spec asks for is keys that are encrypted, not a
# command that ran. Both listings are the live leader's: configured, and then
# encrypted and unlocked. `evoke keys encrypt` replaces each key with a `.key.enc`
# beside it, and unlocking puts back only a symlink into /dev/shm -- so symlinks
# are present in both listings, and it is the regular files that tell them apart.
@test "master key encryption is read off the leader's key files" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  docker() {
    case "$*" in
      *'compose exec -T conjur-master-1.mycompany.local find /opt/conjur/etc'* )
        cat <<'LISTING'
ff /opt/conjur/etc/possum.key
ff /opt/conjur/etc/ui.key
lf /opt/conjur/etc/ssl/internal.key
lf /opt/conjur/etc/ssl/conjur.key
lf /opt/conjur/etc/ssl/ca.key
lf /opt/conjur/etc/ssl/external.key
ff /opt/conjur/etc/ssl/external/conjur-master.mycompany.local.key
ff /opt/conjur/etc/ssl/external/ca.key
ff /opt/conjur/etc/ssl/internal/conjur-master.mycompany.local.key
ff /opt/conjur/etc/ssl/internal/ca.key
LISTING
        ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_key_encryption_state)" = 'not encrypted' ]

  docker() {
    case "$*" in
      *'compose exec -T conjur-master-1.mycompany.local find /opt/conjur/etc'* )
        cat <<'LISTING'
ff /opt/conjur/etc/ui.key.enc
ff /opt/conjur/etc/possum.key.enc
ff /opt/conjur/etc/ssl/conjur-follower.mycompany.local.key.enc
lf /opt/conjur/etc/ssl/conjur-follower.mycompany.local.key
lf /opt/conjur/etc/ssl/internal.key
lf /opt/conjur/etc/ssl/conjur.key
lf /opt/conjur/etc/ssl/external.key
lf /opt/conjur/etc/ssl/external/conjur-master.mycompany.local.key
ff /opt/conjur/etc/ssl/external/conjur-master.mycompany.local.key.enc
lf /opt/conjur/etc/ssl/internal/conjur-master.mycompany.local.key
ff /opt/conjur/etc/ssl/internal/conjur-master.mycompany.local.key.enc
lf /opt/conjur/etc/ssl/internal/ca.key
ff /opt/conjur/etc/ssl/internal/ca.key.enc
LISTING
        ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_key_encryption_state)" = 'encrypted' ]

  # A key imported after encryption: the rest are encrypted, this one sits on disk
  # in plaintext. Enabling MKE before importing certificates is what this catches.
  docker() {
    case "$*" in
      *'find /opt/conjur/etc'* )
        printf '%s\n' \
          'ff /opt/conjur/etc/possum.key.enc' \
          'ff /opt/conjur/etc/ssl/external/conjur-master.mycompany.local.key.enc' \
          'ff /opt/conjur/etc/ssl/conjur-follower.mycompany.local.key' ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_key_encryption_state)" = 'partly encrypted' ]

  # Encrypted but never unlocked -- after a restart, say. The symlinks point into a
  # /dev/shm that is empty again, which find reports as a dangling link (N), and
  # nginx and conjur cannot read their keys.
  docker() {
    case "$*" in
      *'find /opt/conjur/etc'* )
        printf '%s\n' \
          'ff /opt/conjur/etc/possum.key.enc' \
          'ff /opt/conjur/etc/ssl/external/conjur-master.mycompany.local.key.enc' \
          'lN /opt/conjur/etc/ssl/external/conjur-master.mycompany.local.key' ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_key_encryption_state)" = 'locked' ]

  # No leader to ask. Not `not encrypted`, which a spec without MKE would pass on.
  docker() {
    return 1
  }

  [ "$(_leader_key_encryption_state)" = 'unreadable' ]
}

# The chain a client is actually handed, read by connecting through the leader
# load balancer the way a client does, rather than off `evoke ca import` having
# succeeded -- a spec asking for custom certificates on a leader that silently
# kept its self-signed ones has to fail here. Both handshakes are the live
# leader's, before and after `bin/dap --import-custom-certificates`, with the
# certificate bodies left out.
@test "the leader's certificate is read off the chain it presents" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  docker() {
    case "$*" in
      *'compose exec -T conjur-master-1.mycompany.local openssl s_client -connect conjur-master.mycompany.local:443'* )
        cat <<'HANDSHAKE'
CONNECTED(00000003)
---
Certificate chain
 0 s:CN = conjur-master.mycompany.local
   i:O = demo, OU = Conjur CA, CN = conjur-master.mycompany.local
   a:PKEY: rsaEncryption, 2048 (bit); sigalg: RSA-SHA256
   v:NotBefore: Sep 23 12:24:47 2026 GMT; NotAfter: Sep 20 12:24:47 2036 GMT
 1 s:O = demo, OU = Conjur CA, CN = conjur-master.mycompany.local
   i:O = demo, OU = Conjur CA, CN = conjur-master.mycompany.local
   a:PKEY: rsaEncryption, 2048 (bit); sigalg: RSA-SHA256
   v:NotBefore: Sep 23 12:24:43 2026 GMT; NotAfter: Sep 20 12:24:43 2036 GMT
---
Server certificate
subject=CN = conjur-master.mycompany.local
issuer=O = demo, OU = Conjur CA, CN = conjur-master.mycompany.local
---
HANDSHAKE
        ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_certificate_state)" = 'appliance CA' ]

  docker() {
    case "$*" in
      *'compose exec -T conjur-master-1.mycompany.local openssl s_client -connect conjur-master.mycompany.local:443'* )
        cat <<'HANDSHAKE'
CONNECTED(00000003)
---
Certificate chain
 0 s:C = US, ST = Massachusetts, L = Newton, O = Dynamic Access Provider, OU = Master, CN = conjur-master.mycompany.local
   i:C = US, ST = Massachusetts, L = Newton, O = Cyberark USA Engineering, OU = Conjur, CN = Cyberark Conjur
   a:PKEY: rsaEncryption, 2048 (bit); sigalg: RSA-SHA256
   v:NotBefore: Sep 23 12:22:00 2026 GMT; NotAfter: Sep 23 12:22:00 2027 GMT
 1 s:C = US, ST = Massachusetts, L = Newton, O = Cyberark USA Engineering, OU = Conjur, CN = Cyberark Conjur
   i:C = US, ST = Massachusetts, L = Newton, O = Cyberark USA Engineering, OU = Conjur, CN = Cyberark Conjur Root CA
   a:PKEY: rsaEncryption, 2048 (bit); sigalg: RSA-SHA256
   v:NotBefore: Sep 23 12:22:00 2026 GMT; NotAfter: Sep 14 04:22:00 2031 GMT
 2 s:C = US, ST = Massachusetts, L = Newton, O = Cyberark USA Engineering, OU = Conjur, CN = Cyberark Conjur Root CA
   i:C = US, ST = Massachusetts, L = Newton, O = Cyberark USA Engineering, OU = Conjur, CN = Cyberark Conjur Root CA
   a:PKEY: rsaEncryption, 2048 (bit); sigalg: RSA-SHA256
   v:NotBefore: Sep 23 12:22:00 2026 GMT; NotAfter: Sep 22 12:22:00 2031 GMT
---
Server certificate
subject=C = US, ST = Massachusetts, L = Newton, O = Dynamic Access Provider, OU = Master, CN = conjur-master.mycompany.local
issuer=C = US, ST = Massachusetts, L = Newton, O = Cyberark USA Engineering, OU = Conjur, CN = Cyberark Conjur
---
HANDSHAKE
        ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_certificate_state)" = 'custom CA' ]

  # The custom leader certificate served without the intermediate that issued it:
  # a client trusting only the custom root cannot build a path to it.
  docker() {
    printf '%s\n' \
      'Certificate chain' \
      ' 0 s:C = US, ST = Massachusetts, L = Newton, O = Dynamic Access Provider, OU = Master, CN = conjur-master.mycompany.local' \
      '   i:C = US, ST = Massachusetts, L = Newton, O = Cyberark USA Engineering, OU = Conjur, CN = Cyberark Conjur' \
      '---'
  }

  [ "$(_leader_certificate_state)" = 'no intermediate' ]

  # Issued by neither CA bin/dap knows about. Named, because the issuer is what
  # the operator has to go and find.
  docker() {
    printf '%s\n' \
      'Certificate chain' \
      ' 0 s:CN = conjur-master.mycompany.local' \
      '   i:O = Example Corp, CN = Example Issuing CA' \
      '---'
  }

  [ "$(_leader_certificate_state)" = 'Example Issuing CA' ]

  # Nothing answered the handshake, which is not the same as a self-signed answer.
  docker() {
    echo 'connect:errno=111'
    return 1
  }

  [ "$(_leader_certificate_state)" = 'unreachable' ]
}

# The file nginx's ssl_dhparam names, read off the leader. There are three things
# it can hold, and the one to catch is the middle one: the pre-generated
# files/dhparam.pem bin/dap copies in, the RFC 3526 group `evoke configure
# master` installs as a stand-in -- tagged, so dhgen.sh knows to replace it -- or
# parameters the leader generated. A leader asked to generate its own that never
# finished is healthy, and serving the bootstrap group.
@test "the leader's DH parameters are read off the file nginx serves them from" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  # What bin/dap copies in, byte for byte.
  docker() {
    case "$*" in
      *'compose exec -T conjur-master-1.mycompany.local cat /etc/ssl/dhparam.pem'* ) cat files/dhparam.pem ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_dh_params_state)" = 'pre-generated' ]

  # The live leader's, configured with --generate-dh, whose generator had exited.
  docker() {
    case "$*" in
      *'compose exec -T conjur-master-1.mycompany.local cat /etc/ssl/dhparam.pem'* )
        cat <<'PEM'
Nothing-up-my-sleeve pi-based Diffie-Hellman 3072-bit parameters from RFC 3526.
Used for fast bootstrap with reasonable security; custom DH parameters are
generated once enough entropy has been accumulated and replace this.

NOTE: do not remove the following tag line.
BOOTSTRAP PARAMETERS

-----BEGIN DH PARAMETERS-----
MIIBiAKCAYEA///////////JD9qiIWjCNMTGYouA3BzRKQJOCIpnzHQCC76mOxOb
IlFKCHmONATd75UZs806QxswKwpt8l8UN0/hNW1tUcJF5IW1dmJefsb0TELppjft
awv/XLb0Brft7jhr+1qJn6WunyQRfEsf5kkoZlHs5Fs9wgB8uKFjvwWY2kg2HFXT
mmkWP6j9JM9fg2VdI9yjrZYcYvNWIIVSu57VKQdwlpZtZww1Tkq8mATxdGwIyhgh
fDKQXkYuNs474553LBgOhgObJ4Oi7Aeij7XFXfBvTFLJ3ivL9pVYFxg5lUl86pVq
5RXSJhiY+gUQFXKOWoqqxC2tMxcNBFB6M6hVIavfHLpk7PuFBFjb7wqK6nFXXQYM
fbOXD4Wm4eTHq/WujNsJM9cejJTgSiVhnc7j0iYa0u5r8S/6BtmKCGTYdgJzPshq
ZFIfKxgXeyAMu+EXV3phXWx3CYjAutlG4gjiT6B05asxQ9tb/OD9EI5LgtEgqTrS
yv//////////AgEC
-----END DH PARAMETERS-----
PEM
        ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_dh_params_state)" = 'bootstrap' ]

  # What `openssl dhparam` wrote out on the leader: untagged, and not ours.
  docker() {
    case "$*" in
      *'compose exec -T conjur-master-1.mycompany.local cat /etc/ssl/dhparam.pem'* )
        cat <<'PEM'
-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----
PEM
        ;;
      * ) return 1 ;;
    esac
  }

  [ "$(_leader_dh_params_state)" = 'generated' ]

  # Neither a leader to ask nor a file to read. Not `generated`, which is what a
  # probe that only looked for the bootstrap tag would say.
  docker() {
    return 1
  }

  [ "$(_leader_dh_params_state)" = 'unreadable' ]
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

  [ "$(_follower_health 1)" = 'ok' ]

  # Only the follower is unhealthy. A probe reading the leader's answer would still
  # say ok here, which is the whole point of the check.
  curl() {
    case "$*" in
      *localhost:450* ) echo '{"ok":false,"degraded":true,"role":"follower"}' ;;
      *localhost:443* ) echo '{"ok":true,"degraded":false,"role":"master"}' ;;
      * ) return 7 ;;
    esac
  }

  [ "$(_follower_health 1)" = 'not ok' ]
  [ "$(_leader_health)" = 'ok' ]

  # And the follower down while the leader is up, which is the state the whole row
  # exists to surface.
  curl() {
    case "$*" in
      *localhost:443* ) echo '{"ok":true,"degraded":false,"role":"master"}' ;;
      * ) return 7 ;;
    esac
  }

  [ "$(_follower_health 1)" = 'unreachable' ]
}

# Each follower on its own published port, as docker-compose.yml has it: follower 1
# on CONJUR_FOLLOWER_PORT, the others on 450 plus their number.
@test "each follower is probed on its own port" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env

  curl() {
    case "$*" in
      *localhost:450/* ) echo '{"ok":true,"role":"follower"}' ;;
      *localhost:452/* ) echo '{"ok":false,"role":"follower"}' ;;
      * ) return 7 ;;
    esac
  }

  [ "$(_follower_health 1)" = 'ok' ]
  [ "$(_follower_health 2)" = 'not ok' ]
  [ "$(_follower_health 3)" = 'unreachable' ]

  CONJUR_FOLLOWER_PORT=460
  [ "$(_follower_health 1)" = 'unreachable' ]
  [ "$(_follower_health 2)" = 'not ok' ]
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

  [ "$(_follower_replication_state 1)" = 'replicating' ]

  # The same probe pointed at the leader, which is the mistake this guards against.
  # Verified live as well: it reads `not a follower` against conjur-master-1.
  CONJUR_FOLLOWER_PORT="$CONJUR_MASTER_PORT"

  [ "$(_follower_replication_state 1)" = 'not a follower' ]
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
  [ "$(_follower_replication_state 1)" = 'not replicating' ]

  # Still copying the leader's database. Reported as its own state rather than as a
  # failure of replication, because it is a stage every follower passes through.
  curl() { follower_health_body '[{"enabled":true,"apply_error_count":0,"sync_error_count":0}]' true; }
  [ "$(_follower_replication_state 1)" = 'initial sync' ]

  # The subscription exists but is not running, which is what `evoke replication
  # stop` leaves behind -- and the state in which the follower keeps serving the
  # data it already has.
  curl() { follower_health_body '[{"enabled":false,"apply_error_count":0,"sync_error_count":0}]'; }
  [ "$(_follower_replication_state 1)" = 'disabled' ]

  # Receiving changes and failing to apply them. This is the case the leader's own
  # pg_stat_replication would call `streaming`.
  curl() { follower_health_body '[{"enabled":true,"apply_error_count":3,"sync_error_count":0}]'; }
  [ "$(_follower_replication_state 1)" = 'apply errors' ]

  curl() { follower_health_body '[{"enabled":true,"apply_error_count":0,"sync_error_count":2}]'; }
  [ "$(_follower_replication_state 1)" = 'sync errors' ]

  # No replication block at all, which is what an older appliance answers. Distinct
  # from every state above: the probe has no view, rather than a bad one.
  curl() { echo '{"ok":true,"role":"follower","database":{"ok":true}}'; }
  [ "$(_follower_replication_state 1)" = 'unparseable' ]
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

# The follower load balancer's stats page, as HAProxy 3.4 served it for a tier of
# two followers. Its columns are read by name rather than position, so that is
# what this pins: the real header, with the frontend, backend and stats rows that
# have to be told apart from the servers.
follower_lb_stats_csv() {
  cat << 'CSV'
# pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status,weight,act,bck,chkfail,chkdown,lastchg,downtime,qlimit,pid,iid,sid,throttle,lbtot,tracked,type,rate,rate_lim,rate_max,check_status,check_code,check_duration,hrsp_1xx,hrsp_2xx,hrsp_3xx,hrsp_4xx,hrsp_5xx,hrsp_other,hanafail,req_rate,req_rate_max,req_tot,cli_abrt,srv_abrt,comp_in,comp_out,comp_byp,comp_rsp,lastsess,last_chk,last_agt,qtime,ctime,rtime,ttime,agent_status,agent_code,agent_duration,check_desc,agent_desc,check_rise,check_fall,check_health,agent_rise,agent_fall,agent_health,addr,cookie,mode,algo,conn_rate,conn_rate_max,conn_tot,intercepted,dcon,dses,wrew,connect,reuse,cache_lookups,cache_hits,srv_icur,src_ilim,qtime_max,ctime_max,rtime_max,ttime_max,eint,idle_conn_cur,safe_conn_cur,used_conn_cur,need_conn_est,uweight,agg_server_status,agg_server_check_status,agg_check_status,srid,sess_other,h1sess,h2sess,h3sess,req_other,h1req,h2req,h3req,proto,priv_idle_cur,reqbin,reqbout,resbin,resbout,-,ssl_sess,ssl_reused_sess,ssl_failed_handshake,ssl_ocsp_staple,ssl_failed_ocsp_staple,h3_data,h3_headers,h3_cancel_push,h3_push_promise,h3_max_push_id,h3_goaway,h3_settings,h3_no_error,h3_general_protocol_error,h3_internal_error,h3_stream_creation_error,h3_closed_critical_stream,h3_frame_unexpected,h3_frame_error,h3_excessive_load,h3_id_error,h3_settings_error,h3_missing_settings,h3_request_rejected,h3_request_cancelled,h3_request_incomplete,h3_message_error,h3_connect_error,h3_version_fallback,pack_decompression_failed,qpack_encoder_stream_error,qpack_decoder_stream_error,quic_rxbuf_full,quic_dropped_pkt,quic_dropped_pkt_bufoverrun,quic_dropped_parsing_pkt,quic_socket_full,quic_sendto_err,quic_sendto_err_unknwn,quic_sent_pkt,quic_lost_pkt,quic_too_short_dgram,quic_retry_sent,quic_retry_validated,quic_retry_error,quic_half_open_conn,quic_hdshk_fail,quic_stless_rst_sent,quic_conn_migration_done,quic_transp_err_no_error,quic_transp_err_internal_error,quic_transp_err_connection_refused,quic_transp_err_flow_control_error,quic_transp_err_stream_limit_error,quic_transp_err_stream_state_error,quic_transp_err_final_size_error,quic_transp_err_frame_encoding_error,quic_transp_err_transport_parameter_error,quic_transp_err_connection_id_limit,quic_transp_err_protocol_violation_error,quic_transp_err_invalid_token,quic_transp_err_application_error,quic_transp_err_crypto_buffer_exceeded,quic_transp_err_key_update_error,quic_transp_err_aead_limit_reached,quic_transp_err_no_viable_path,quic_transp_err_crypto_error,quic_transp_err_unknown_error,quic_data_blocked,quic_stream_data_blocked,quic_streams_blocked_bidi,quic_streams_blocked_uni,quic_ncbuf_gap_limit,h2_headers_rcvd,h2_data_rcvd,h2_settings_rcvd,h2_rst_stream_rcvd,h2_goaway_rcvd,h2_detected_conn_protocol_errors,h2_detected_strm_protocol_errors,h2_rst_stream_resp,h2_goaway_resp,h2_open_connections,h2_backend_open_streams,h2_total_connections,h2_backend_total_streams,h1_open_connections,h1_open_streams,h1_total_connections,h1_total_streams,h1_bytes_in,h1_bytes_out,h1_spliced_bytes_in,h1_spliced_bytes_out,
www,FRONTEND,,,0,3,256,7,2106,11429,0,0,0,,,,,OPEN,,,,,,,,,1,2,0,,,,0,0,0,7,,,,0,7,0,0,0,0,,0,7,7,,,0,0,0,0,,,,,,,,,,,,,,,,,,,,,http,,0,7,7,0,0,0,0,,,0,0,,,,,,,0,,,,,,,,,,0,2,5,0,0,2,5,0,,,2106,2289,11429,11429,-,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,0,15,0,1,0,0,0,0,0,0,5,5,0,0,2,2,437,2323,0,0,
www-backend,conjur-follower-1,0,0,0,1,,3,478,5632,,0,,0,0,0,0,UP,1,1,0,1,2,34,8,,1,3,1,,3,,2,0,,3,L7OK,200,58,0,3,0,0,0,0,,,,3,0,0,,,,,9,,,0,2,9,12,,,,Layer7 check passed,,2,3,4,,,,,,http,,,,,,,,0,3,0,,,0,,0,2,26,27,0,0,0,0,1,1,,,,0,,,,,,,,,,0,478,557,5632,5632,-,23,1,0,0,0,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
www-backend,conjur-follower-2,0,0,0,1,,4,1628,5797,,0,,0,0,0,0,UP,1,1,0,2,1,44,0,,1,3,2,,4,,2,0,,4,L7OK,200,63,0,4,0,0,0,0,,,,4,0,0,,,,,9,,,0,2,69,72,,,,Layer7 check passed,,2,3,4,,,,,,http,,,,,,,,0,2,2,,,0,,0,3,225,228,0,0,0,0,1,1,,,,0,,,,,,,,,,0,1628,1732,5797,5797,-,23,0,0,0,0,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
www-backend,BACKEND,0,0,0,1,26,7,2106,11429,0,0,,0,0,0,0,UP,2,2,0,,1,44,0,,1,3,0,,7,,1,0,,7,,,,0,7,0,0,0,0,,,,7,0,0,0,0,0,0,9,,,0,2,44,46,,,,,,,,,,,,,,http,,,,,,,,0,5,2,0,0,,,0,3,225,228,0,,,,,2,0,0,0,,,,,,,,,,,,2106,2289,11429,11429,-,46,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,47,49,102090,3201,0,0,
stats,FRONTEND,,,1,2,256,3,168,11114,0,0,0,,,,,OPEN,,,,,,,,,1,4,0,,,,0,1,0,2,,,,0,2,0,0,0,0,,1,2,3,,,0,0,0,0,,,,,,,,,,,,,,,,,,,,,http,,1,2,3,3,0,0,0,,,0,0,,,,,,,0,,,,,,,,,,0,3,0,0,0,3,0,0,,,168,168,11114,11114,-,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,3,3,243,11134,0,0,
stats,BACKEND,0,0,0,0,26,0,168,11114,0,0,,0,0,0,0,UP,0,0,0,,0,44,,,1,4,0,,0,,1,0,,0,,,,0,0,0,0,0,0,,,,0,0,0,0,0,0,0,0,,,0,0,0,0,,,,,,,,,,,,,,http,,,,,,,,0,0,0,0,0,,,0,0,0,0,0,,,,,0,0,0,0,,,,,,,,,,,,168,168,11114,11114,-,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
CSV
}

# A follower load balancer with the given servers up behind it, balancing
# round-robin across them, with each server's lbtot -- the times HAProxy chose it
# -- kept in a file so the counts survive the subshells the probe runs curl in.
# The stats page is the captured one with those counts written into it.
stub_follower_load_balancer() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/lb-servers"
  echo 0 > "$BATS_TEST_TMPDIR/lb-next"

  curl() {
    case "$*" in
      *'localhost:7001/;csv'* )
        follower_lb_stats_csv | awk -F, -v OFS=, -v dir="$BATS_TEST_TMPDIR" '
          $1 == "www-backend" && $2 ~ /^conjur-follower-/ {
            total = 0
            if ((getline total < (dir "/lbtot-" $2)) <= 0) total = 0
            $31 = total
          }
          { print }'
        ;;
      *'localhost:449/health'* )
        local servers next server total
        mapfile -t servers < "$BATS_TEST_TMPDIR/lb-servers"
        next="$(cat "$BATS_TEST_TMPDIR/lb-next")"
        server="${servers[next % ${#servers[@]}]}"
        total="$(cat "$BATS_TEST_TMPDIR/lbtot-$server" 2> /dev/null || echo 0)"
        echo $((total + 1)) > "$BATS_TEST_TMPDIR/lbtot-$server"
        echo $((next + 1)) > "$BATS_TEST_TMPDIR/lb-next"
        echo '{"ok":true}'
        ;;
      * ) return 7 ;;
    esac
  }
}

# Counted off the load balancer's own record of which servers it chose, across
# requests made through it, rather than off the followers: a follower answering
# on its own port says nothing about whether the load balancer ever sends it
# anything.
@test "the backends used are the followers the load balancer chose for requests through it" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env
  SPEC_FOLLOWERS=2
  stub_follower_load_balancer conjur-follower-1 conjur-follower-2

  [ "$(_follower_backends_used)" = 2 ]
}

# Follower 2 is healthy on its own port but never marked up by the load balancer
# -- a certificate it cannot verify against its CA does exactly this.
@test "a follower the load balancer never chooses is not a backend used" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env
  SPEC_FOLLOWERS=2
  stub_follower_load_balancer conjur-follower-1

  [ "$(_follower_backends_used)" = 1 ]
}

# The counts are cumulative, so a server chosen before verification ran -- by the
# provisioning's own reads -- must not count unless it is chosen again now.
@test "only requests made while verifying count toward the backends used" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env
  SPEC_FOLLOWERS=2
  stub_follower_load_balancer conjur-follower-1
  echo 40 > "$BATS_TEST_TMPDIR/lbtot-conjur-follower-2"

  [ "$(_follower_backends_used)" = 1 ]
}

@test "a follower load balancer whose stats page does not answer is unreachable" {
  BIN_ENV_SOURCE_ONLY=1 source bin/env
  SPEC_FOLLOWERS=2
  curl() {
    return 7
  }

  [ "$(_follower_backends_used)" = 'unreachable' ]
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
