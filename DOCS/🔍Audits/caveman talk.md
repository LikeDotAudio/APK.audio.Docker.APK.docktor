---
subject: []
---

# 🪨 Caveman Talk — cutting prose out of Claude, notes, and comments

**Date** · §1 — 2026-09-10.

**Subject** · §2 — none. Frame document. This is about tooling config, not repo paths.

**Ask** · §3 — "too much prose across the board. Is there a caveman plugin to make notes and
comments fewer words, lower context, better use of LLM?"

**Answer** · §4 — Yes, two of them, both third-party. Neither is Anthropic-official. Both fix
*chat output only*. Neither touches notes or code comments — those need a `CLAUDE.md` rule.

---

## §5 · What exists

| Thing | What it is | Claimed saving | Install |
|---|---|---|---|
| [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | Skill + optional proxy. Slash commands, intensity levels, stats. MIT (proxy runtime BSL-1.1). | 65% output tokens avg, 22–87% range. Proxy: −33% input. | `npx skills add JuliusBrussee/caveman` |
| [carlosduplar/caveman-output-style](https://github.com/carlosduplar/caveman-output-style-claude-code) | One markdown file. Output style. No runtime, no dependency. | ~40% output tokens. | Copy one file to `~/.claude/output-styles/` |

Numbers are vendor-measured. Not independently verified here.

### Caveman skill commands
`/caveman lite` · `/caveman` · `/caveman full` · `/caveman ultra` · `/caveman wenyan-*` · `/caveman off`
`/caveman-commit` — terse Conventional Commits. `/caveman-review` — one-line findings. `/caveman-stats` — token usage.

---

## §6 · The catch

1. **Chat only.** Caveman changes what Claude says to you. It does not change what Claude *writes
   into files*. Audit docs, `NORTH-STAR.md`, docstrings, JSX comments — untouched.
2. **Grammar damage is a real risk.** "Caveman grammar" drops articles and function words. Those
   words carry syntax. Ultra mode trades clarity for tokens. Unmeasured effect on reasoning quality.
3. **Wrong lever for input cost.** Output tokens are the cheap half. The expensive half is context
   — the repo this session reads. Caveman skill does nothing there; only the proxy touches input.
4. **Third-party skill = code in your session.** The proxy variant is a `npm -g` install that
   intercepts traffic. Review before running on this repo.

---

## §7 · Recommendation

Skip caveman grammar. Take the terseness, leave the pidgin.

**A · Output style — no plugin needed.** One file, no dependency, no third-party code:

```bash
mkdir -p ~/.claude/output-styles
cat > ~/.claude/output-styles/terse.md <<'STYLE'
---
name: Terse
description: Minimum prose. Full technical accuracy.
keep-coding-instructions: true
---
Answer first. No preamble, no summary of what you just did, no offers of next steps.
Drop hedging, pleasantries, and narration of tool calls.
Prefer tables, lists, fragments over paragraphs. One line per fact.
Never restate the question. Never explain a command that is self-evident.
Keep verbatim: code, commands, paths, exact error strings, numbers, URLs.
Correct grammar — do not drop articles or mangle syntax to save tokens.
STYLE
```

Then `/config` → Output Style → Terse. Or persist in `~/.claude/settings.json`:

```json
{ "outputStyle": "terse" }
```

**B · Notes and comments — `CLAUDE.md`.** This repo has none at root. That is the gap. Caveman
cannot fill it; a project rule can:

```bash
cat >> /home/anthony/Documents/GitProjects/APK.audio/CLAUDE.md <<'MD'

## Prose budget

Docs and audits: lead with the finding. Tables over paragraphs. No throat-clearing intro,
no closing summary. Section headers do the work a topic sentence would.
Code comments: only for the non-obvious — why, not what. No comment restating the line below it.
Commit messages: Conventional Commits, one line, body only when the why is not in the diff.
MD
```

**C · If you want caveman anyway.** Take the output-style variant, not the proxy. One file, no
`npm -g`, no traffic interception, and `/config` toggles it off in one step.

---

## §8 · Sources

- <https://github.com/JuliusBrussee/caveman>
- <https://github.com/carlosduplar/caveman-output-style-claude-code>
- <https://www.claudepluginhub.com/plugins/juliusbrussee-caveman>
- <https://aiweekly.co/alerts/caveman-plugin-trims-claude-and-codex-output-to-cut-ai-bills>
