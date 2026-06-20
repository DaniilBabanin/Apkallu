# STATE — binding invariants (director-owned)

_Constraints every worker must respect, read before working. Empty until you add some._

This anchor is never auto-compacted; keep it to the few invariants that must always hold for THIS
instance (e.g. "never touch production config", "all schema changes go through a migration").
