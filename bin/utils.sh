#!/usr/bin/env bash

function dotenv {
  local envfile="${1:-.env}"

  # Ensure envfile exists
  if ! $(ls ${envfile} >/dev/null 2>&1); then
    echo "${envfile} not found";
    return 1;
  fi

  # Export variables first before we source the envfile below
  local envvars=$(cat ${envfile} | cut -f1 -d=)
  if [[ -z "${envvars}" ]]; then
    echo "nothing to source, ${envfile} is empty."
    return
  fi

  echo "envvars sourced from ${envfile}:"
  echo "${envvars}"
  export $(echo ${envvars})

  # Ensure all env vars values are wrapped in quotation marks before unescaping them,
  # then source.
  source <(cat ${envfile} | sed -E 's/\=([^"].*)/="\1"/' | sed -E 's/\="(.*)"$/=\$\(printf \"%b\" "\1"\)/')
}

function _wait_for_master {
  _wait_for_healthy 'DAP Master' "https://localhost:${CONJUR_MASTER_PORT}" "${1:-600}"
}

function _wait_for_follower {
  _wait_for_healthy 'DAP Follower' "https://localhost:${CONJUR_FOLLOWER_PORT}" "${1:-600}"
}

function _wait_for_healthy {
  local name="$1"
  local url="$2"

  echo "Waiting for ${name} to be ready... ${url}"

  # Wait for 10 successful connections in a row
  local COUNTER=0

  TIMEOUT="${3:-600}"
  SECONDS=0
  while [ $COUNTER -lt 10 ]; do
    if [ $SECONDS -ge $TIMEOUT ]; then
      echo "Timed out waiting for ${name} to be ready"
      exit 1
    fi

    local response
    response=$(curl -k --silent --head "$url/health" || true)

    if ! echo "$response" | grep -iq "Conjur-Health: OK"; then
      sleep 5
      COUNTER=0
    else
      (( COUNTER=COUNTER+1 ))
    fi

    sleep 1
    echo "Successful Health Checks: $COUNTER"
  done
}

function retry_5_times() {
    local cmd=$1
    local attempt=0
    while [ $attempt -lt 5 ]; do
        result=$(eval "$cmd")
        if [ "$?" -eq 0 ]; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    if [[ ! -z "$result" ]]; then
      echo "$result"
    fi
}

# The follower load balancer's HAProxy config. Generated at provisioning time,
# as the leader's is, and gitignored. Here rather than in bin/dap because
# bin/podman-dap mounts the same directory.
function _set_follower_proxy_config {
  local dir="${1:-files/haproxy/follower}"

  mkdir -p "$dir"
  _follower_proxy_config > "$dir/haproxy.cfg"
}

function _follower_proxy_config {
  cat << EOF
global
  daemon
  maxconn 256
  log-send-hostname

resolvers docker
  nameserver dns1 127.0.0.11:53
  resolve_retries 3
  timeout retry 1s
  hold valid 30s
  hold other 30s
  hold refused 30s
  hold nx 30s
  hold timeout 30s

defaults
  mode http
  option forwardfor
  timeout connect 50000ms
  timeout client  50000ms
  timeout server  50000ms

#
# Peform SSL Pass-Through to proxy HTTPS requests to DAP
#

frontend www
  bind *:80
  bind *:443 ssl crt /etc/ssl/certs/conjur-follower.mycompany.local.pem
  default_backend www-backend

#
# Performs Layer 4 proxy
# Uses DAP's HTTP health endpoint to determine master
#

backend www-backend
  balance roundrobin
  option httpchk GET /health
$(_follower_backend_www_lines)

#
# Enables HAProxy's UI for debugging
#
listen stats
  mode http
  bind *:7000
  stats enable
  stats uri /
EOF
}

function _follower_backend_www_lines {
  declare -a follower_servers

  # docker-compose.yml defines a single follower, conjur-follower-1
  local follower_count=1

  # Followers are resolved through docker's DNS at runtime (init-addr none), so
  # the load balancer can start before they are resolvable
  for ((i=1; i<=follower_count; i++))
  do
    follower_servers+=("  server conjur-follower-$i conjur-follower-$i.mycompany.local:443 check port 443 check port 443 check-ssl ca-file /etc/ssl/certs/ca.pem ssl ca-file /etc/ssl/certs/ca.pem resolvers docker init-addr none")
  done

  printf '%s' "$(IFS=$'\n' ; echo "${follower_servers[*]}")"
}
