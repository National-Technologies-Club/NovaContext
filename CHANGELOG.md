# Changelog

## 0.1.0 — prepared, publication pending

- Durable, scoped memories backed by published NovaGraph 1.0.0, with explicit kind, origin, source and pinning.
- Complete replacement by scope/UUID, durable deletion/clear, schema validation and explicit capacity errors.
- Full coherent scoped memory lists in pin/update-time/UUID order, including records omitted from context budgets; read failures never return a partial list.
- Atomic text/pin updates that preserve creation time and provenance, skip unchanged writes, and return nil without recreating missing records. Disjoint field edits are preserved, with queue order deciding same-field changes.
- Deterministic bounded context assembly with whole-record selection, exact rendered byte accounting, caller-supplied token counts and omission reporting.
- Scoped keyword recall over normalized, case-folded whole terms in memory text, ranked by distinct matched terms before pinning/recency/UUID. Queries are bounded to 1,024 original UTF-8 bytes; no matches return empty context without automatic fallback, and omissions include every unselected scoped record.
- Whole-request composition with separate instructions/prompt, mandatory-content fit checks, supplied memory ranking and a contiguous suffix of explicit recent history. Combined byte limits and optional asynchronous request-token counting include the complete candidate input, with explicit reservation and omission reporting.
- Serialized storage operations, cooperative cancellation, explicit trim/suspend/resume/close and observable failure outcomes.
- A separate SwiftUI/Foundation Models example with a full editable stored-memory list, pin controls and visible provenance; captured-question recall, exact composed instructions/prompt and combined byte count; and answer invalidation plus recomposition after memory changes. Model-free preview, fresh sessions, cancellation, lifecycle handling and explicit model-memory saves remain available.
- A sample-only read-only `search_project_notes` tool, fixed to the host project scope with two attempts per question and bounded queries/whole results. Separate composed-input and completed-search displays retain captured-question identity; results stay ephemeral, and lifecycle invalidation prevents stale publication. No public tool/plugin API is introduced.
- Package CI, usage/compatibility documentation and independent clean-consumer installation verification.
- Apache 2.0 license, copyright attribution, contribution instructions and first-release notes.

These are the prepared contents of the first source release. The National-Technologies-Club/NovaContext repository has been created; source/tag publication and hosted CI are pending. Physical-device and real-model tool-selection qualification remain pending; the earlier successful owner sample report is retained in the compatibility guide.
