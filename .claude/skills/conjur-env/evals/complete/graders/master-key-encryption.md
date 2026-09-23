---
type: regex
target: { source: file, path: environments/acme-repro.yml }
pattern: '^\s+master_key_encryption:\s*true\s*(#.*)?$'
flags: m
---
