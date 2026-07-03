# Decisions Queue

Non-blocking director decisions (ARCHITECTURE principle 1). Workers and the loop append
`## D-NNN — <title>` entries (escalate() in loop/run.sh / loop/cascade.sh, or by hand per
CLAUDE.md); a blank `**Answer:**` line means OPEN. The director answers via
`local/decide.sh apply D-NNN <verdict>` or the TUI's [a] key.
