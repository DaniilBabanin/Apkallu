# Graph Report - .  (2026-06-19)

## Corpus Check
- 64 files · ~58,246 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 459 nodes · 704 edges · 47 communities (38 shown, 9 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 23 edges (avg confidence: 0.81)
- Token cost: 60,019 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Agency Design Principles|Agency Design Principles]]
- [[_COMMUNITY_VM Lifecycle Management|VM Lifecycle Management]]
- [[_COMMUNITY_Budget Scheduler|Budget Scheduler]]
- [[_COMMUNITY_Task Decomposition Cascade|Task Decomposition Cascade]]
- [[_COMMUNITY_KVStore Eval Fixture|KVStore Eval Fixture]]
- [[_COMMUNITY_Egress Proxy|Egress Proxy]]
- [[_COMMUNITY_Local Model Queue|Local Model Queue]]
- [[_COMMUNITY_Health Watcher|Health Watcher]]
- [[_COMMUNITY_Loop Runner|Loop Runner]]
- [[_COMMUNITY_Operator TUI|Operator TUI]]
- [[_COMMUNITY_Postgres Control Plane|Postgres Control Plane]]
- [[_COMMUNITY_Commit Ledger Enforcement|Commit Ledger Enforcement]]
- [[_COMMUNITY_Scheduler Budget Tests|Scheduler Budget Tests]]
- [[_COMMUNITY_VM Isolation Tests|VM Isolation Tests]]
- [[_COMMUNITY_Sandbox Setup|Sandbox Setup]]
- [[_COMMUNITY_Parallel Job Dispatch|Parallel Job Dispatch]]
- [[_COMMUNITY_Model Smoke Test|Model Smoke Test]]
- [[_COMMUNITY_Postgres Test Fixture|Postgres Test Fixture]]
- [[_COMMUNITY_Queue Tests|Queue Tests]]
- [[_COMMUNITY_VM Session Runner|VM Session Runner]]
- [[_COMMUNITY_Session Event Logger|Session Event Logger]]
- [[_COMMUNITY_Cascade Postgres Tests|Cascade Postgres Tests]]
- [[_COMMUNITY_Enforcement Tests|Enforcement Tests]]
- [[_COMMUNITY_Run Completion Tests|Run Completion Tests]]
- [[_COMMUNITY_Local LLM Serving|Local LLM Serving]]
- [[_COMMUNITY_State Sync|State Sync]]
- [[_COMMUNITY_Status Dashboard|Status Dashboard]]
- [[_COMMUNITY_Cascade Tests|Cascade Tests]]
- [[_COMMUNITY_Status Tests|Status Tests]]
- [[_COMMUNITY_VM Image Build|VM Image Build]]
- [[_COMMUNITY_Decision Queue Tests|Decision Queue Tests]]
- [[_COMMUNITY_Postgres Lineage Tests|Postgres Lineage Tests]]
- [[_COMMUNITY_Postgres Queue Tests|Postgres Queue Tests]]
- [[_COMMUNITY_Sandbox Config Tests|Sandbox Config Tests]]
- [[_COMMUNITY_Decision Queue|Decision Queue]]
- [[_COMMUNITY_Retrospective|Retrospective]]
- [[_COMMUNITY_Digest Tests|Digest Tests]]
- [[_COMMUNITY_Postgres Writers Tests|Postgres Writers Tests]]
- [[_COMMUNITY_Lineage Recorder|Lineage Recorder]]
- [[_COMMUNITY_Map Gen Tests|Map Gen Tests]]
- [[_COMMUNITY_Scheduler Probe Tests|Scheduler Probe Tests]]
- [[_COMMUNITY_State Sync Tests|State Sync Tests]]
- [[_COMMUNITY_DB Migration|DB Migration]]
- [[_COMMUNITY_The Gate|The Gate]]
- [[_COMMUNITY_Activity Digest|Activity Digest]]
- [[_COMMUNITY_Repo Map Generator|Repo Map Generator]]

## God Nodes (most connected - your core abstractions)
1. `AGENCY.md operating guide` - 16 edges
2. `KVStore` - 15 edges
3. `up()` - 11 edges
4. `virsh()` - 10 edges
5. `main()` - 10 edges
6. `Routing policy (work -> execution lane)` - 10 edges
7. `cascade.sh script` - 9 edges
8. `scheduler.sh script` - 9 edges
9. `main_run()` - 9 edges
10. `tui.sh script` - 9 edges

## Surprising Connections (you probably didn't know these)
- `Execution honesty (no fabricated success)` --semantically_similar_to--> `Assume every worker model is prompt-injectable`  [INFERRED] [semantically similar]
  CLAUDE.md → policy/routing.md
- `GUPP (coordinate through git, not LLM judgment)` --rationale_for--> `Apkallu (self-hosted autonomous dev agency)`  [INFERRED]
  AGENCY.md → README.md
- `AGENCY.md operating guide` --references--> `backlog.md task list`  [EXTRACTED]
  AGENCY.md → backlog.md
- `AGENCY.md operating guide` --references--> `STATE.md binding invariants`  [EXTRACTED]
  AGENCY.md → director/STATE.md
