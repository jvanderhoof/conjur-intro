---
type: regex
target: { source: file, path: environments/acme-repro.yml }
pattern: '^(?=[\s\S]*^\s+generate_dh:)(?=[\s\S]*^sample_data:)(?=[\s\S]*^events:)'
flags: m
---
