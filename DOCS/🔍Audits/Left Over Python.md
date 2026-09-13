---
subject:
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:Softapps/PythonAudioConsoleElements
  - APK:Documentation/230_📐📡🤝 Standards and Protocols/Protocols
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:Softapps/like dot audio cleanup
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:Softapps/Download folder cleanup
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:Softapps/GAMES/XandO/archive
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/assets/generate_icons.py
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:FrontEnd/assets/makegif_original.py
  - APK:DOCKERS/PROTOCOL:DEV:AES70/SRC/aes70py
  - APK:DOCKERS/APK:audio:WebPortal/SRC/APK:OS/server.py
  - .apk.scripts/audit_python_census.py
  - .apk.scripts/console.baseline.json
  - .apk.scripts/deploy_excludes.py
---

# 🐍 Left Over Python — 1,483 files, and a quarter of them have nothing behind them

**Date** · §1 — 2026-09-06.

**Lane** · §2 — **all five**, which is the first finding rather than a dodge. Python is not filed
anywhere in NORTH-STAR.md as a thing; it is the material five
different lanes happen to be made of. EVENT holds the Crawler and the Datasheet builders, PLANNING
holds the GANTT server, EXECUTION holds the SPICE engine, the bare-metal supervisors and the bus
agents, PUBLISH holds `server.py` and the deploy, and the verification tooling under
`.apk.scripts/` sits across all of them. **Nothing in the leftover set belongs to a lane at all** —
that is what makes it leftover.

**Subject** · §3 — the `subject:` list above: the four trees this audit rules CUT, the two front-end
scripts, the one vendored library it rules KEEP so a later reader does not delete it by mistake,
the back end it rules KEEP for the same reason, and the three files that carry the evidence.

**Scope** · §4 — every tracked `.py` in the repository: **1,483 files, 169,124 lines**, 7.4% of the
20,098 tracked files. Untracked `.py` is out of scope and there is little of it — two check scripts
in flight this session. Also out of scope but counted so the number is honest: **602 `.pyc` files
and 170 `__pycache__` directories** exist on disk and **none are tracked**; `.gitignore` is already
doing its job there.

The three trees CLAUDE.md §4 names as other people's documents were dropped from the *caller*
corpus but **not** from the population — `WebScraper/scrapes/` turns out to contain 1,151 lines of
this project's own Python, which is F7.

**Method** · §5 — one script, `.apk.scripts/audit_python_census.py`, written for this audit and
committed with it:

```bash
python3 ".apk.scripts/audit_python_census.py" --rev HEAD                  # the six tables
python3 ".apk.scripts/audit_python_census.py" --rev HEAD --orphans        # every callerless file
python3 ".apk.scripts/audit_python_census.py" --component "Softapps/SCAN" # one component in full
python3 ".apk.scripts/audit_python_census.py" --rev HEAD --json           # machine-readable
```

It asks three independent questions of each file and takes the union as "has a caller":

| | question | how |
|---|---|---|
| **IMPORTED** | does another `.py` resolve to this one? | `ast`, matched against package roots — a chain of `__init__.py` walked upward — plus every `"…​.py"` string literal, because `spec_from_file_location` leaves no import statement |
| **INVOKED** | does something that can execute name it? | basename or path in a `.sh`, `.yml`, `Dockerfile`, `package.json`, `.mjs`, `.rs`, `.ts`, `.html` |
| **COLLECTED** | does pytest reach it by convention? | `test_*.py`, `*_test.py`, `conftest.py` — a caller that appears in no file |

**A `.baseline.json` that lists a path is not a caller**, and separating those is the whole
difference between a useful number and a useless one. A first pass that counted any file mentioning
a basename found **41** orphans; `prologue.baseline.json` alone names 366 console-library files it
does not run. Splitting *named* from *invoked* takes the real figure to **298**.

**Swept against** · §6 — `4a9342401`, read as a revision. Thirteen sessions share this checkout and
the count moved three times while this was being written (1,481 → 1,483); `--rev` is why the tables
below can be re-measured rather than believed.

**Lens** · §7 — **Lens 2 (wiring)** throughout: every finding is the question *what runs this?* and
every verdict follows from the answer. **Lens 7 (load)** on F1 and F4, where the cost is carrying
weight. **Lens 5 (provenance)** on F6, which is the one tree that must NOT be cut.

---

## The whole population, in one table

`T1` of the census, with the audit's disposition against each component. Percentages are of the
169,124-line total.

