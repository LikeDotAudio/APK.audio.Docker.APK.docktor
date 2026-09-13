---
subject:
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/buttons/lit-words.js
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/buttons/ButtonToggle/ButtonToggle.jsx
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/text/OcaTable/OcaTable.jsx
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/graphing/Equalization/Equalization.jsx
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/graphing/DynamicGraph/DynamicGraph.jsx
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/frameLayout/FieldComponent.jsx
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/comMQTT/MqttProvider.jsx
  - .apk.scripts/audit_frontend_comments.py
  - .apk.scripts/linecount.baseline.json
  - .apk.scripts/baremetal_module_facts.py
---

# 🧹 The Front End Carries A Header That Says Nothing, And A Header That Says Too Much

**Date** · §1 — 2026-09-06.

**Lane** · §2 — **PUBLISH**. `APK:FrontEnd/` is filed there by the North Star — *"the published
surfaces — the shell and the windows it opens, and nothing else"*
(NORTH-STAR.md, §5 · Publish). Every file measured here ships.

**Subject** · §3 — the `subject:` list above. Seven front-end files that are the worst instance of
one of the five classes below, plus the script that produced every number, plus the two existing
tools this audit says are looking at the wrong tree.

**Scope** · §4 — the 238 tracked source files under
`APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/`, extensions `.js .mjs .jsx .ts .tsx .html .css`,
with `vendor/ node_modules/ .next/ dist/ public/` dropped. That is 35,070 lines, of which **5,946
(17%) are whole-line comments**. Not walked: `APK:OS/`, `APK:Softapps/`, `APK:BareMetal/` — the same
generator sprayed all of them, and F1 below says what the BareMetal pass already found there.

**Method** · §5 — one script, `.apk.scripts/audit_frontend_comments.py`, written for this audit and
committed with it:

```bash
python3 ".apk.scripts/audit_frontend_comments.py" --rev HEAD  # the five tables
python3 ".apk.scripts/audit_frontend_comments.py" --sites C1  # every site, with line numbers
python3 ".apk.scripts/audit_frontend_comments.py" --json      # the same, machine-readable
```

**Every number below is read at the commit in §6, not off the working tree**, which is what `--rev`
is for. The default is the working tree — that is what a push carries — but thirteen sessions share
this checkout and the census moved seven lines while it was being written. An audit whose numbers
depend on who else was saving is not reproducible, so this one pins them.

It is a script and not a recipe on purpose — the lens document records that as the single property
that predicted whether an audit in this lane still reproduced.

**Swept against** · §6 — `41402f60e`, read as a revision, which is what `--rev` is for. One file was
dirty in the working tree while this was written and has since landed as `e8cf9a538`;
F7 is about what that concurrent session was doing to it. Thirteen sessions run against this checkout; a number here
without this SHA is a number about a tree that has moved.

**Lens** · §7 — **Lens 7 (load)** throughout, and **Lens 2 (wiring)** on F1 and F2, where the
question is not *does this comment exist* but *does anything read it*. Deliberately **not** applied:
Lens 1 (existence is not in doubt), Lens 3, Lens 4, Lens 5, Lens 6. In particular this audit does
**not** claim any comment it names is false — only that it is generated filler, or narration of a
past event rather than statement of a present constraint. Whether a war story is *true* is a
different question from whether it belongs in the file, and only the second one is asked here.

**Findings** · §8

---

## F1 · 155 files open with a generated header that states no fact, and 141 of them say the file "handles logic and rendering"

Severity: **high** by volume, trivial by difficulty. **1,631 lines** across 155 files — 4.6% of the
whole front end — in a block of this exact shape:

```js
/**
 * Header: Button.jsx
 * Purpose: Button component or utility.
 * Description: Handles logic and rendering for Button component or utility.
 *
 * Version: 26.07.05.1
 * Change Log:
 * - 2026-07-05: Initial annotation and documentation added.
 */
```

Every field is derived from the filename. `Purpose` restates it, `Description` restates `Purpose`,
`Version` is a date in another notation, and `Change Log` records that the block itself was added.
**130 of the 155 are that nine-line block verbatim with only the name changed**, and only 14 carry
any content at all.

