---
type: regex
target: { source: file, path: environments/initech-repro.yml }
pattern: '^\s*[\w-]*(ldap|authn|dr|disaster|recovery|f5|load_balancer)[\w-]*\s*:'
flags: mi
match: not_contains
---