| Component | Files | LOC | No caller | Disposition |
|---|---:|---:|---:|---|
| `.apk.scripts/` | 145 | 50,135 | 12 | **KEEP** |
| `Softapps/PythonAudioConsoleElements` | 682 | 37,140 | 132 | **CUT** |
| `PROTOCOL:DEV:AES70/aes70py` | 442 | 19,912 | 107 | **KEEP — VENDORED** |
| `BareMetal/Simulation:SPICE` | 14 | 10,122 | 1 | KEEP |
| `WebPortal/APK:OS` | 7 | 7,630 | 0 | KEEP |
| `BareMetal/Baremetal:Manager` | 12 | 7,296 | 0 | KEEP |
| `Softapps/Softapp:Crawler` | 44 | 6,604 | 3 | KEEP |
| `Softapps/Documentation Management` | 14 | 4,791 | 5 | KEEP |
| `BareMetal/Protocol-RS232` | 1 | 4,475 | 0 | KEEP |
| `DockTor/manager` | 12 | 3,893 | 1 | KEEP |
| `Softapps/like dot audio cleanup` | 6 | 1,954 | 6 | **CUT** |
| `Softapps/SCAN` | 8 | 1,730 | 3 | KEEP |
| `BareMetal/Monitor Probes` | 2 | 1,466 | 0 | KEEP |
| `Softapps/Beskar2d2.com` | 6 | 1,437 | 1 | KEEP |
| `WebPortal/(root)` — the launchers | 3 | 1,101 | 0 | KEEP |
| `999_📌🕰📝 Changelogs/changelog.py` | 1 | 1,042 | 0 | KEEP |
| `BareMetal/Core` — `oaFileImportCSV` | 33 | 999 | 1 | KEEP |
| `230_📐📡🤝 Standards and Protocols/Protocols` | 15 | 917 | 14 | **CUT** |
| `BareMetal/Storage:MQTT` | 5 | 836 | 0 | KEEP |
| `Documentation/build_index.py` | 1 | 718 | 0 | KEEP |
| `Server:Discovery:NMOS` | 4 | 661 | 2 | KEEP |
| `BareMetal/test` | 3 | 634 | 0 | KEEP |
| `BareMetal/(root)` | 3 | 566 | 0 | KEEP |
| `Softapps/Download folder cleanup` | 2 | 477 | 0 | **CUT** |
| `.apk.skills/synch.py` | 1 | 440 | 0 | KEEP |
| `003_Manual/build_manual_html.py` | 1 | 323 | 1 | **DECIDE** |
| `Softapps/SAMPLE and PLAY` | 2 | 309 | 1 | **DECIDE** |
| `Softapps/GAMES` | 4 | 285 | 4 | **CUT** |
| `WebPortal/APK:FrontEnd/assets` | 2 | 269 | 2 | **CUT** |
| `BareMetal/Protocol-visa` | 1 | 241 | 1 | KEEP |
| `Softapps/TIME` | 2 | 199 | 0 | KEEP |
| `BareMetal/Protocol-midi` | 1 | 172 | 1 | KEEP |
| `Server:Netbox` | 1 | 126 | 0 | KEEP |
| `Manager:docktor.py` | 1 | 102 | 0 | KEEP |
| `BareMetal/firmware` | 1 | 71 | 0 | KEEP |
| `Softapps/TOUCH/archive` | 1 | 51 | 0 | **DECIDE** |

| Disposition | Files | LOC | Share |
|---|---:|---:|---:|
| **KEEP** — has a runtime, a lane, or both | 326 | 107,487 | 63% |
| **KEEP — VENDORED** — somebody else's source, pinned | 442 | 19,912 | 11% |
| **DECIDE** — one question each, §9 asks them | 4 | 683 | <1% |
| **CUT** — nothing runs it and nothing would notice | 711 | 41,042 | **24%** |

---

**Findings** · §8

## F1 · The console library is 682 files that cannot import a sixth of themselves, and the only thing that reads it is the lane measuring how broken it is

`APK:DOCKERS/APK:audio:WebPortal/SRC/APK:Softapps/PythonAudioConsoleElements/` is **682 Python files,
37,140 lines, 819 tracked files, 3.96 MB** — 22% of all the Python in this repository and the second
largest component after the verification tooling itself.

**Six packages it imports are not in this repository, in 143 files:**

