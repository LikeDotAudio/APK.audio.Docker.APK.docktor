# 🏛️ Philosophy — Testing Strategy, Execution Architecture & Agent Cost Optimization

> **Standing Decision & Design Law**  
> **Adopted:** 2026-08-31  
> **Scope:** Monorepo Testing Philosophy, AI Agent Verification Workflows, and Software Testability Laws  
> **Primary Orchestrator:** `./.apk.scripts/check.sh`

---

## 1. Abstract & Standing Principles

In the **APK.audio** ecosystem, automated testing is not an administrative compliance step or a code coverage trophy. It is the core engineering mechanism that enforces system contracts, protects hardware from catastrophic misconfiguration, and guarantees that software state remains deterministic across monorepo changes.

Every test in this repository MUST obey three fundamental standing principles:

1. **Local-First Pre-Push Verification:** Tests run on your machine before code is pushed. CI does not re-test what your machine should have verified; CI only checks the signed stamp (`APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/system/validated.json`).
2. **Refusal Over Fabrication:** A failing test MUST fail loudly, immediately, and with exact diagnostic evidence. It must never swallow exceptions, return dummy fallback data, or pass silently when underlying assumptions break.
3. **Agent Cost Optimization:** Test execution MUST be structured so that AI coding agents (and human engineers) can verify changes in milliseconds without spending unnecessary execution budget or context tokens on heavy, monolithic test runs.

---

## 2. Agent Cost Optimization: How Tests SHOULD Be Run & Activated

AI coding agents (such as Antigravity, Claude, etc.) operate in tool-calling loops. When an agent edits a code file, it needs to verify that its edit worked. 

If verifying a 5-line change requires running a 5-minute integration build, spinning up Docker containers, or executing 500 unrelated unit tests:
- Context windows become flooded with thousands of lines of irrelevant build logs.
- Agent turn budgets and token costs multiply by 10x to 50x.
- Iteration speed drops from seconds to minutes.

To maximize confidence while keeping agent tool execution fast and cheap, all testing in APK.audio follows the **4-Tier Verification Hierarchy**:

```
                       ▲
                      ╱ ╲
                     ╱   ╲   Tier 3: Heavy Integration & Rig Probes
                    ╱ L3  ╲  (Docker, Headless Browsers, Hardware) -> On-Demand / Pre-Commit
                   ╱───────╲
                  ╱         ╲   Tier 2: Hermetic Subsystem Tests
                 ╱    L2     ╲  (In-memory DBs, Mocked MQTT) -> Targetable Subsystems
                ╱─────────────╲
               ╱               ╲   Tier 1: Isolated Invariant Unit Tests
              ╱       L1        ╲  (Pure Functions, Single File <3s) -> Direct File Execution
             ╱───────────────────╲
            ╱                     ╲   Tier 0: Ultra-Fast Static Ratchets & Types
           ╱          L0           ╲  (tsc --noEmit, Regex Ratchets <500ms) -> Always Run First
          └─────────────────────────┘
```

---

### Tier 0: Ultra-Fast Static Ratchets & Types (<500 ms)
- **What it is:** Pure static checks, TypeScript typechecking (`tsc --noEmit`), regex ratchets, line count checkers, and link integrity guards.
- **When to run:** Immediately after modifying any source file.
- **Agent Rule:** Always execute targeted L0 checks first (e.g. `python3 .apk.scripts/check_plan_prefixes.py` or `./.apk.scripts/check.sh contracts`).

### Tier 1: Single-File Isolated Invariant Unit Tests (<3 seconds)
- **What it is:** Pure-function mathematical assertions, state transition tests, and lightweight VM stub tests (such as `signal-laws.test.js`).
- **When to run:** When modifying specific domain logic, math, or data parsers.
- **Agent Rule:** Pass the exact target test file to the test runner. **NEVER** run the global test suite when verifying a single file change.
  - *Good:* `npx vitest run src/shared/money/Money.test.ts`
  - *Bad:* `npm test` (runs 500+ backend/frontend tests).

### Tier 2: Hermetic Subsystem Tests (<20 seconds)
- **What it is:** Subsystem integration tests running against in-memory SQLite, stubbed brokers, or compiled WASM modules.
- **When to run:** When modifying subsystem APIs or data bus serializations.
- **Agent Rule:** Execute via targeted `./.apk.scripts/check.sh <lane>` commands (e.g. `./.apk.scripts/check.sh scan-analyzer`).

