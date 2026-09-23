---
type: llm
---

Check the response against this list. For each item, decide whether the response
says that it will not be built by the spec (for example "set up by hand", "a gap",
"not supported", "not expressible"):

1. LDAP authentication (authn-ldap / Active Directory)
2. the DR standby in the secondary datacenter
3. the followers beyond the three that will be built (the customer has five)

PASS if the response names all three items as not built. FAIL if any item is
missing, or is described as though the spec builds it. Nothing else matters.