It carries **173 dated `- YYYY-MM-DD:` entries**, which CLAUDE.md §7 forbids in as many words —
*"Do not write dated changelog entries into source files. That is what git is for."*

**Nothing reads any of it.** Grepped across `.apk.scripts/`: no tool parses `Header:`, `Purpose:`,
`Version:` or `Change Log:` in this tree. `audit_softapps_headers.py` counts *"a ≥5-line block
comment"* as contract-header coverage, so a block like the one above **scores as a contract header**
— but that script walks `APK:Softapps/`, not here, so the front end is neither counted nor inflated.
That is the Lens-2 half of this finding: 1,631 lines with no reader.

**The class is already known, and the existing detector cannot see this tree.**
`baremetal_module_facts.py:51` carries `TAUTOLOGY = Purpose:\s*\S+\s+implementation\.`, and
`write_baremetal_plans.py` already orders the fix in the right words — *"ask what constraint the file
actually carries; write that as one undated present-tense line, or write nothing. The dated Change
Log lines go — git has them."* The front end spells the same template `component or utility` instead
of `implementation.`, so that regex catches **12 of the 238 files here**, all of them CSS. The other
143 are invisible to it.

**Deleting the block is not free everywhere.** 110 of the 155 files carry a real second docblock
underneath, so the filler simply goes; **45 do not**, and stripping those leaves the file with no
header at all — which is a different breach of CLAUDE.md §7, not a fix. `--sites C1` tags every
span `has-header` or `NO-HEADER-UNDER`.

The eight largest, which are the ones that carry real content mixed into the block and must be read
rather than deleted:

| lines | file:span |
|---:|---|
| 79 | `libControl/buttons/lit-words.js:1-79` |
| 45 | `libControl/text/OcaTable/OcaTable.jsx:1-45` |
| 33 | `libControl/graphing/_dsp/jfir.js:1-33` |
| 23 | `libControl/buttons/lit-bench.js:1-23` |
| 23 | `libControl/buttons/lit-words.test.js:1-23` |
| 21 | `libControl/graphing/DynamicGraph/DynamicGraph.jsx:1-21` |
| 18 | `libControl/graphing/Reverb/Reverb.jsx:1-18` |
| 16 | `libControl/graphing/_dsp/dsp.js:1-16` |

The remaining 147 spans are printed by `--sites C1`, each tagged `filler` or `content` and
`has-header` or `NO-HEADER-UNDER`.

## F2 · 124 more generated lines under the header, in four spellings

Severity: **high** by triviality — there is nothing to weigh, these say the filename back.

| kind | count | the line |
|---|---:|---|
| C2a | 72 | `// Inline comment: Logic for OcaButton` |
| C2c | 20 | `// Author: Gemini (Collaborator)` |
| C2d | 20 | a bare rule — `// ----------------` with no heading under it |
| C2b | 12 | `// HighVisButton Component` |

`// Inline comment: Logic for X` sits directly above `const X = (...) => {`. It is the purest form of
the defect: a comment whose entire content is the identifier on the next line.

**The `Author:` line comes with a second version stamp that disagrees with the first.**
`ButtonToggle.jsx` opens with `Version: 26.07.05.1` in the generated block and then
`// Version: 20260507.1000.1` nine lines later. Twenty files carry both. Neither is read by anything;
authorship and version are git's, and two of them in one file is worse than none.

`--sites C2` prints all 124 with line numbers.

## F3 · Sixteen comment blocks, 316 lines, narrate a past incident instead of stating a present constraint

Severity: **medium**, and this is the class that needs a person rather than a script. The detector
scores a contiguous comment block on past-tense incident markers (*"used to"*, *"without this"*,
*"the bug"*, *"no longer"*, *"went dark"*). **A block it names is a candidate for a read, never a
deletion a tool should make** — several of these blocks contain a real constraint welded to the
story of the day it was learned, and the constraint has to survive.