| import | files | present? |
|---|---:|---|
| `oaLogging` | 108 | no |
| `oaGui` | 63 | no |
| `oaConfigurationManager` | 62 | no |
| `oaRustCore` | 19 | no — the name appears only in `APK:BareMetal/Core/pyproject.toml`, a different project |
| `oaStyle` | 18 | no |
| `oaComProtocols` | 15 | no |
| `oaComBroker` | 10 | no |

It runs at all only because `mock_init.py` installs a `MetaPathFinder` that answers every one of
them with a `MagicMock`. That is a deliberate, well-commented piece of work — and what it is
holding up is a snapshot of an application whose other half lives somewhere else.

**Seven directories declare a Rust extension that was never vendored either.** `oaNeedleEngine_rs`,
`oaCMDPMath_rs`, `oaRotaryCore_rs`, `oaPatternEngine_rs`, `oaProceduralArt_rs`,
`oaNeedleGeometry_rs`, `oaMeteringEngine_rs`, `oaEditorState_rs`, `oaHitboxMath_rs` — each is a
`pyproject.toml` and **nothing else**. `git ls-files` finds **0** `Cargo.toml` and **0** `.rs` files
under the whole tree.

**Nothing in this repository imports it and nothing publishes it.** `check_published_refs.py`'s
published set does not contain it; `deploy_excludes.py` puts `.py` in `IGNORED_SUFFIXES`, so no
Python ships to the web root at all. The single consumer is `check.sh console`, and what that lane
reports today is:

```
102 collected, 49 passed, 50 failed, 3 skipped, 0 collection error(s)  (floors: 102 collected, 49 passed)
```

**Half of a 682-file library fails its own tests, and the lane is green** — correctly so, because
`console.baseline.json` says in its own note that failures are tolerated *"eight sibling packages
are not in this repository and the tree is a read-only snapshot"*. The lane was built (PLAN-119.03
step 4) to catch collection errors, and it does. It was never a claim that the library works.

The cost is not the disk. It is that **366 of the 486 lines of `prologue.baseline.json` are console
library paths**, that `check.sh console` is one of the slower lanes on the board, and that a reader
scanning `APK:Softapps/` sees the largest folder in it and reasonably assumes it is the product.

## F2 · Fifteen protocol testers in the documentation hub have no caller, carry a generated header that states no fact, and document a path that has not existed since the flatten

`APK:Documentation/230_📐📡🤝 Standards and Protocols/Protocols/` holds fifteen `*_tester.py` files —
**917 lines** — one per protocol: `aes70`, `dnssd`, `ember`, `mdns`, `midi`, `mqtt`, `osc` (two),
`ptp`, `rest`, `sap`, `smpte2138`, `snmp`, `websocket`, plus `_proto_util.py`.

**Fourteen of the fifteen have no importer, no runner, and no pytest name.** The exception is
`_proto_util.py`, which the other fourteen import and which is itself named only by a generated
HTML page. `check.sh` names the *directory* once — for the `nmos-rig` lane's `testSchema.md`, a
Markdown document in the `nmos/` sibling folder that holds no Python at all.

**Every one of them used to tell you to run it from a path that was deleted** — repaired in
`21a4edbe8`, and this is what the finding looked like:

```python
"""Real MQTT tester: subscribe to the broker and print messages (the bus itself).
    python3 Validations/Protocols/mqtt/mqtt_tester.py [--topic '#'] [--timeout S]
"""
```

`Validations/` has not existed since the documentation migration. All fifteen files now open by
binding `P` to the directory they are in and interpolating it, so the USAGE line resolves from the
checkout root and cannot rot the same way again. PLAN-910.04.

**They duplicate live tools that do have callers.** `midi_tester.py` is a second, different copy of
`APK:BareMetal/Protocol/Protocol-midi/Test/midi_tester.py` (different sha, same job, and the bare-metal one
is named by `check.sh`). `aes70_tester.py` is 28 lines against `PROTOCOL:DEV:AES70/aes70_probe.py`'s
259, which is in the AES70-Dev Dockerfile. `mqtt_tester.py` is 49 lines against
`Storage:MQTT/mqtt_agent.py` and `Baremetal:Manager/mqtt_broker_discovery.py`, both wired.

There is also the filing question, which is the reason this one is easy: **executable protocol
probes are not documents.** CLAUDE.md §3 says every document goes in a lane of the hub; it does not
say the hub is where code lives. These are the only `.py` under `230_📐📡🤝 Standards and Protocols/`.

## F3 · All seventeen contentless Python headers in the repository are exactly the leftover set

