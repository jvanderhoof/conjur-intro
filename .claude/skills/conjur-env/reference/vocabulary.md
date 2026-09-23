# Customer vocabulary → spec fields

Distilled from the Secrets Manager Self-Hosted product knowledge base (`overview.md`,
`follower.md`, `operations.md`, `system-requirements.md`), so that this skill has no
path dependency on a clone of it. Where a mapping comes from support-ticket usage
rather than from the knowledge base, it says so.

This file is for translation only. What a field *accepts* — its range, its type,
which fields constrain each other — is in `environments/schema.json`, and nowhere
here. Read the schema for that.

## Fields

| Spec field | Customers say | Notes for translating |
|---|---|---|
| `version` | "13.5", "Secrets Manager Self-Hosted 13.x", "Conjur Enterprise 12.9", "DAP 11.x" / "Dynamic Access Provider" (ticket usage), "the appliance image", "running image 13.5.1" | Conjur Enterprise is the former name of Secrets Manager Self-Hosted, and DAP is the older name for the same appliance. If a ticket mentions several versions, the leader's is the one that matters: standbys and followers must run the same version as the leader or newer, so the leader is the oldest node. Get an exact image tag, not a product generation. |
| `leader.standbys` | "standby", "replica", "sync replica", "async replica", "HA pair", "master/standby", "3-node cluster" (leader + 2 standbys), "5-node cluster" (leader + 4 standbys) | Standbys are promotion candidates. They sit behind the cluster load balancer, next to the leader, and never serve applications. "Leader", "Master" and "primary" all mean the leader, so the leader is never counted as a standby. |
| `leader.auto_failover` | "auto-failover", "automatic failover", "AFO", "HA cluster", "etcd", "cluster enroll", "cluster policy", "the standby promoted itself" | Auto-failover is an etcd cluster that elects a new leader by majority. "Manual failover" or "we run `evoke role promote`" means auto-failover is **off**. The failover itself is a transition (see Gaps below). |
| `leader.master_key_encryption` | "MKE", "master key encryption", "encrypted server keys", "keys locked after reboot", "`evoke keys unlock`", "`evoke keys encrypt`" | The spec builds a file-based master key only. A master key held in AWS KMS (`evoke keys kms`) or an HSM (`evoke pkcs11`) is a gap. Say `true` here and name the backend as set up by hand. |
| `leader.custom_certificates` | "third-party certificates", "our own CA", "enterprise / internal PKI", "CA-signed certs", "`evoke ca import`", "imported certificates" | The spec generates its own CA with `bin/generate-certs`. It cannot use the customer's CA, their SANs or their hostnames, so those are gaps even when this is `true`. The opposite answer is "self-signed", "default certificates" or "`evoke ca regenerate`". |
| `leader.generate_dh` | "DH parameters", "dhparam", "Diffie-Hellman", "generate DH", "slow first start while it generates DH", "weak DH / Logjam scan finding" | The knowledge base does not cover this (ticket usage). It is rarely stated, so ask. |
| `followers` | "follower", "read replica", "edge node", "regional follower", "follower per DC", "the node the apps talk to" | Followers are read-only and replicate asynchronously. They are never promoted, sit behind their own follower load balancer, and serve application traffic. A follower on Kubernetes (Helm, microservices, or a single container in a pod) is a gap. The spec builds a Docker follower, so say so, and ask whether a Docker follower still reproduces the issue. |
| `sample_data` | "the app can't fetch secret X", "policy load fails", "hosts", "layers", "variables" | Only the demo policy and secrets. The customer's own policy never maps here. It is a gap unless it is recreated by hand. Ask whether the demo data is wanted. |
| `events` | "we upgraded", "after failover", "we promoted a standby", "restored from backup", "rebased the follower" | A reserved seam: write the value the schema accepts for no transitions. Every transition is a gap. Pin the spec to the state *before* the transition, and name the transition as set up by hand. |

### Telling a standby from a follower

Customers say "replica" for both. Two questions settle it:

- Is it ever promoted to leader? If so, it is a standby.
- Do applications authenticate against it or fetch secrets from it? If so, it is a follower.

An "async replica" in the leader's own cluster is a standby. An "async replica" the
applications talk to is a follower. "Conjur on Kubernetes" always means followers,
because the leader and standbys never run on Kubernetes.

## Gaps: never a spec field, always "set up by hand"

Each of these is something customers commonly mention that the spec cannot express.
Name it in the gaps list. Never approximate it with a field that exists, and never
invent a key for it.

**Topology**
- DR standbys, a DR site, DR promotion
- Placement across availability zones, datacenters or regions
- Synchronous vs asynchronous standby replication mode (`evoke replication sync`)
- A cluster name other than `production`, or tuned auto-failover TTLs
- Followers on Kubernetes or OpenShift, HPA, pod anti-affinity
- Replication sets or selective replication ("EU follower", "PCI follower")
- More nodes of a kind than the schema accepts. Report the rest as by hand, not as a smaller number with no explanation

**Identity and configuration**
- Authenticators of any kind: `authn-ldap`, `authn-oidc`, `authn-jwt`, `authn-k8s`, `authn-iam`, `authn-azure`, `authn-gcp`
- A Conjur account other than `demo`
- A specific admin password
- Customer hostnames or FQDNs (the environment is always `*.mycompany.local`)
- The customer's own certificates, CA or SANs
- A master key in AWS KMS or an HSM / PKCS#11
- `conjur.yml` settings, `trusted_proxies`, TLS cipher or protocol settings
- The customer's own policy, hosts and secrets

**Operations**
- Upgrades, rolling upgrades, mixed-version clusters, rollback
- Backup and restore (`evoke backup` / `evoke restore`)
- Manual promotion, `evoke replication rebase`, cluster pause / resume / clear

**Integrations and platform**
- Load balancer products (F5, NetScaler, AWS NLB/ELB), firewall rules, port changes
- Audit forwarding to a SIEM or syslog, monitoring, replication-lag alerting
- Vault Synchronizer, CyberArk PAS, secrets rotation, dynamic secrets
- Secretless Broker, Summon, credential providers, ESO
- Podman, RHEL versions, cloud platform, instance sizing

## Shapes customers commonly describe

- **Production** (knowledge base): a leader, a synchronous standby in the same
  availability zone, an asynchronous standby in another zone, and at least two
  followers spread across zones. Zone placement is a gap, and so is any follower
  beyond what the schema accepts.
- **Staging** (knowledge base): a leader, one standby and one follower.
- **"HA"** on its own does not say how many standbys there are, or whether
  auto-failover is on. Ask both.
