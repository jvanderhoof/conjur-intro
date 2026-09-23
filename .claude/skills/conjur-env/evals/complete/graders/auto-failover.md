---
type: regex
target: { source: file, path: environments/acme-repro.yml }
pattern: '^\s+auto_failover:\s*true\s*(#.*)?$'
flags: m
---
