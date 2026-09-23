---
runs: 3
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write]
---

Can you set me up a local repro of this customer escalation in this repo? Write the
spec to environments/globex-repro.yml.

> We're on Conjur Enterprise 13.2, HA with automatic failover, and our applications
> fetch secrets through a follower. After the last failover the follower stopped
> receiving updates and apps are reading stale values.
