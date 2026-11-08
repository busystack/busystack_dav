# Unreleased

- Decode required BOM-marked UTF-16 DAV XML in buffered and streaming parsers.
  Strict surrogate/byte validation, DTD/entity rejection, cancellation and all
  existing resource limits remain enforced. No third-party XML code changed.

# 0.1.0

Initial independent protocol/contacts implementation. Public entry points, examples, provider contracts and deterministic regressions. Existing-app adoption is deferred to explicitly authorized Milestone 2.