| lines | file:line | markers |
|---:|---|---:|
| 79 | `libControl/buttons/lit-words.js:1` | 4 |
| 30 | `frameLayout/widgetDispatch.js:21` | 3 |
| 29 | `libControl/buttons/ButtonToggler/ButtonToggler.jsx:97` | 3 |
| 27 | `libControl/buttons/ButtonToggle/ButtonToggle.jsx:28` | 4 |
| 16 | `comMQTT/connectionPool.js:63` | 3 |
| 15 | `libControl/special/SweepStatus/SweepStatus.jsx:1` | 2 |
| 13 | `libControl/buttons/WinkButton/WinkButton.jsx:13` | 4 |
| 12 | `comMQTT/MqttProvider.jsx:71` | 4 |
| 11 | `libControl/special/LinkGang/LinkGang.jsx:76` | 4 |
| 11 | `libControl/text/OcaTable/OcaTable.jsx:163` | 4 |

**`lit-words.js` is the specimen.** 104 lines, of which **81 open with a comment marker — 78% of the file**, and 85 sit
inside a comment once block continuations are counted — over a payload of two six-word arrays and a nine-line lookup. Its header runs under the section titles
`WHY THIS FILE EXISTS`, `WHY IT IS SERVED FROM THE ENGINE, AND REACHED AS ../FrontEnd/...` and
`IF THIS FILE IS MISSING`. Two things are wrong with it beyond length:

- **19 of those lines explain a decision made in a different file.** The `../FrontEnd/…` load-path
  argument (lines 50–68) is about a `<script src>` that lives in
  `APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/index.html:48`. `lit-words.js` contains no URL. A
  constraint documented where it is not enforced is a constraint the next edit will not see.
- **The one line that must not be lost is buried at line 29.** *"Giving that family this list would
  be a regression, not a cleanup: on the shipped `Off·On·Send` toggler a payload of `Send` would
  resolve as On."* That is a live hazard about a live file. Everything above and below it is the
  story of the day two lists were merged.

**`ButtonToggle.jsx:28` is the same shape at 27 lines**: three sentences of contract (*a payload is
not a JavaScript truth value; an unrecognised string is truthy on purpose because this button also
carries filenames; the list lives in `lit-words.js`*) wrapped in a paragraph about the Heartbeat
panel coming up with MILLI, CENTI and DRUMS lit while the bench was doing none of it.

**Not every block here should shrink.** `widgetDispatch.js:21` is 30 lines and most of them are
load-bearing: they say that `exact` matches are order-free and `any` matches are walked top to
bottom, that `dual` above `fader` is *why* `_CustomDualVerticalFader` renders as a DualFader, and
that `check_fieldcomponent_cascade.mjs` holds it. That is present-tense law with a gate named. What
should go from it is the opening paragraph about the 40 sequential `if` branches it replaced.

**The rule this audit proposes, in one line:** *keep the constraint, drop the day it was learned.*
Present tense, no "used to", no "without this it broke" — and if the reason genuinely needs the
counterexample, one clause, not a paragraph.

## F4 · Three front-end files over 600 lines are outside the ratchet that watches the other three — and the biggest unwatched one is bigger than two of the watched

Severity: **high**. `check_line_counts.py` is the institutionalised form of the deleted god-function
audit; Lens 7 names it as the model outcome. It watches three files here:

| lines | file | watched? |
|---:|---|---|
| 1048 | `comMQTT/MqttProvider.jsx` | ✅ |
| **883** | **`libControl/graphing/Equalization/Equalization.jsx`** | ❌ |
| **840** | **`libControl/text/OcaTable/OcaTable.jsx`** | ❌ |
| 831 | `tabManager/WindowManager.jsx` | ✅ |
| 817 | `frameLayout/FieldComponent.jsx` | ✅ |
| **643** | **`libControl/graphing/DynamicGraph/DynamicGraph.jsx`** | ❌ |

`Equalization.jsx` at 883 lines is larger than both watched files below it and can grow without
limit. The baseline's own `_scope` note says `files` is *"a watch list on seven named god functions,
NOT a budget on the folders they sit in"* — so this is not a hole in the design, it is a list that
was seeded from a 2026-08 audit of a different tree and never extended when the front end grew its
own. `LTPFader.jsx` at 597 is four lines under the bar and belongs in the same conversation.

## F5 · 57 of the 66 oversized functions ARE their file, so the ratchet can never be lowered without extraction

