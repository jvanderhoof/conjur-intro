---
type: regex
target: { source: file, path: environments/acme-repro.yml }
pattern: '^sample_data:\s*false\b'
flags: m
match: not_contains
---