`T5` of the census greps for the generator's signature — `Purpose: <file>.py implementation.`
followed by `Description: Logic and implementation for <file>.py implementation.` — the header class
that the front-end comment audit
named C1 and measured at 155 sites in `.jsx`.

Across **1,483 Python files there are exactly 17**, and they are:

- the **15** protocol testers of F2, and
- the **2** front-end asset scripts of F5.

Not one live component carries one. This is not a coincidence to be admired — it is a
**usable signal**: the generated header marks the files nobody has opened since the annotation
sweep of 2026-07-05, and in Python that set and the leftover set are the same set.

## F4 · Two personal-tooling folders under `APK:Softapps/` are not applications, the repository already says so in a baseline, and one of them is why a key had to be rotated

`softapps_declared.baseline.json` lists three folders under `APK:Softapps/` that declare no
`display.json`, and its own note states the remedy:

> *"Lower it by declaring one — or, if the folder is not an application, by saying so here and
> **removing it from `APK:Softapps/`**."*

Two of the three are Python and neither is an application:

| Folder | Python | LOC | What it is |
|---|---:|---:|---|
| `like dot audio cleanup/` | 6 | 1,954 | WordPress media tooling for a **different website** — `wp_media.py`, `wp_regen_thumbs.py`, `wp_validate_thumbs.py`, `generate_gallery.py`, plus `check_mail.py` and `check_sftp.py` |
| `Download folder cleanup/` | 2 | 477 | a personal `~/Downloads` sorter, with its own unit test |

All six files in the first have **no caller of any kind**. Three of them hold entries in
`secrets.baseline.json`. And `check.sh`'s own comment above `run_secrets()` records what this folder
already cost:

> *"A plaintext SSH passphrase sat in `like dot audio cleanup/check_{mail,sftp}.py` from 2026-08-26
> until 2026-08-29, found by OPENING THE FOLDER — nothing in 54 lanes looked. It was in git history,
> so deleting the line did not un-publish it and the key had to be rotated."*

BLOCKED-PLAN-244.01
is that incident, still blocked on an owner-only rotation, and it records the exposure window as
**410 commits, pushed to `origin/main`**. **Deleting the folder does not close that plan** — the
literal is in history and only a rotation or a rewrite removes it — but it does remove the two files
that will otherwise be edited again by somebody who does not know.

`GAMES/XandO/archive/` is the third of this shape and the smallest: three files, 240 lines, under a
directory literally named `archive/`, with no caller and no doc mention. `dupetrees.baseline.json`
is the only thing that names it.

## F5 · The two Python files in the front end do nothing, could not ship if they did, and the documentation that describes them is describing a file that was deleted

`APK:FrontEnd/` contains exactly two `.py` files, **269 lines**:

| File | LOC | State |
|---|---:|---|
| `assets/generate_icons.py` | 120 | no caller; needs Pillow, which no `requirements.txt` declares |
| `assets/makegif_original.py` | 149 | no caller; needs matplotlib, which nothing declares |

Both carry the F3 generated header. Neither is imported, invoked or collected. Only
`prologue.baseline.json` names them.

**They could not ship in any case.** `deploy_excludes.py` states the rule in its own contract —
*"`IGNORED_SUFFIXES` — the Python back end does not ship"* — and `.py` is in that tuple. The
published surface is the shell, the widget engine and three apps; no Python crosses the wire.

**The documentation that appears to cover `generate_icons.py` covers a different file.**
`002_🏛⚖📜 Philosophy/Styles/readme.Styles.md` cites it nine times and gives runnable commands:

```
python3 "APK:Softapps/oneScope/Documentation/1_Philosophy/Styles/generate_icons.py" --check
```

`APK:Softapps/oneScope/` was removed. The `--check` flag it documents does not exist in the
front-end file — that file is a one-shot favicon/PWA generator with no flags at all. So the 269
lines are unreferenced and the 9 references are unresolvable, in opposite directions.

## F6 · The single largest block of callerless Python must not be touched, and the thing that says so is one JSON file

`PROTOCOL:DEV:AES70/aes70py/` is **442 files, 19,912 lines**, of which **107 files / 8,904 lines have
no caller** — the biggest orphan block in the census after the console library.

**It is not ours.** It is a verbatim copy of `github.com/AES70py/aes70py`, MIT, pinned in
`upstream.json` at commit `b01eee812bc4a56d83959bef98c5d9650de4a232`, extracted 2026-09-06 — today.
The Dockerfile installs it; `aes70_probe.py` and the AES70-Dev compose service are its callers; its
own `examples/` and `tests/` are supposed to be callerless, because that is what a vendored library
looks like from the outside.