- `AGENCY.md operating guide` --references--> `NOTES.md append-only build log`  [EXTRACTED]
  AGENCY.md → NOTES.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **The execution lanes (orchestrator/local/remote/VM/frontier)** — agency_orchestrator_lane, policy_routing_local_lane, policy_routing_remote_lane, policy_routing_vm_lane, policy_routing_frontier_lane [EXTRACTED 1.00]
- **The three trust boundaries** — policy_substrate_trust_boundaries, architecture_vm_security_boundary, policy_routing_injection_unsafe, agency_decisions_queue [INFERRED 0.85]
- **kvstore unimplemented features** — kvstore_readme_ttl_expiry, kvstore_readme_lru_eviction, kvstore_readme_json_persistence [EXTRACTED 1.00]

## Communities (47 total, 9 thin omitted)

### Community 0 - "Agency Design Principles"
Cohesion: 0.05
Nodes (56): Apkallu (self-hosted autonomous dev agency), Non-blocking decisions queue, Fix-rigor principle (works AND broke nothing else), The gate (gate.sh, RESULT: PASS), GUPP (coordinate through git, not LLM judgment), Instruction routing paths (do/queue/decompose/escalate), AGENCY.md operating guide, Orchestrator (frontier reasoning, decides + verifies) (+48 more)

### Community 1 - "VM Lifecycle Management"
Cohesion: 0.16
Nodes (30): _define_filter(), _delete_vols(), destroy(), dom(), _ensure_proxy(), _filter_xml(), get_branch(), get_files() (+22 more)

### Community 2 - "Budget Scheduler"
Cohesion: 0.14
Nodes (15): scheduler.sh script, billing_mode(), budget_status(), capture_cap_event(), have_task(), local_tier_work(), log(), main_run() (+7 more)

### Community 3 - "Task Decomposition Cascade"
Cohesion: 0.13
Nodes (16): cascade.sh script, cmd_decompose(), cmd_dispatch(), cmd_reconcile(), cmd_reset(), escalate(), insert_block(), next_ready() (+8 more)

