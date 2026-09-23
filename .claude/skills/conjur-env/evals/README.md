# conjur-env evals

These evals measure whether the skill turns a customer's description into the right
spec more reliably than the same agent does without the skill. They are not a
regression gate, and they are not part of `bin/env-test`. Each run is a real agent
session that costs money, so run them by hand while changing the skill.

```sh
.claude/skills/conjur-env/evals/run                  # every case, both arms, 3 runs each
.claude/skills/conjur-env/evals/run --case gaps --runs 1 --ablation none   # iterate cheaply
```

`claude plugin eval` runs each case twice: once with the skill loaded and once with
no plugin at all. The number worth reading is the **delta** between those two arms.
A single arm's score says little on its own, because a model can get a clear
description right without help.

## The fair baseline

Each run starts in an empty directory. `_workspace/seed.sh` copies the repo's
tracked files into it, **except `.claude/`**. It does this in both arms, so the
baseline agent has the same `bin/env`, schema, examples and docs the skill points
at, but cannot read the skill. The question is therefore "does the skill beat an
agent that has the repo?", not "does it beat an agent that has nothing?".

## The cases

| Case | The description | Main check |
|---|---|---|
| `complete` | States every field, in customer wording ("3-node cluster", "AFO", "MKE", "internal CA") | Each field's value in the written spec, and that every field is written out |
| `underspecified` | Leaves most fields unstated | No spec is written, because the agent should ask first; a judge checks it asked about standbys, MKE and certificates |
| `gaps` | Adds things no field expresses (authn-ldap, a DR standby, three followers) | No invented keys, the follower count capped, the core fields right; a judge checks all three gaps are named as set up by hand |

## Keeping the graders from being fragile

- **Deterministic graders read values, not wording.** Each one is a line-anchored
  regex on one field of the spec file. It does not care about key order, comments,
  or which quote character is used. That a value sits under `leader:` is checked
  only as far as indentation shows it.
- **A field whose right answer is its schema default is checked as "not the
  opposite".** For example, `generate_dh` must not be `true`. A spec that omits the
  field is still the right configuration. A separate grader, `every-field`,
  checks that the skill's rule of writing every field out was followed. The baseline
  is judged by that rule too, so the grader measures the rule, not the configuration.
- **Judges answer yes/no questions about what was asked and named.** They never
  score style. Each rubric is a numbered checklist. `run` pins the judge to
  Sonnet 5, not the harness's default Haiku. On the first run of this suite, Haiku
  gave unanimous opposite verdicts on two replies whose gap lists were nearly word
  for word the same.
- **`skill-fired` is an indicator, not part of the score.** The harness excludes it
  in two-arm runs, because it can never pass without the skill.

## What the evals do not cover

- **Validation and the gate's plan output.** Runs are granted `Write` but not
  `Bash`. That is partly deliberate, since nothing can provision. It is also
  forced: the eval sandbox refuses Bash on a host whose `~/.docker` holds a
  symlink, and `bin/env --plan` could not reach docker from inside it anyway. The
  skill is told to say when a spec is unvalidated. `test/env.bats` covers the
  schema and `bin/env`.
- **Provisioning and verification.** In a headless run nobody answers the gate,
  so every run stops there. That is also what makes the cases safe to run.
- **The answers to the questions.** The skill's multi-turn flow is exercised only
  up to the point where it asks. `complete` and `gaps` supply the engineer's
  follow-up answers in the prompt.

## Changing the suite

The customer descriptions are invented and sanitized. Keep them that way, because
this directory ships to the public mirror. When a field is added to the schema, add
a grader for it to `complete`. Otherwise the skill can get the new field wrong
without the eval noticing.
