---
type: regex
target: { source: file, path: environments/acme-repro.yml }
pattern: '^\s+standbys:\s*2\s*(#.*)?$'
flags: m
---
