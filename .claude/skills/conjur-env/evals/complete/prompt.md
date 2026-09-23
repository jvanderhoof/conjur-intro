---
runs: 3
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write]
---

I need a local repro of a customer's environment in this repo. Here's what they told
us in the escalation:

> We run Secrets Manager Self-Hosted 13.5 as a 3-node cluster -- the Leader plus two
> Standbys -- with AFO turned on. Server keys are encrypted with a master key file
> (MKE). TLS uses certificates from our internal CA, which we imported with
> `evoke ca import`. There's a single Follower on a VM, and that's what our apps
> talk to. We've never touched the DH parameters; they're whatever ships by default.

I've already asked them the follow-ups: load the demo policy and secrets, so we have
something to fetch. Write the spec to environments/acme-repro.yml.