This is recorded as a finding because **the metric that finds leftovers points straight at it**, and
the only thing standing between a future sweep and 20,000 lines of somebody else's source is
`upstream.json` — one file, in one directory, that a caller-count tool has no reason to read. Any
tool built on §5's method must exempt a directory carrying an `upstream.json` or a vendored
`LICENSE`, by rule and not by memory.

## F7 · 1,151 lines of this project's own Python are filed inside the third-party scrape corpus, where §4 of CLAUDE.md tells every agent not to look

```
APK:Softapps/Documentation Management/WebScraper/scrapes/microphones/Datamodel/extract.py      872 L
APK:Softapps/Documentation Management/WebScraper/scrapes/microphones/Datamodel/audit_pages.py  279 L
```

`scrapes/` is 8,945 files of other people's marketing pages, de-ranked in the root `.ignore`
precisely so that searches stop finding them. Two files of our own extraction code are inside it.
Both have no caller and no doc mention; `rg` will not surface either without `--no-ignore`.

This is a **filing** finding, not a deletion one: `extract.py` is the reader behind the microphone
datamodel and `build_data.py` is its live sibling one directory up. It belongs beside the code that
uses it, not inside the corpus it reads.

## F8 · The remaining callerless files are eleven singletons, and most of them are legitimately callerless

The census's 298 callerless files are, after F1's 132, F6's 107 and F2's 14, **45 files** — and the
audit rules the majority of those KEEP. The distinction that matters:

