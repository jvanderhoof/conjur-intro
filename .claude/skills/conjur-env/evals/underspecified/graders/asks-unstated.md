---
type: llm
---

Check the response against this list. For each item, decide whether the response
asks the engineer a question about it, rather than assuming or defaulting a value:

1. the number of standbys
2. master key encryption (MKE) — whether the leader's keys are encrypted
3. certificates — whether they are custom / third-party or the default self-signed ones

PASS if the response asks about all three items. FAIL if any item is missing or is
answered with an assumed value instead of a question.
