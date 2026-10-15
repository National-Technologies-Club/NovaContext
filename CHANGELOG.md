# Changelog

## Unreleased — v0.1 candidate

- Durable, scoped memories backed by published NovaGraph 1.0.0, with explicit kind, origin, source and pinning.
- Complete replacement by scope/UUID, durable deletion/clear, schema validation and explicit capacity errors.
- Full coherent scoped memory lists in pin/update-time/UUID order, including records omitted from context budgets; read failures never return a partial list.
- Atomic text/pin updates that preserve creation time and provenance, skip unchanged writes, and return nil without recreating missing records. Disjoint field edits are preserved, with queue order deciding same-field changes.
- Deterministic bounded context assembly with whole-record selection, exact rendered byte accounting, caller-supplied token counts and omission reporting.
- Serialized storage operations, cooperative cancellation, explicit trim/suspend/resume/close and observable failure outcomes.
- A separate SwiftUI/Foundation Models example with model-free preview, fresh per-question sessions, inspected context and explicit model-memory saves.
- Package CI, usage/compatibility documentation and independent clean-consumer installation verification.

The owner reports a successful installed-sample test; a detailed physical-device qualification record remains incomplete. This candidate is local and has no published NovaContext remote, release tag or production certification.