### Tier 3: Heavy Integration & Rig Probes (Pre-Commit / On-Demand Only)
- **What it is:** Full Docker container spin-up (MariaDB schema parity), PlatformIO firmware builds, or full headless browser contact sheet capture.
- **When to run:** Only prior to staging commits or when explicitly debugging container/database bugs.
- **Agent Rule:** Skip L3 during rapid iterative coding unless the task explicitly targets container/database code.

---

## 3. Best Practices for Test Architecture

### 1. Single-File Targetability
Every test file MUST be executable independently via a single command line without requiring custom global environment setups.

```bash
# JavaScript / TypeScript (Vitest / Node)
npx vitest run path/to/target.test.ts
node --test path/to/target.test.js

# Python
python3 -m pytest path/to/target_test.py

# Rust
cargo test -p crate_name --lib test_function_name
```

### 2. Zero Heavy Dependencies for Unit Tests
- Do **NOT** pull in heavy browser emulators (like `jsdom` or `playwright`) for pure business logic or state calculations.
- Use lightweight JS `vm` sandboxes or minimal object stubs (as demonstrated in `signal-laws.test.js`).

### 3. Ratchet Technical Debt Instead of Failing on Inherited Debt
- When adding static analysis or quality enforcement checks, implement a **ratchet mechanism** (baseline ceiling file).
- The ratchet MUST freeze existing technical debt and fail strictly if technical debt *increases*.
- This allows new code to be held to 100% standards without blocking developers or AI agents on legacy backlogs.

### 4. Structured & Concise Log Outputs
- Test failure output MUST be concise. Print the exact line number, expected vs actual values, and root cause stack trace.
- Avoid dumping thousands of unformatted HTML/JSON lines into stdout.

---

## 4. Best Practices for Software Design (Testing-First Architecture)

To ensure the software remains easily testable by both humans and AI agents:

1. **Decouple Pure Logic from Side Effects:**
   - Keep domain logic (schematic calculations, audio timing curves, BOM pricing, data transformations) in pure functions with zero I/O, network, or DOM side-effects.
   - Pure functions can be tested in sub-milliseconds without mocks.

2. **Enforce Contract-First Boundaries:**
   - Define strict TypeScript interfaces, Rust structs, and JSON schema lockfiles for all internal APIs and topic messages.
   - Verify serialization/deserialization at boundary layers.

3. **Self-Describing Diagnostics:**
   - Errors in production and test code must carry structured context keys (`code`, `details`, `expected`, `actual`) rather than generic string messages.

---

## 5. Summary Checklist for Developers & AI Agents

Before submitting code changes:
- [ ] Ran targeted L0/L1 test for the modified file in <3 seconds.
- [ ] Ensured no new console warnings, unhandled promise rejections, or memory leaks were introduced.
- [ ] Confirmed that tests pass locally using `./.apk.scripts/check.sh <lane>`.
- [ ] Staged the updated `validated.json` flag (`git add APK:OS/system/validated.json`) before committing.

---

## 6. Pre-Build Test Enforcements & Docker Container Refusal Laws

> **Standing Law (Carved in PLAN-170.01):**  
> If upstream unit/contract tests fail, Docker container compilation and stack mounting **MUST BE STRICTLY REFUSED**.  
> Each container service build MUST be tied to its specific upstream test gate.

### Container Service Pre-Build Test Matrix

| Container Service | Build Target | Pre-Build Test Gate | Refusal Policy |
| :--- | :--- | :--- | :--- |
| **`apkaudio-broker`** | MQTT Mosquitto | Broker candidate order & socket checks (`run_brokerlist`) | **REFUSE BUILD** if discovery or candidates fail |
| **`Storage-MariaDB`** | MariaDB 11.4 | None — the schema-lock gate went with oneScope | *(no gate)* |
| **`apk-audio` (Web Shell)** | Web Portal | Static boot snapshot (`run_static_boot`) | **REFUSE BUILD** if PHP contains syntax errors |

### Enforcement Mechanisms

1. **`docker scripts/test-gates.sh`:**  
   The gates themselves, and the only place they are spelled. Non-zero exit means the build must not run.
2. **`up.sh`, `rebuild-all.sh` and `rebuild-core.sh`:**  
   Every script that builds runs `test-gates.sh` first and aborts on a failure. There is no `--skip-tests`; `APKAUDIO_NO_GATES=1` exists only for debugging the gates themselves and is forbidden in automated pipelines.
3. **`Manager:docktor.py` and `APK.audio:mount.sh`:**  
   Neither enforces anything of its own any more — they run the scripts above, so the dashboard button and the command line cannot disagree about what a gate is.

