# Runs test/env.bats without making bats a host dependency.
#
# The docker CLI and jq are here because bin/env uses them: it shells out to
# docker to convert and validate a spec, and reads the resulting JSON with jq.
# bin/env-test mounts the host docker socket, so those docker calls reach the
# host daemon rather than a nested one.
FROM bats/bats:1.11.0

RUN apk add --no-cache \
      curl \
      docker-cli \
      jq
