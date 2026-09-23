---
type: regex
target: { source: file, path: environments/acme-repro.yml }
pattern: '^\s+custom_certificates:\s*true\s*(#.*)?$'
flags: m
---