**Legitimately callerless — an operator command is run by a person, not by a lane.** `.apk.scripts/`
has twelve, and nine of them are measurement tools that back a specific audit and say so in their own
header: `audit_frontend_comments.py`, `audit_softapps_census.py`, `census_timestamps.py`,
`census_widget_declarations.py`, `probe_kay_voice.py` (needs a real Chrome and Google's servers),
`fetch_ieee_oui.py` (needs the internet), `rename_identifiers.py` and `rename_tokens.py` (re-runnable
refactor tools, deliberately idempotent), `pull.py`. These are the provenance of numbers other
documents quote. Deleting them makes those documents unfalsifiable.

**`check.sh` already governs its own half of this and finds two.**
`check_unwired_checks.py` holds *"108 check scripts, 101 reached by a lane, 5 exempt"* and reports
`check_simulation_freshness.py` and `check_skill_cd_targets.py` UNWIRED — both untracked, both in
flight this session. **The gap that ratchet does not cover is the `audit_*`, `census_*`, `build_*`
and `probe_*` half**, which is why the nine above are invisible to it. That is a real hole and §9
proposes closing it with an exemption block rather than a lane.

**Actually leftover — the eleven singletons.** No header explaining why they are callerless, no
audit behind them, no lane:

| File | LOC | Verdict |
|---|---:|---|
| `.apk.scripts/mkdir_ftp.py` | 48 | CUT — no contract header at all (violates §7), and the `ftp-make-folder` skill is its replacement |
| `Softapps/Beskar2d2.com/Folders/sort_cad_files.py` | 421 | DECIDE — one-shot sorter, no header, siblings under `Cad Drawings/` are all live |
| `Softapps/SCAN/Documentation/Fixes/patch_stats.py` | 359 | DECIDE — a "Fixes" folder inside a Documentation folder |
| `003_Manual/build_manual_html.py` | 323 | KEEP + WIRE — it generates the manual lane's 852 HTML pages and **no lane proves the output is fresh** |
| `DockTor/manager/cli.py` | 232 | KEEP — the terminal half of a live package; reached as `python3 -m manager.cli`, which the method cannot see |
| `Simulation:SPICE/examples/av_matrix.py` | 164 | KEEP — an example, and examples are callerless by definition |
| `Softapps/SAMPLE and PLAY/ICON and LOGO/generate_assets.py` | 60 | DECIDE — same shape as F5's two |
| `Softapps/SCAN/Database/Test.py` | 61 | CUT — 61 lines, no header, no doc, capital-T `Test.py` collects under no convention |
| `Softapps/TOUCH/archive/start.py` | 51 | DECIDE — under `archive/` |
| `Softapps/SCAN/Documentation/Fixes/fix_voice.py` | 37 | CUT — one-shot patch script |
| `Softapps/SCAN/describe_db.py` | 21 | CUT — 21 lines, no header, no doc |

---

**Plan** · §9 — **re-carved 2026-09-10.** The original `PLAN-652.01` was closed `DONE-` and swept,
but re-measurement on disk that day found **every CUT target still present**, so the work is carried
now by five plans, ordered so each is provable before the next:

- [ ] **0. Restore or formally retire the verification toolchain.**
      PLAN-3301.01
      — `check.sh` names 218 scripts and **215 are absent**; `audit_python_census.py`, which produced
      every number in this audit, is one of them. Nothing below can be measured or held until this is
      answered.
- [ ] **1. Wire the ratchet before cutting anything.**
      PLAN-3302.01
      — extend `check_unwired_checks.py` past `check_*.py` to `audit_`, `census_`, `build_`, `probe_`,
      and add the vendored-tree rule F6 demands. **A cut made before this exists is a cut nothing can hold.**
- [ ] **2. Cut what nothing names**, and move F7's two files out of the scrape corpus.
      PLAN-3302.02
      — ~630 lines, one baseline re-seed, no lane touched. `mkdir_ftp.py` is already gone, with the
      whole `.apk.scripts/` tree rather than by this ruling.
- [ ] **3. Retire the fifteen protocol testers.**
      PLAN-3302.03
      — 917 lines out of the documentation hub, and the hub stops holding executables.
- [ ] **4. Move the two personal folders out of `APK:Softapps/`.**
      PLAN-3302.04
      — 2,431 lines, and re-seed `softapps_declared.baseline.json` to `["QcadSchematics"]`. This does
      **not** close BLOCKED-PLAN-244.01.
- [ ] **5. Decide the console library.**
      BLOCKED-PLAN-3302.05
      — 37,140 lines, 22% of all Python here. Blocked on the owner; three options costed in the plan.
      **The audit does not pick.** The four boxes above deliberately do not wait on it.

In summary, the five boxes as originally written:

1. **Wire the ratchet before cutting anything.** Extend `check_unwired_checks.py` past `check_*.py`
   to `audit_*`, `census_*`, `build_*`, `probe_*`, with the same exemption block that already carries
   five reasons — and add the vendored-tree rule F6 demands. **A cut made before this exists is a cut
   nothing can hold.**
2. **Cut what nothing names** — the front end's two, `XandO/archive/`, `mkdir_ftp.py`, and F8's four
   CUT singletons. ~1,000 lines, one baseline re-seed (`prologue`), no lane touched.
3. **Retire the protocol testers.** Delete the fifteen; fold anything the bench does not already have
   into `aes70_probe.py` / `mqtt_agent.py` / `Protocol-midi/Test/midi_tester.py` first. 917 lines out
   of the documentation hub, and the hub stops holding executables.
4. **Move the two personal folders out of `APK:Softapps/`** and re-seed
   `softapps_declared.baseline.json` to `["QcadSchematics"]`, which is what its own note prescribes.
   2,431 lines. Note explicitly in the changelog that this does **not** close BLOCKED-PLAN-244.01.
5. **Decide the console library**, which is the only box that needs the owner and the only one worth
   real money: 37,140 lines, 22% of all Python here. Three options, costed in the plan — keep as a
   read-only snapshot with a `SNAPSHOT.md` stating what it is (cheapest, honest), extract to its own
   repository and vendor it back the way `aes70py` is (correct, ~a day), or delete it. **The audit
   does not pick.** It records that the current state — 50 of 102 tests failing under a green lane,
   six absent packages mocked, nine Rust crates declared and never written — is the one option that
   is not a decision.

F7 (the two files inside `scrapes/`) is a `git mv` into `Documentation Management/Microphones/docs/`
and rides with box 2.

**Reproduce** · §10

```bash
cd "$(git rev-parse --show-toplevel)"
python3 ".apk.scripts/audit_python_census.py" --rev 4a9342401            # T0-T5, every table above
python3 ".apk.scripts/audit_python_census.py" --rev 4a9342401 --orphans  # the 298, largest first
python3 ".apk.scripts/check_console_suite.py"                            # F1's 102/49/50/3
python3 ".apk.scripts/check_unwired_checks.py"                           # F8's 108/101/5
git ls-files "APK:DOCKERS/APK:audio:WebPortal/SRC/APK:Softapps/PythonAudioConsoleElements" \
  | grep -c "Cargo.toml\|\.rs$"                                          # F1's nine empty crates: 0
git ls-files '*.pyc' | wc -l                                             # §4's tracked bytecode: 0
```

The census takes about a minute against a revision — it reads every tracked text file twice, once
for imports and once for callers.
