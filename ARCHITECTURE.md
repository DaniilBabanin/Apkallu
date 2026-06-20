# ARCHITECTURE — your instance's design + principles

_Director-owned. Replace this with the design of THIS Apkallu instance and the numbered principles it
holds. The gate (`gate.sh`), the watchdog (`local/watcher.sh`), the scheduler, and the digest all
refer to these principles — define the ones you want enforced._

Suggested starting principles (edit freely):

1. **No green, no merge.** A unit is done only when `./gate.sh` ends in `RESULT: PASS`.
2. **Idle quota is waste.** The scheduler bursts work whenever budget/quota allow.
3. **Coordinate through git, not an LLM's judgment** (GUPP).
4. **The VM is the security boundary**; untrusted output is gated before it touches anything real.
