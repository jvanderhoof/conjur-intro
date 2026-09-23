---
type: regex
target: { source: file, path: environments/acme-repro.yml }
pattern: '^\s+generate_dh:\s*true\b'
flags: m
match: not_contains
---