### Community 4 - "KVStore Eval Fixture"
Cohesion: 0.12
Nodes (9): KVStore, kvstore.core — a small key-value store.  Basic get/set/delete/len/keys work. THR, FakeClock, Deterministic test suite for kvstore (no pytest dependency — run `python tests/t, test_basic(), test_default_ttl(), test_lru_eviction(), test_persistence_roundtrip() (+1 more)

### Community 5 - "Egress Proxy"
Cohesion: 0.18
Nodes (6): allowed(), Handler, Handler, main(), _read_key(), BaseHTTPRequestHandler

### Community 6 - "Local Model Queue"
Cohesion: 0.19
Nodes (8): queue.sh script, cmd_drain(), cmd_enqueue(), cmd_next(), cmd_run(), cmd_status(), cmd_submit(), with_lock()

### Community 7 - "Health Watcher"
Cohesion: 0.26
Nodes (14): watcher.sh script, add_crit(), add_warn(), check_decisions(), check_disk(), check_stall(), check_vram(), do_backup() (+6 more)

### Community 8 - "Loop Runner"
Cohesion: 0.22
Nodes (10): run.sh script, commit_closed_task(), compute_sig(), escalate(), hash_file(), hash_stdin(), notify(), run_claude() (+2 more)

### Community 9 - "Operator TUI"
Cohesion: 0.32
Nodes (12): tui.sh script, act_answer(), act_dispatch(), act_follow(), act_reset(), act_start(), act_stop(), act_vmssh() (+4 more)

### Community 10 - "Postgres Control Plane"
Cohesion: 0.19
Nodes (6): pg.sh script, pg_complete_job(), pg_fail_job(), _pg_init(), pg_insert_job(), _pg_uuid_ok()

### Community 11 - "Commit Ledger Enforcement"
Cohesion: 0.23
Nodes (6): enforce.sh script, cmd_counts(), cmd_project_commit(), cmd_record(), cmd_sanitize(), usage()

### Community 12 - "Scheduler Budget Tests"
Cohesion: 0.42
Nodes (10): scheduler_budget_test.sh script, bsched(), expect_action(), expect_eq(), expect_num(), fail(), num_eq(), pass() (+2 more)

### Community 13 - "VM Isolation Tests"
Cohesion: 0.38
Nodes (7): bad(), check(), http_code(), is_rfc1918(), ok(), ssh_vm(), test_isolation.sh script

### Community 14 - "Sandbox Setup"
Cohesion: 0.50
Nodes (8): sandbox-setup.sh script, apparmor_warn(), deps_ok(), do_check(), do_install(), settings_ok(), snippet(), usage()

### Community 15 - "Parallel Job Dispatch"
Cohesion: 0.32
Nodes (7): demo_jobs(), main(), ram_cap(), Max concurrent VMs that fit in host RAM with headroom (61 GB host -> ~11 at 4 GB, Run one session via run_session.py; never raises (a single job's failure must no, K=3 sessions on the kvstore fixture (distinct VMs/results) — the a build phase e, run_one()

### Community 16 - "Model Smoke Test"
Cohesion: 0.39
Nodes (7): ensure_proxy(), ensure_up(), main(), Start the host proxy if it isn't already up. Returns the Popen we started (so we, Run smoke_agent.py in the VM for one model over an ssh -R tunnel; return the par, run_model(), write_report()

### Community 17 - "Postgres Test Fixture"
Cohesion: 0.29
Nodes (6): pg_fixture.sh script, AGENCY_PG_DB, AGENCY_PG_HOST, AGENCY_PG_PORT, AGENCY_PG_USER, pg_fixture_teardown()

### Community 18 - "Queue Tests"
Cohesion: 0.46
Nodes (7): queue_test.sh script, check(), fail(), ok(), QUEUE_FILE, QUEUE_OUT_DIR, reset_q()

### Community 19 - "VM Session Runner"
Cohesion: 0.48
Nodes (6): ensure_proxy(), main(), _put(), Run a command in the VM; return CompletedProcess (stdout+stderr merged)., _scp_out(), _ssh()

### Community 20 - "Session Event Logger"
Cohesion: 0.38
Nodes (6): _event_text(), _fmt_event(), _git(), main(), Pull the human-readable text out of an event's observation/llm_message (a nested, One compact, human-readable line per event for the live events.log (`tail -f` mo

### Community 21 - "Cascade Postgres Tests"
Cohesion: 0.38
Nodes (5): cascade_pg_test.sh script, AGENCY_HOST_CREDENTIALS, fail(), pass(), TMP_STUB_OUT

### Community 22 - "Enforcement Tests"
Cohesion: 0.43
Nodes (4): enforce_test.sh script, enf(), fail(), pass()

### Community 23 - "Run Completion Tests"
Cohesion: 0.67
Nodes (5): run_completion_test.sh script, chk(), fail(), ic(), pass()

### Community 24 - "Local LLM Serving"
Cohesion: 0.53
Nodes (4): llm.sh script, ensure_loaded(), probe_ok(), serving_at()

### Community 25 - "State Sync"
Cohesion: 0.60
Nodes (4): state-sync.sh script, apply_block(), main(), print_block()

### Community 26 - "Status Dashboard"
Cohesion: 0.47
Nodes (3): status.sh script, print_procs(), print_vms()

### Community 27 - "Cascade Tests"
Cohesion: 0.47
Nodes (4): cascade_test.sh script, AGENCY_HOST_CREDENTIALS, fail(), pass()

### Community 28 - "Status Tests"
Cohesion: 0.47
Nodes (3): status_test.sh script, fail(), pass()

### Community 29 - "VM Image Build"
Cohesion: 0.70
Nodes (4): die(), log(), ssh_agent(), build-image.sh script

### Community 30 - "Decision Queue Tests"
Cohesion: 0.60
Nodes (4): decide_test.sh script, DECIDE_LIB, expect_eq(), mkfix()

### Community 31 - "Postgres Lineage Tests"
Cohesion: 0.60
Nodes (3): pg_lineage_test.sh script, fail(), pass()

### Community 32 - "Postgres Queue Tests"
Cohesion: 0.70
Nodes (4): pg_queue_test.sh script, _claim_all(), fail(), pass()

### Community 33 - "Sandbox Config Tests"
Cohesion: 0.90
Nodes (4): sandbox_config_test.sh script, assert_cfg(), bad(), ok()

### Community 34 - "Decision Queue"
Cohesion: 1.00
Nodes (3): decide.sh script, open_decisions(), record_answer()

### Community 36 - "Digest Tests"
Cohesion: 0.83
Nodes (3): digest_test.sh script, fail(), pass()

### Community 37 - "Postgres Writers Tests"
Cohesion: 0.83
Nodes (3): pg_writers_test.sh script, fail(), pass()

## Knowledge Gaps
- **26 isolated node(s):** `migrate.sh script`, `gate.sh script`, `digest.sh script`, `map-gen.sh script`, `AGENCY_HOST_CREDENTIALS` (+21 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **9 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Are the 5 inferred relationships involving `KVStore` (e.g. with `test_basic()` and `test_default_ttl()`) actually correct?**
  _`KVStore` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `migrate.sh script`, `Max concurrent VMs that fit in host RAM with headroom (61 GB host -> ~11 at 4 GB`, `Run one session via run_session.py; never raises (a single job's failure must no` to the rest of the system?**
  _46 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Agency Design Principles` be split into smaller, more focused modules?**
  _Cohesion score 0.0512987012987013 - nodes in this community are weakly interconnected._
- **Should `Budget Scheduler` be split into smaller, more focused modules?**
  _Cohesion score 0.13538461538461538 - nodes in this community are weakly interconnected._
- **Should `Task Decomposition Cascade` be split into smaller, more focused modules?**
  _Cohesion score 0.13405797101449277 - nodes in this community are weakly interconnected._
- **Should `KVStore Eval Fixture` be split into smaller, more focused modules?**
  _Cohesion score 0.11857707509881422 - nodes in this community are weakly interconnected._