Severity: **medium**, and it is the reason F4's fix is not sufficient on its own. 66 functions run
120 lines or more; 16 run 300 or more. For **57 of the 66, the function occupies ≥70% of the file it
is in** — there is nothing else in the file to move out from under it.

| lines | % of its file | function |
|---:|---:|---|
| 788 | 96% | `frameLayout/FieldComponent.jsx:30` · `FieldComponent` |
| 722 | 86% | `libControl/text/OcaTable/OcaTable.jsx:52` · `OcaTable` |
| 648 | 73% | `libControl/graphing/Equalization/Equalization.jsx:233` · `Equalization` |
| 595 | 93% | `libControl/graphing/DynamicGraph/DynamicGraph.jsx:43` · `DynamicGraph` |
| 555 | 93% | `libControl/faders/LTPFader/LTPFader.jsx:41` · `LTPFader` |
| 441 | 90% | `libControl/graphing/Reverb/Reverb.jsx:46` · `Reverb` |
| 426 | 96% | `libControl/faders/GCA/GCA.jsx:19` · `GCA` |
| 420 | 98% | `Thin/src/components/views/CsvToJsonView.tsx:10` · `CsvToJsonView` |
| 383 | 94% | `libControl/special/CMDP/CMDP.jsx:22` · `CMDP` |
| 377 | — | `comMQTT/MqttProvider.jsx:666` · `useMqttState` |
| 361 | — | `tabManager/WindowManager.jsx:470` · `WindowManager` |
| 360 | 91% | `libControl/planning/OcaGantt/OcaGantt.jsx:35` · `OcaGantt` |
| 352 | 95% | `libControl/buttons/ButtonToggler/ButtonToggler.jsx:18` · `ButtonToggler` |
| 351 | — | `comMQTT/MqttProvider.jsx:251` · `MqttProvider` |

`FieldComponent` is the extreme: **788 of 817 lines are one arrow function**, and it opens by
shaping a node through seven bindings named `_d`, `_v`, `_numU`, `_lab`, `_labIsPair`, `_as` and
`_is` (`FieldComponent.jsx:34-71`). Those are the genuinely unreadable names in this tree; the
one- and two-letter bindings elsewhere are overwhelmingly geometry and DSP maths (`w0`, `alpha`,
`cos_w`, `M0`/`P1`), where the short name **is** the notation and renaming them would make the code
harder to check against the filter algebra it implements. The distinction matters: this finding is
about `_lab` and `_is`, not about `w0`.

`MqttProvider.jsx` and `WindowManager.jsx` are the two files where the ratchet can be lowered
without touching a god function — both hold several large functions rather than one, so a genuine
extraction exists.

## F6 · There is no commented-out code, and that is worth recording so nobody looks again

Severity: **informational**. A detector for comment lines that parse as code returned 36 candidates
across 16 files; all 36 were read, and every one is prose, an ASCII topic diagram, or an example
payload deliberately shown inside a contract header (`dsp.js:124-126`, `LinkGang.jsx:25-27`,
`jfir.js:61-65`). **Zero commented-out code.** CLAUDE.md §7's third rule — *"Do not leave
commented-out code"* — is already met in this tree, and that is a lane not worth re-walking.

## F7 · The population is live, and a concurrent session fixed one of these files while this was being written

Severity: **informational**, and it is the reason §6 pins a revision. At `41402f60e`,
`libControl/special/StatusLight/StatusLight.jsx` opens with the nine-line filler block and
`// Inline comment: Logic for StatusLight`. It landed as `e8cf9a538` while this audit was being
written, and now opens with a real contract header — *OWNS* drawing "is that thing there" for a single value, *MUST NOT* invent a fifth
vocabulary, and the gate that holds it (`check.sh statewords`) — with the filler and the noise line
gone.

That is exactly step 3 of the plan below, done by hand on one file. It is good news twice over: the
fix is understood here, and the 155 is a shrinking number rather than a static one. It is also the
warning: any count in this document re-run against the working tree will disagree with it, and the
disagreement is progress rather than error.

---

