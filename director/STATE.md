# STATE — binding invariants (director-owned)

Constraints every worker must respect, read before working. This anchor is never auto-compacted; keep
it to the few invariants that must always hold for THIS instance.

1. **Gate before done.** No unit is complete until `./gate.sh` ends in `RESULT: PASS`.
2. **Irreversible actions escalate.** Deploy, delete, credentials, or money never run on a worker —
   queue a decision with default NO and stop only that action.
3. **Schema changes go through a migration** in `db/migrations/` — never hand-edit a live database.
4. **`NOTES.md` is append-only.** Add at the end; never rewrite or reorder (the gate enforces this).
5. **No secrets in the repo or in worker context.** Inference keys stay host-side, off the VM.
6. **Untrusted code runs only in the sandbox/VM**, never directly on the host.
