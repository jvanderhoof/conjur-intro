---
runs: 3
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write]
---

I need a local repro of a customer's environment in this repo. From the escalation:

> Secrets Manager Self-Hosted 13.5. Leader plus two Standbys in an auto-failover
> cluster. No master key encryption, and we use the default self-signed
> certificates -- no custom CA. DH parameters are the defaults. We have three
> Followers behind an F5, and all our apps authenticate with authn-ldap against
> Active Directory. We also keep a DR Standby in our secondary datacenter.

I've asked the follow-ups: load the demo policy and secrets. Write the spec to
environments/initech-repro.yml.
