# Converts a declarative environment spec from YAML to JSON and validates it
# against environments/schema.json, so that neither a YAML parser nor a JSON
# Schema validator becomes a host dependency of bin/env.
#
# Everything is pinned: the schema is the contract, and a validator that drifts
# between machines would make it a suggestion instead.
FROM python:3.12.7-alpine3.20

RUN pip install --no-cache-dir \
      PyYAML==6.0.2 \
      jsonschema==4.23.0

COPY validate-spec /usr/local/bin/validate-spec

ENTRYPOINT ["/usr/local/bin/validate-spec"]
