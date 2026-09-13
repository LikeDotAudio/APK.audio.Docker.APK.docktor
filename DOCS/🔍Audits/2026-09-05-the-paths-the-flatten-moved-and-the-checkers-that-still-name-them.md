---
subject:
  - .apk.scripts/repair_doc_links.py
  - .apk.scripts/write_baremetal_plans.py
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/Clock/discovered-clocks/read-discovered-clocks.js
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/TimeLine/strip/read-gantt-project.js
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/DataBus/mqtt-lib/load-mqtt-lib.js
  - APK:Documentation/999_📌🕰📝 Changelogs/CHANGELOG.md
---

# 🔍 The Paths The Flatten Moved, And The Checkers That Still Name Them

**Date** · §1 — 2026-09-05.

**Lane** · §2 — Connected. The shell, the servers on this bench, and the scripts that check them.

**Subject** · §3 — the `subject:` list in the front matter above. Six files: the two checkers that
carry the largest populations of dead paths, the three shell modules measured for stale URL
spellings, and the changelog, which is where a rename's collateral lands.

**Scope** · §4 — every path a checker or a shell module names as a string, across `.apk.scripts/`
and `APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/`. Not walked: `APK:Softapps/`, the vendor and scrape
trees, and anything under `APK:Documentation/` other than the changelog.

**Method** · §5 — three existing lanes, run rather than re-implemented, plus one `grep`:

```bash
./.apk.scripts/check.sh --no-stamp scriptpaths     # dead paths named by checkers
./.apk.scripts/check.sh --no-stamp osrepopath      # bare APK:OS/ in shell instructions
grep -rn "/repo/" --include=*.js "APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS"
```

**Swept against** · §6 — `2f8475baa`.

**Lens** · §7 — **Lens 1 (does it resolve)** and **Lens 6 (has the named thing left the source)**.
Deliberately **not** applied: Lens 2 (is it read by anything), Lens 3, 4, 5 and 7. So this audit
says which named paths are dead; it does **not** say whether the code that names them is reached.
A dead path in an unreachable branch is counted here exactly like a dead path in a hot one, and
separating those is a second pass this one does not make.

**Findings** · §8


**F1 · Two checkers name 28 paths that do not exist, and 18 of them are pre-flatten spellings.**
Severity: high — these are the tools the repository uses to find this exact defect elsewhere.

| file | dead paths |
|---|---:|
| `.apk.scripts/repair_doc_links.py` | 24 |
| `.apk.scripts/write_baremetal_plans.py` | 4 |

The 18 carry the signatures of two moves that have already happened: `Node:BareMetal` →
`APK:BareMetal`, the lift of the crates out of `backend/ComProtocols/`, and `APK.audio:` →
`APK:audio:`. Falsifiable: `check.sh scriptpaths` names each one with its line.

**F2 · One shell module tells a person to open five paths that do not resolve from the repository
root.** Severity: medium. All five are in
`APK:OS/Clock/discovered-clocks/read-discovered-clocks.js` — lines 45, 47, 71, 216 and 411 — and
each spells `APK:OS/…` bare, without the `APK:DOCKERS/APK:audio:WebPortal/` the tree split added.

**F3 · Four stale `/repo/` URL spellings, three of them silent.** Severity: was high, now closed.
Measured and fixed under PLAN-348.01 the same day: two live forks in `read-gantt-project.js` that
404'd every GANTT fetch on every load, one dead candidate in `load-mqtt-lib.js` masked by an earlier
candidate succeeding, and one stale directory in `server.py`'s GANTT PUT tuple. Recorded here
because the *class* is the finding: `/repo/` mounts the checkout, and everything that moved under
the portal is now one directory too shallow through it.

**F4 · A rename orphans citations the repair pass does not reach.** Severity: medium.
`rename_plan.sh` repairs plan-to-plan citations by number — its whole purpose — but not references
from `999_📌🕰📝 Changelogs/`. Measured: three links broken in one sitting by three `DONE-` renames, in
the act of closing three plans correctly. Repaired by hand the same day. `changelog.py check`
does not catch this: it reports links broken *by the groom move* (0) separately from those already
dead (1,640).

**F5 · The population is live, and this audit watched it move.** Severity: informational, and it is
the reason §6 exists. `osrepopath` reported **six** bare `APK:OS/` sites when this sweep began and
**five** an hour later — `Launch Pad/app-database/app-groups.js:72` was corrected by a concurrent
session in `ef14c1e03` while the audit was being written. Any number here without its SHA is a
number about a tree that no longer exists.

**Plan** · §9 — **re-carved 2026-09-10.** `PLAN-356.01` and `PLAN-356.02` were closed `DONE-` and
swept. Re-measurement that day closed F2 as well, and moved F1 and F4 from *repair the script* to
*the script no longer exists*.

- [ ] **Repair the 28 dead paths, and answer F4's changelog citations.**
      PLAN-3304.02
      — both checkers, and `rename_plan.sh`, went with the `.apk.scripts/` tree in `05e22b605`. The
      28 are not fixed, they are unreachable. Gated behind
      PLAN-3301.01.
- [x] **Correct the five bare `APK:OS/` spellings in `read-discovered-clocks.js`** — **verified closed
      2026-09-10.** The only surviving `APK:OS/` in that file is line 61, inside a sentence explaining
      that `/APK:FrontEnd/…` and `/APK:OS/…` are URLs and not checkout paths, which is the distinction
      the finding was about.
- [x] **Fix the four `/repo/` spellings** — done 2026-09-05, `PLAN-348.01`.

Every box above now names a file. §9 of the contract asks for that in those words — *"ordered,
checkboxed, naming the file and the reason"* — and the first draft of this audit did not: two boxes
said "wants its own plan number", which is the thing the contract calls a complaint rather than a
plan. Corrected the same day.

**Reproduce** · §10


```bash
git checkout 2f8475baa

# F1 — 28, and the 18 pre-flatten spellings inside them
./.apk.scripts/check.sh --no-stamp scriptpaths 2>&1 | grep -cE '^     - '
./.apk.scripts/check.sh --no-stamp scriptpaths 2>&1 | grep -E '^     - ' \
  | grep -cE 'Node:BareMetal|APK\.audio:|backend/ComProtocols|backend$|4-Data|DUPLICATES'

# F2 — 5
./.apk.scripts/check.sh --no-stamp osrepopath 2>&1 | grep -c 'bare APK:OS/'

# F3 — 0 remaining stale spellings; the three surviving /repo/ uses are correct
grep -rn "/repo/APK" --include=*.js "APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS" | wc -l

# F4 — the dead-link population the groom does not own
./"APK:Documentation/999_📌🕰📝 Changelogs/changelog.py" check
```