**Plan** · §9 — **re-carved 2026-09-10.** `PLAN-358.01/.02/.03` were closed `DONE-` and swept.
Re-measurement that day found F1 and F2 nearly finished — **155 files → 7** — and F4 **regressed**:
`linecount.baseline.json` was deleted with the `.apk.scripts/` tree and `OcaTable.jsx` has since grown
840 → 1,240 lines with nothing watching.

- [ ] **0. Restore or formally retire the verification toolchain.**
      PLAN-3301.01
      — `check.sh` names 218 scripts and 215 are absent, `audit_frontend_comments.py` among them.
      Every §10 command below is currently unrunnable for that reason.
- [ ] **1. Re-seed the line-count ratchet, at today's numbers.**
      PLAN-3303.05
      — all seven files, seeded where the tree actually is, **before** any comment deletion lands, so
      the removed lines cannot be spent as headroom. This is now the urgent box, not F1.
- [ ] **2. Finish F1 and F2 — the remnant.**
      PLAN-3303.02
      — 7 files still open with the generated block, 5 still carry `// Inline comment:`, 2 still carry
      `// Author: Gemini`. Includes teaching `baremetal_module_facts.py:51` the front end's spelling,
      which is the step that stops the remnant regrowing.
- [ ] **3. Read the sixteen F3 blocks and rewrite each as the constraint without the incident.**
      PLAN-3303.03
      — starting with `lit-words.js`. **Not automatable**; the detector's output is a reading list.
- [ ] **4. Extract the god components of F5.**
      PLAN-3303.04
      — 57 of 66 oversized functions *are* their file, so the ratchet can be held but never lowered
      until this happens. `MqttProvider.jsx` and `WindowManager.jsx` first: they are the two where a
      genuine extraction already exists.
- [x] **Ship the census as a script rather than a shell block** — done, this audit,
      `.apk.scripts/audit_frontend_comments.py`. *(Deleted with the tree in `05e22b605`; PLAN-3301.01
      is how it comes back.)*

---

**Reproduce** · §10

```bash
git checkout 41402f60e

# F1 — 155 files, 1631 lines, 173 dated entries, 141 filler, 45 with no header underneath
# F2 — 124 sites in four spellings
# F3 — 16 blocks, 316 lines
# F4 — 3 watched, 3 not
# F5 — 66 functions >= 120 lines, 16 >= 300
python3 ".apk.scripts/audit_frontend_comments.py" --rev 41402f60e

# F1 — every span, tagged filler|content and has-header|NO-HEADER-UNDER
python3 ".apk.scripts/audit_frontend_comments.py" --sites C1

# F7 — the filler block this audit measured, and what replaced it in e8cf9a538
git show 41402f60e:"APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/special/StatusLight/StatusLight.jsx" | head -12
git show e8cf9a538:"APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/special/StatusLight/StatusLight.jsx" | head -14

# F1 — the existing BareMetal detector catches 12 of the 238, all CSS
python3 - <<'PY'
import re, subprocess
TAUT = re.compile(r"Purpose:\s*\S+\s+implementation\.", re.I)   # baremetal_module_facts.py:51
out = subprocess.run(["git","ls-files","-z",
    "APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd"],
    capture_output=True, text=True).stdout.split("\0")
src = [p for p in out if re.search(r"\.(js|mjs|jsx|ts|tsx|html|css)$", p)
       and not re.search(r"/(vendor|node_modules|\.next|dist|public)/", p)]
print(sum(1 for p in src if TAUT.search(open(p, errors="replace").read(6000))), "of", len(src))
PY

# F3 — 81/104 lines open with a comment marker, and it names a URL it does not contain
awk 'BEGIN{c=0} /^[[:space:]]*(\/\/|\/\*|\*)/{c++} END{print c"/"NR}' \
  "APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/libControl/buttons/lit-words.js"
grep -c 'src="\.\./FrontEnd/libControl/buttons/lit-words' \
  "APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/index.html"

# F4 — which of the six are in the ratchet
python3 -c "import json;print(sorted(json.load(open('.apk.scripts/linecount.baseline.json'))['files']))"

# F6 — 36 candidates, all of them prose inside a deliberate comment
python3 ".apk.scripts/audit_frontend_comments.py" --json | python3 -c "import json,sys;json.load(sys.stdin)"
```
