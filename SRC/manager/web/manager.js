// Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
// MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
/* 🧠 The thin half. Ask /api, draw what came back, send a verb when clicked.
 *
 * WHAT THIS FILE OWNS. Rendering, the three cadences, and the dialogues. It
 * spells no port, no container name, no docker verb and no state colour: the
 * verbs arrive from /api/actions with their own labels and their own confirm
 * text, the addresses from /api/endpoints, the colours from /api/palette. A
 * literal of any of those here would be a second copy of a table that already
 * exists in Python, which is the drift the whole package is arranged against.
 */

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/* THERE ARE THREE CADENCES AND THEY DO DIFFERENT WORK. Stated below the first
 * line of code on purpose — `check.sh prologue` measures the comment run a file
 * OPENS with, and a reader does not need the reasoning above the first line to
 * find it. Same placement, and the same reason, as `docker scripts/apps.sh`.
 *
 *   · METERS      /api/resources on 5s while "Live Resources" is armed. Numbers
 *                 into cards that already exist; it never creates one.
 *   · SCAN        /api/containers on the ⏱ interval. The whole grid, so a
 *                 container that appeared between ticks gets a card.
 *   · FOLLOW      /api/containers?apps=0 on 2s, only while an action runs, and
 *                 it overrides both. A grid titled LIVE may not be suspended by
 *                 the one event that invalidates every card on it — the Tk
 *                 window held its pre-action snapshot until the exit code came
 *                 back, and painted green dots over containers the log beside
 *                 it was printing the teardown of.
 *
 * NONE OF THEM ACTS. Every cadence is a GET, and the server refuses a script
 * that changes the bench over GET. An operator who leaves a tab open must be
 * able to leave it open.
 */

const state = {
  palette: null,
  actions: { actions: {}, container_actions: {} },
  selected: null,
  detail: null,
  meters: false,
  density: "high",
  view: "cards",
  // THE LAST SNAPSHOT AND THE LAST STATS SAMPLE, HELD RATHER THAN RE-ASKED
  // FOR. The donut and the port table are second readings of what the cadences
  // already fetched -- a view that re-fetched on every switch would put a
  // third cadence on the box to draw numbers that are on screen already.
  snapshot: null,
  resources: {},
  // WHAT THE BOX IS -- how many cores, how much RAM -- held rather than
  // re-read, because it arrives on whichever of the two cadences happened to
  // answer last and the rings need it on both. 0 means the server has not said
  // yet; see renderDonuts(), which draws a different CPU ring in that case
  // rather than guessing a denominator, and falls back to the widest limit in
  // the stats sample for RAM.
  hostCpus: 0,
  hostMemory: 0,
  endpoints: [],
  scanEvery: 0,
  scanTimer: null,
  scanPhase: null,  // the one-shot that walks the scan onto a pace-clock mark
  meterTimer: null,
  followTimer: null,
  busy: 0,          // a DEPTH of runs in flight, not a flag -- see follow()
  scanning: false,
};

/* --------------------------------------------------------------- transport */

/* WHERE /api IS, WORKED OUT RATHER THAN SPELLED.
 *
 * Every route below is written the way the manager's own server answers it --
 * `/api/containers`, `/api/stream` -- and every one of them is resolved against
 * the directory this page was served from before it is fetched. Served at an
 * origin's root, which is what `serve.py` does on 8765, that resolution changes
 * nothing. Served under a prefix, which is what APK:OS does when it relays the
 * manager at `/manager/` so the shell can frame it, it is the difference
 * between the client working and the client asking the OS for a route the OS
 * has never heard of.
 *
 * THE PREFIX IS NOT CONFIGURED AND MUST NOT BECOME CONFIGURABLE. It is read off
 * `document.baseURI`, so the page is correct wherever it is mounted without
 * anybody remembering to tell it -- and a mount point that has to be declared
 * in two places is a mount point that will one day disagree with itself. */
const ROOT = new URL(".", document.baseURI);
const at = (path) => new URL(String(path).replace(/^\//, ""), ROOT).href;

async function get(path) {
  const response = await fetch(at(path), { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error((await response.json().catch(() => ({}))).error || response.statusText);
  return response.json();
}

async function post(path, body) {
  const response = await fetch(at(path), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  return response.json();
}

/* ------------------------------------------------------------------- tones */
function applyPalette(palette) {
  state.palette = palette;
  const root = document.documentElement.style;
  for (const [name, hex] of Object.entries(palette.tones)) {
    root.setProperty(name === "accent" ? "--accent" : `--tone-${name}`, hex);
  }
}

const appTone = (word) =>
  (state.palette && state.palette.app_state_tones[word]) || "unknown";

const appPulses = (word) =>
  !!(state.palette && state.palette.app_states_pulsing.includes(word));

/* Same rule, second vocabulary: `live`, `retained`, `departed` are topics.sh's
 * words and palette.py owns what each one looks like. */
const busTone = (word) =>
  (state.palette && state.palette.bus_state_tones[word]) || "unknown";

/* ------------------------------------------------------------------ the log
 *
 * A BAR IS ONE LINE REDRAWN, NOT A NEW ONE. `brief.LogBrief` on the server
 * turns a docker build's four thousand lines into a moving bar, and it says so
 * by sending `bar` where it means overwrite and `bardone` where it means
 * overwrite once more and freeze. Holding the element is the whole trick.
 */
const logBox = $("#log");
let liveBar = null;

function logRecord(record) {
  if (record.kind === "clear") { logBox.textContent = ""; liveBar = null; return; }

  const pinned = logBox.scrollTop + logBox.clientHeight >= logBox.scrollHeight - 24;

  if (record.kind === "bar" || record.kind === "bardone") {
    if (!liveBar) {
      liveBar = document.createElement("span");
      // Stamped when the bar STARTS and never restamped, because it is one
      // line being overwritten: a bar that changed colour under a build would
      // be reporting the clock rather than the build.
      liveBar.className = `l q${paceQuarter(record.at)}`;
      logBox.append(liveBar);
    }
    liveBar.textContent = record.text;
    if (record.kind === "bardone") liveBar = null;
  } else {
    liveBar = null;
    const line = document.createElement("span");
    line.className = `l q${paceQuarter(record.at)}${record.tone === "hot" ? " err" : ""}`;
    line.textContent = record.text;
    logBox.append(line);
  }
  // Only when the reader was already at the bottom. Scrolling a log somebody
  // has scrolled UP is taking the thing they were reading away from them.
  if (pinned) logBox.scrollTop = logBox.scrollHeight;
}

function openStream() {
  const source = new EventSource(at("/api/stream"));
  const note = $("#stream-state");
  source.onopen = () => { note.textContent = "live"; };
  source.onmessage = (event) => logRecord(JSON.parse(event.data));
  // EventSource reconnects on its own; saying so is the difference between a
  // quiet bench and a manager nobody noticed had gone deaf.
  source.onerror = () => { note.textContent = "reconnecting…"; };
}

/* --------------------------------------------------------------- pace clock
 *
 * A SWIM PACE CLOCK, AND THE LOG ABOVE READS OFF IT. Four hands fifteen
 * seconds apart on a 60-at-the-top dial; the one at the top is the colour
 * every log line takes as it arrives, so the terminal's own ink says which
 * quarter of the minute each block of output landed in. That is the pool-deck
 * reading of this instrument — nobody on a pool deck reads a time off it, they
 * read which fifteen they are in and whether they are still in it.
 *
 * IT IS SYNCHRONISED TO THE WALL CLOCK, WHICH THE PAGE IT CAME FROM IS NOT.
 * A CSS animation starts when the page loads, so an unsynchronised dial has
 * red at the top at some arbitrary moment and the colour of a log line would
 * then mean nothing outside this one tab. Handing each hand a negative
 * animation-delay of its offset PLUS the seconds already elapsed this minute
 * puts red on the top at :00 in every tab on every screen — and makes the log
 * colour a pure function of the second of the minute, so nothing has to be
 * shared between the dial and the log for the two to agree.
 *
 * NO TIMER. Phase is set once here and once more when the tab comes back to
 * the front (a backgrounded tab may have had its animations throttled). There
 * is no fourth cadence and there must not be one; see the three at the head.
 */
const LANES = [
  // `top` is the second of the minute at which this hand is at 60, which makes
  // it both the hand's phase and the quarter it owns. One table, both jobs.
  { colour: "red",    top:  0 },
  { colour: "yellow", top: 15 },
  { colour: "green",  top: 30 },
  { colour: "blue",   top: 45 },
];

/* THE QUARTER A LINE BELONGS TO IS THE SERVER'S `at`, NOT THE MOMENT THIS TAB
 * DREW IT. Every record on the stream carries the epoch second it was written
 * (LogRing, serve.py), and the ring replays its backlog to every tab that
 * connects — so a colour taken from the browser's clock would paint four
 * hundred lines of history in whatever one colour the tab opened in, and two
 * tabs opened a minute apart would disagree about the same line. Epoch is on a
 * minute boundary, so seconds-into-the-minute is just the remainder. */
const paceQuarter = (at = Date.now() / 1000) => Math.floor((at % 60) / 15);

/* 120 ticks and 12 numerals, drawn rather than typed. Every second gets a
 * mark and every half-second a shorter one, which is the density that makes a
 * hand between two marks readable at a glance instead of countable. */
function buildPaceDial() {
  const svgNS = "http://www.w3.org/2000/svg";
  const ticks = $("#pace-ticks");
  const numbers = $("#pace-numbers");
  if (!ticks || !numbers) return;

  for (let i = 0; i < 120; i++) {
    const major = i % 10 === 0;   // every five seconds, where a numeral is
    const full  = i % 2 === 0;    // a whole second
    const tick = document.createElementNS(svgNS, "line");
    tick.setAttribute("class", major ? "tick major" : "tick");
    tick.setAttribute("y1", "-235");
    tick.setAttribute("y2", major ? "-205" : full ? "-220" : "-228");
    tick.setAttribute("stroke-width", major ? "5" : full ? "2" : "1");
    tick.setAttribute("transform", `rotate(${i * 3})`);
    ticks.append(tick);
  }

  for (let n = 5; n <= 60; n += 5) {
    // -90° so that 60 lands at the top rather than at three o'clock.
    const angle = (n * 6 - 90) * (Math.PI / 180);
    const label = document.createElementNS(svgNS, "text");
    label.setAttribute("class", "num");
    label.setAttribute("x", String(250 + 165 * Math.cos(angle)));
    label.setAttribute("y", String(250 + 165 * Math.sin(angle)));
    label.setAttribute("text-anchor", "middle");
    label.setAttribute("dominant-baseline", "central");
    label.textContent = String(n);
    numbers.append(label);
  }
}

function syncPaceClock() {
  const now = new Date();
  const intoMinute = now.getSeconds() + now.getMilliseconds() / 1000;
  for (const lane of LANES) {
    const hand = $(`.pace .sweep.${lane.colour}`);
    // (60 - top) % 60 is how far round the dial this hand already is when the
    // minute turns over — the offset the hand needs to reach 60 at `top`.
    if (hand) hand.style.animationDelay = `-${((60 - lane.top) % 60) + intoMinute}s`;
  }
  const minute = $("#pace-minute-hand");
  if (minute) minute.style.animationDelay = `-${now.getMinutes() * 60 + intoMinute}s`;
}

/* ------------------------------------------------------------------ dialogs */
function ask(title, body) {
  return new Promise((resolve) => {
    const dialog = $("#ask");
    $("#ask-title").textContent = title;
    $("#ask-body").textContent = body;
    dialog.onclose = () => resolve(dialog.returnValue === "yes");
    dialog.showModal();
  });
}

function sheet(title, text, { filter = false } = {}) {
  const dialog = $("#sheet");
  $("#sheet-title").textContent = title;
  $("#sheet-body").value = text;
  $("#sheet-filter-wrap").hidden = !filter;
  $("#sheet-errors-only").checked = false;
  dialog.showModal();
}

/* ------------------------------------------------------------------- cards */
function meter(value, tone, label) {
  return `<div class="meter"><b class="t-${tone}">${value ?? "—"}</b><span>${label}</span></div>`;
}

/* HOW FAR BEHIND, IN WORDS, AND ONE COPY OF IT. The payload carries seconds
 * because that is what a subscriber can compare; a person reading a card or a
 * band wants "3.2h", and 11422 is a number they would have to do arithmetic on
 * to feel. Two surfaces render this now -- the card below and the band further
 * down -- and the thresholds are the same ones staleness.sh's `human()` uses,
 * so a second copy on this side of the wire would be a third reading of the
 * same seconds.
 */
function behind(s) {
  return s < 90 ? `${s}s`
    : s < 5400 ? `${Math.round(s / 60)}m`
    : s < 172800 ? `${(s / 3600).toFixed(1)}h`
    : `${(s / 86400).toFixed(1)} days`;
}

function cardHTML(container) {
  const r = container.resources || {};
  const dot = `<span class="dot t-${container.tone}${container.pulse ? " pulse" : ""}">●</span>`;

  // ON THE CARD, because the card is where a person is already looking when
  // they decide whether to trust what they are seeing. Every other field this
  // card draws about a stale container is green and correct -- it is up, it is
  // healthy, its meters move -- so the one fact that contradicts them has to
  // ride on the same tile rather than only in the band above the grid.
  //
  // ONLY "yes" DRAWS. api.snapshot() folds the verdict on for the unhurried
  // cadence only, so a missing `staleness` means NOT ASKED, not current; and
  // `unbuilt` is the dark band's news one step earlier, `unknown` is the reader
  // declining to answer. Painting either of those violet would put a colour on
  // the grid that means "we do not know", which is what grey already means.
  const verdict = container.staleness;
  const isStale = !!verdict && verdict.stale === "yes";
  // NOT A TONE SWAP. `container.tone` still answers "how is this container
  // doing" and a stale container is usually doing fine; violet is a second,
  // separate line, and the border says which card to look at from across the
  // room without repainting the dot that answers the other question.
  const staleRow = isStale ? `
      <div class="stale-row t-stale" title="${escapeAttr(verdict.newest || "")}">⚡ stale ·
        ${behind(verdict.behind || 0)} behind${verdict.newest
          ? ` · <span class="stale-newest">${escapeHTML(verdict.newest)}</span>` : ""}</div>
      <div class="stale-fix"><button class="btn small violet"
             data-rebuild="${escapeAttr(container.name)}"
             title="Rebuild this image from the tree and swap this container. The old one keeps running until the build succeeds, and nothing else on the bench is touched."></button></div>` : "";
  const kill = container.dead
    ? `<button class="kill" data-remove="${escapeAttr(container.name)}" title="Remove this stopped container">✕</button>`
    : "";

  const lines = [];
  if (container.published.length) {
    lines.push(...container.published.slice(0, 4).map((p) => `🔌 ${p}`));
    if (container.published.length > 4) lines.push(`   +${container.published.length - 4} more mapping(s)`);
  } else if (container.network_mode !== "host") {
    lines.push("🔌 no published ports");
  }
  if (container.image) lines.push(`📦 ${container.image}`);

  // NOT an idle container. A host-networked container has no veth, so docker
  // stats has nothing to count and prints 0B / 0B forever. Said on the meter
  // itself, because the alternative is reading that zero as a node that has
  // stopped talking.
  // THE STATE EMOJI AND ITS SENTENCE ARE TWO SPANS, AND THAT IS WHAT LETS THE
  // FOLDED CARD KEEP THE FIRST AND DROP THE SECOND. At `low` density every row
  // under the name is hidden, which used to leave a 9px dot as the only thing
  // on the tile that said how the container was doing -- one glyph, at a size
  // that is legible only if you already know which card you are looking for.
  // The stylesheet keeps the emoji there instead, at twice the type size, and
  // hides the words beside it; nothing here changes per density.
  const netCaption = container.network_mode === "host"
    ? "🏠 host networking, no veth to count"
    : "🔀 RX / TX";

  const apps = container.apps.length ? `
    <div class="apps">
      <div class="apps-head">APPS · ${container.apps.filter((a) => a.state === "running").length}/${container.apps.length} running</div>
      ${container.apps.slice(0, 8).map((app) => {
        const tone = appTone(app.state);
        return `<div class="app">
          <span class="t-${tone}${appPulses(app.state) ? " pulse" : ""}">●</span>
          <span class="app-name">${escapeHTML(app.app)}</span>
          <span class="app-state t-${tone}">${escapeHTML(app.state)}</span>
        </div>`;
      }).join("")}
      ${container.apps.length > 8 ? `<div class="app"><span class="app-name">…and ${container.apps.length - 8} more</span></div>` : ""}
    </div>` : "";

  return `
    <article class="card${container.ours ? " ours" : ""}${isStale ? " stale" : ""}${state.selected === container.name ? " selected" : ""}"
             data-container="${escapeAttr(container.name)}">
      ${kill}
      <div class="head">${dot}<span class="name" title="${escapeAttr(container.name)}"
        >${container.role} ${escapeHTML(container.leaf || container.name)}</span></div>
      <div class="status t-${container.tone}"><span class="status-emoji">${container.emoji}</span> <span
        class="status-text">${escapeHTML(container.status || "unknown")}</span></div>
      ${staleRow}
      <div class="meters">
        ${meter(r.cpu_percent, container.tone, "CPU")}
        ${meter(r.memory_percent, container.tone, "MEM")}
      </div>
      <div class="net">${escapeHTML(r.memory || "—")} <small>${escapeHTML(r.net_io || "")}</small></div>
      <div class="net"><small>${netCaption}</small></div>
      <div class="detail-lines${container.published.length ? "" : " unreachable"}">${escapeHTML(lines.join("\n"))}</div>
      ${apps}
    </article>`;
}

/* WHAT NO CARD IS ABOUT. The two bands below are both about containers -- one
 * that is missing, one that is lying. This one is about the BOX they are on,
 * and about the container that is still here and stopped, because those are the
 * two facts this page had nowhere to put.
 *
 * ON 2026-09-09 THE ROOT FILESYSTEM FILLED AND NOTHING HERE SAID SO. Every
 * writer on the machine failed in the same minute; MariaDB crash-looped, and
 * Netbox-Postgres, Netbox-Valkey and Netbox-Worker exited 1 and were still down
 * hours later. The stack was not dark -- its containers all existed -- so the
 * band below drew nothing, and the cards drew three grey tiles among five. The
 * disk was never on this page at all.
 *
 * IT IS HIDDEN ON A HEALTHY BENCH, AND THAT IS THE POINT. A meter that is
 * always drawn is a meter nobody reads; a band that appears is an event. The
 * threshold is the SERVER's (readers.DISK_WARNING_PERCENT) and arrives as
 * `level`, so this file compares nothing -- a second copy of the number here is
 * the copy that never gets raised when the first one is.
 */
function renderBenchHealth(snapshot) {
  const host = $("#bench-health");
  const disk = (snapshot.host && snapshot.host.disk) || {};
  // MID-ACTION SUPPRESSION FOR THE STOPPED HALF ONLY, and the split is
  // deliberate. A rebuild stops containers on its way through, so naming them
  // during one is naming the happy path; a disk that is 96% full is exactly as
  // true mid-rebuild, and a rebuild is when it is most likely to end the build.
  const stopped = snapshot.action_running ? [] : (snapshot.stopped_containers || []);
  const diskBad = disk.level === "warning" || disk.level === "critical";
  host.hidden = !diskBad && !stopped.length;
  if (host.hidden) { host.innerHTML = ""; return; }

  const gib = (kb) => `${((Number(kb) || 0) / (1024 * 1024)).toFixed(1)} GiB`;
  host.innerHTML = [
    diskBad ? `
      <p class="dark-lead ${disk.level === "critical" ? "stranded" : ""}">💾
         <b>${disk.level === "critical" ? "The disk is nearly full" : "The disk is filling"} —
         ${disk.used_percent}% of ${escapeHTML(disk.filesystem || "the volume")} is used,
         ${gib(disk.available_kb)} left.</b>
         Every container writing to <code>${escapeHTML(disk.root || "")}</code> shares it, and a
         database that cannot write does not warn — it exits. Reclaim layers with Prune, or find
         the consumer before this becomes an outage.</p>` : "",
    stopped.length ? `
      <p class="dark-lead">🛑 <b>${stopped.length} container${stopped.length > 1 ? "s" : ""}
         exited and ${stopped.length > 1 ? "were" : "was"} not restarted.</b>
         ${stopped.length > 1 ? "Their" : "Its"} compose file asked docker to keep
         ${stopped.length > 1 ? "them" : "it"} up, so ${stopped.length > 1 ? "these are" : "this is"}
         not a one-shot that finished — something stopped ${stopped.length > 1 ? "them" : "it"} and
         nothing brought ${stopped.length > 1 ? "them" : "it"} back.</p>
      ${stopped.map((row) => `
        <div class="dark-stack driven">
          <h3>🛑 ${escapeHTML(row.container)} <small>${escapeHTML(row.stack)}</small></h3>
          <p class="dark-fix"><button class="btn small accent" data-saction="up-stack"
               data-stack="${escapeAttr(row.stack)}"></button>
             <span>brings <b>${escapeHTML(row.stack)}</b> back up and nothing else;
             the per-container Restart does just this one.</span></p>
        </div>`).join("")}` : "",
  ].join("");

  // The verbs are named by the server and this markup was written after boot
  // did the naming, so the buttons just planted are labelled and wired here.
  if (state.actions) labelVerbs();
}

/* WHAT THE GRID CANNOT DRAW. Every card is a container that exists; a stack
 * whose containers were all removed has no card, and on a page made of cards an
 * absence and a thing-that-was-never-here are the same picture. This band is
 * the difference. Server:Discovery:NMOS/ was empty for hours behind a green
 * dashboard because there was nowhere for that fact to appear.
 *
 * THE TWO KINDS ARE NOT THE SAME NEWS, which is the whole reason `restorable`
 * is on the wire. A dark stack this tool DRIVES is a remount that did not take
 * — press the row's own remount. A dark stack it does not drive is down until a
 * person runs the command, because a panic removes containers host-wide and
 * the remount behind it only knows three of the six compose files. So the
 * second kind carries its command and the first carries the button.
 *
 * AND THE BUTTON IS SCOPED TO THE ROW IT SITS IN. It used to be `up` — the
 * whole bench, eight compose files, minutes of build — under a heading naming
 * ONE stack; on the row this band draws most often, DockTor, that
 * verb rebuilt every stack EXCEPT the one the row was about, because
 * `for_each_stack` does not drive the manager's compose file. `up-stack` takes
 * the stack name this row already carries and runs that file and no other.
 */
function renderDarkStacks(snapshot) {
  const host = $("#dark-stacks");
  const dark = snapshot.dark_stacks || [];
  host.hidden = !dark.length;
  if (!dark.length) { host.innerHTML = ""; return; }

  // THE REASON IS SAID ONCE, ABOVE THE ROWS, and the rows carry only what
  // differs. Three stacks each repeating the same paragraph filled half the
  // grid pane with one sentence written three times, and pushed the containers
  // that ARE running below the fold — which is its own way of hiding the bench.
  const stranded = dark.filter((row) => !row.restorable);
  // A DRIVEN STACK IS SUPPOSED TO BE DARK MID-REBUILD. `action_running` is the
  // server's ACTION_LOCK, so this holds for a rebuild started in another tab
  // too, and follow(false) rescans the moment the verb finishes -- a stack that
  // is STILL dark then is the real finding and appears then. The stranded rows
  // stay visible throughout: no verb here was going to restore those anyway,
  // and a panic is exactly when they need saying.
  const driven = snapshot.action_running ? [] : dark.filter((row) => row.restorable);
  // THE PAGE HAS TO BE ABLE TO ACCUSE ITSELF, and this is the one case where
  // the answer is sitting in front of the person reading it. The manager runs
  // `network_mode: host`, so a manager started at a terminal and the
  // containerised one contend for the SAME 127.0.0.1:8765 — and the terminal
  // one wins simply by being first, which after a panic it always is. The
  // container then cannot bind, DockTor shows as dark-and-driven, and
  // "read the execution log" sends the reader to a log that says the remount
  // succeeded. It did. `manager` on the snapshot is who is serving THIS page;
  // when that is not the container, it is the reason, and the fix is to stop it.
  const servedBy = snapshot.manager || {};
  const selfHeld = servedBy.containerised === false &&
        driven.some((row) => row.stack === "DockTor");
  // A ROW THAT NAMES A FAULT THIS PAGE CAN FIX CARRIES THE FIX. The driven rows
  // used to end at "read the execution log", which is a diagnosis handed to
  // somebody who is already looking at the one screen that could have acted on
  // it — three clicks away through a menu, to press a verb the paragraph had
  // just described without naming. `data-action` is the same wiring every verb
  // in the toolbar uses, so the label is the SERVER's (labelVerbs) and follow()
  // greys this one with the rest while a build is running.
  //
  // The stranded rows still get a command instead of a button, and that is not
  // an inconsistency: no verb on this page drives those compose files, so a
  // button there would be one that cannot work.
  const rowHTML = (row) => `
    <div class="dark-stack${row.restorable ? " driven" : ""}">
      <h3>${row.restorable ? "⚠" : "🚧"} ${escapeHTML(row.stack)}
          <small>${row.declared} declared, none present</small></h3>
      <p class="absent">${escapeHTML(row.absent.join("  ·  "))}</p>
      ${row.restorable
        ? `<p class="dark-fix"><button class="btn small accent" data-saction="up-stack"
               data-stack="${escapeAttr(row.stack)}"></button>
             <span>builds the image if it is missing and brings up
             <b>${escapeHTML(row.stack)}</b> — that stack alone, none of the others.</span></p>`
        : `<code>docker compose -f '${escapeHTML(row.compose_file)}' up -d --build</code>`}
    </div>`;

  host.innerHTML = [
    stranded.length ? `
      <p class="dark-lead stranded">🚧 <b>${stranded.length} stack${stranded.length > 1 ? "s" : ""} declared
         under APK:DOCKERS/ ${stranded.length > 1 ? "have" : "has"} no containers at all, and nothing on
         this page will restart ${stranded.length > 1 ? "them" : "it"}.</b>
         A panic removes containers host-wide; the remount behind it drives three of the six
         compose files. Run the command to bring one back.</p>
      ${stranded.map(rowHTML).join("")}` : "",
    driven.length ? `
      <p class="dark-lead">⚠ <b>${driven.length} stack${driven.length > 1 ? "s" : ""} this tool DRIVES
         ${driven.length > 1 ? "are" : "is"} empty.</b> Each row's remount builds and mounts
         ${driven.length > 1 ? "that stack alone" : "it"}; if it has already been pressed, the
         execution log says how far it got.</p>
      ${selfHeld ? `
        <p class="dark-lead self-held">🪞 <b>And this page is why.</b> You are reading it from a
           DockTor started at a terminal — pid ${escapeHTML(String(servedBy.pid))} on
           ${escapeHTML(String(servedBy.hostname))} — not from the container. It holds
           127.0.0.1:8765 on the host's network stack, so <b>DockTor cannot bind and no
           remount will ever win that port.</b> Remount anyway if the image is missing — the
           container waits for the port rather than exiting — then Ctrl+C that process, or run
           this, and it takes the socket within five seconds. <b>This tab goes dark when you
           do; reload it and the container is serving.</b></p>
        <code class="self-held-cmd">kill ${escapeHTML(String(servedBy.pid))}</code>` : ""}
      ${driven.map(rowHTML).join("")}` : "",
  ].join("");

  // The verbs are named by the server and this markup was written after boot
  // did the naming, so the buttons just planted are labelled and wired here.
  // Guarded because the first grid can land before /api/actions answers.
  if (state.actions) labelVerbs();
}

/* WHAT THE GRID DRAWS WRONG. renderDarkStacks() above covers the container that
 * is not there; this covers the container that IS there and is lying. A stale
 * image runs, answers its health check, moves its meters and draws a green card
 * — every signal this page has says fine, and the code inside it was replaced
 * hours ago. The card itself now carries the verdict -- cardHTML() draws the
 * violet row and takes the violet edge -- and this band stays anyway, because a
 * fact on one tile among forty is a fact that has to be FOUND. The band is the
 * count and the newest file at the top of the page; the card is where the
 * finding lands when you go looking for it.
 *
 * IT IS SUPPRESSED MID-ACTION for the reason the driven dark rows are: a
 * rebuild in flight makes this answer change under the reader, and a warning
 * that fires on the happy path is a warning that gets learnt as noise.
 * follow(false) rescans the moment the verb finishes, so an image that is STILL
 * stale then is the real finding and appears then.
 */
function renderStaleImages(snapshot) {
  const host = $("#stale-images");
  const stale = snapshot.action_running ? [] : (snapshot.stale_services || []);
  host.hidden = !stale.length;
  if (!stale.length) { host.innerHTML = ""; return; }

  // THE CAPTION UNDER THE BUTTON IS SAID ONCE, IN THE LEAD, and the rows carry
  // only what differs. Seven rows each repeating the same sentence about what a
  // rebuild does is the shape the dark-stack band above was rewritten to stop
  // drawing: it fills the pane with one sentence written seven times and pushes
  // the containers that ARE fine below the fold.
  //
  // WHAT THE ROW IS ABOUT IS THE CONTAINER, and it is the heading now. It used
  // to be the stack, with the container's name printed underneath as a bare
  // word and the image and the age crammed into the heading's `small` — so a
  // row read as four unlabelled strings about a stack that has nothing wrong
  // with it. Every field below says what it is: the container, the image it is
  // running, how far that image lags, and the file that decided so.
  host.innerHTML = `
    <p class="dark-lead stale">⚡ <b>${stale.length} container${stale.length > 1 ? "s are" : " is"}
       running an image that was built before the code inside it.</b>
       ${stale.length > 1 ? "They are" : "It is"} up and healthy and every other reading on this
       page says so — this is the one that does not. <b>What is compared:</b> the moment the image
       was built, against the newest file its Dockerfile copies in. Each 🧱 Rebuild below builds
       that one image from the tree and swaps its container — the old one keeps running until the
       build succeeds — and nothing else on the bench is touched. ⚡ Rebuild All Dockers &amp; Mount
       does all of ${stale.length > 1 ? "them" : "it"} and everything else besides.</p>
    ${stale.map((row) => `
      <div class="dark-stack stale">
        <h3>⚡ ${escapeHTML(row.container || row.service)}
            <small>in ${escapeHTML(row.stack)}</small></h3>
        <p class="absent">image <code>${escapeHTML(row.image || row.service)}</code> —
           built <b>${behind(row.behind)}</b> before this file was last changed:</p>
        <p class="newest"><code>${escapeHTML(row.newest || "—")}</code></p>
        ${row.container ? `
          <p class="dark-fix"><button class="btn small violet" data-cverb="rebuild"
               data-container="${escapeAttr(row.container)}"></button></p>` : ""}
      </div>`).join("")}`;

  // The verb's words are the server's, like every other button on this page,
  // and the container it is aimed at is the row's. Guarded because the first
  // grid can land before /api/actions answers.
  if (state.actions) {
    $$("[data-cverb]", host).forEach((button) => {
      const row = state.actions.container_actions[button.dataset.cverb];
      button.textContent = row ? row.label : button.dataset.cverb;
      button.onclick = () => runContainerAction(button.dataset.cverb,
                                                button.dataset.container, button);
    });
  }
}

function renderGrid(snapshot) {
  state.snapshot = snapshot;
  // EVERY CARD'S METERS, INTO THE ONE MAP THE OTHER VIEWS READ. The scan
  // carries a stats sample of its own (api.snapshot joins ps.sh and stats.sh
  // in one moment on purpose), so the donut is live on the ⏱ cadence with the
  // five-second one disarmed -- just slower.
  for (const group of snapshot.groups || []) {
    for (const container of group.containers) {
      if (container.resources) state.resources[container.name] = container.resources;
      else delete state.resources[container.name];
    }
  }
  // NEVER BACK TO ZERO. A scan that could not reach docker still returns a
  // document, with host.cpus 0 in it; letting that overwrite a count we already
  // have would take the idle wedge off the ring for one tick and put the
  // caption back, which reads as the page changing its mind about the box.
  if (snapshot.host && snapshot.host.cpus) state.hostCpus = snapshot.host.cpus;
  if (snapshot.host && snapshot.host.memory_bytes) state.hostMemory = snapshot.host.memory_bytes;
  renderBenchHealth(snapshot);
  renderDarkStacks(snapshot);
  renderStaleImages(snapshot);
  const host = $("#cards");
  if (!snapshot.count) {
    // AND THE BAND IS ALREADY DRAWN, above this guard on purpose. An empty
    // bench is exactly when "which stacks are missing" is the only question on
    // the page, and returning before renderDarkStacks() would answer it with
    // one grey sentence about mounting the stack.
    host.innerHTML = `<p class="empty">No containers. Mount the stack to see them here.</p>`;
    return;
  }
  // THE STACK IS DRAWN ONCE AND COLOURED THROUGHOUT. `--group` is set on the
  // heading and on the block of cards under it, and the stylesheet spends it on
  // the heading's text and each card's left edge -- never on the dot, the
  // status, the meters or the app rows, which are the five state tones' and
  // must keep meaning health. The colour comes from palette.py with the rest of
  // them; a hue picked here would be the second table this page was built to
  // avoid.
  host.innerHTML = snapshot.groups.map((group) => {
    const hue = ` style="--group: ${escapeAttr(group.hue || "")}"`;
    return `
    <div class="group-head${group.ours ? " ours" : ""}"${hue}>${escapeHTML(group.label)} · ${group.containers.length}</div>
    <div class="group"${hue}>${group.containers.map(cardHTML).join("")}</div>`;
  }).join("");

  $$(".card", host).forEach((card) => {
    card.onclick = (event) => {
      // ANY BUTTON ON THE TILE, not just the ✕. The card grew a second one, and
      // a list of exempt attributes is a list that goes stale the third time.
      if (event.target.closest("button")) return;
      select(card.dataset.container);
    };
  });
  $$("[data-remove]", host).forEach((button) => {
    button.onclick = (event) => {
      event.stopPropagation();
      runContainerAction("remove", button.dataset.remove, button);
    };
  });
  // THE FIX WHERE THE FINDING IS. renderStaleImages() draws this same verb in
  // the band above the grid, and that band is the COUNT -- it is how a stale
  // container gets found among forty. This is how it gets acted on without
  // scrolling back up: the card already carries the verdict, so it carries the
  // one button that answers it. Same server verb, same one-at-a-time lock, and
  // the label is the server's like every other button on this page.
  $$("[data-rebuild]", host).forEach((button) => {
    const row = state.actions && state.actions.container_actions.rebuild;
    button.textContent = row ? row.label : "rebuild";
    button.onclick = (event) => {
      event.stopPropagation();
      runContainerAction("rebuild", button.dataset.rebuild, button);
    };
  });
  renderViews();
}

/* METERS ONLY, into cards that already exist. Building a card from a stats
 * sample would make one with no status, ports or image. */
function applyMeters(resources) {
  state.resources = resources.containers;
  if (resources.host && resources.host.cpus) state.hostCpus = resources.host.cpus;
  if (resources.host && resources.host.memory_bytes) state.hostMemory = resources.host.memory_bytes;
  // The ring is the same sample, so it moves on the same tick. It is REBUILT
  // rather than written into: a donut's geometry is its data, and there is no
  // equivalent of "the number in this box changed".
  if (state.view === "donuts") renderDonuts();
  $$(".card").forEach((card) => {
    const row = resources.containers[card.dataset.container];
    const values = $$(".meter b", card);
    if (!values.length) return;
    values[0].textContent = row ? row.cpu_percent : "—";
    values[1].textContent = row ? row.memory_percent : "—";
    const nets = $$(".net", card);
    if (nets.length && row) {
      nets[0].innerHTML = `${escapeHTML(row.memory || "—")} <small>${escapeHTML(row.net_io || "")}</small>`;
    }
  });
}

/* ------------------------------------------------------- the other two views
 *
 * THREE READINGS OF ONE SNAPSHOT, AND ONLY THE CARDS ARE A GRID. Everything
 * below is drawn from `state.snapshot` and `state.resources`, which are what
 * the scan and meter cadences already put there -- no view here fetches
 * anything of its own except the endpoint table, which is a join the docker
 * half cannot supply. Switching view HIDES #cards rather than emptying it, so
 * the five-second meter cadence keeps writing into the cards while the donut
 * is up and coming back is a toggle rather than a rescan.
 *
 * WHY EITHER EXISTS. A card grid answers "how is this container" forty times
 * and cannot be read for the two questions asked most often at a broken bench:
 * WHO IS EATING THE BOX -- a share, which is a comparison ACROSS cards and so
 * exists nowhere on any one of them -- and WHAT IS ON 8080, which the grid can
 * only answer by reading every card's port lines in turn. */
const VIEWS = ["cards", "donuts", "ports"];

function applyView(name) {
  state.view = VIEWS.includes(name) ? name : "cards";
  $("#cards").hidden  = state.view !== "cards";
  $("#donuts").hidden = state.view !== "donuts";
  $("#ports").hidden  = state.view !== "ports";
  // The detail level is a property of a CARD. Left on screen over a donut it
  // is a control with nothing to control, and the first thing tried when the
  // ring looks wrong.
  $("#density").closest("label").hidden = state.view !== "cards";
  try { localStorage.setItem("apk.manager.view", state.view); } catch { /* no store */ }
  renderViews();
  // The docker half of the port table rides the scan cadence; the endpoint
  // half is endpoints.sh -- `docker port` and an inspect per container -- and
  // is far too expensive to put on a cadence. Re-read on arrival instead.
  if (state.view === "ports") loadWebPages();
}

function savedView() {
  try { return localStorage.getItem("apk.manager.view"); } catch { return null; }
}

function renderViews() {
  if (state.view === "donuts") renderDonuts();
  if (state.view === "ports") renderPorts();
}

/* ------------------------------------------------------ reading the numbers
 *
 * DOCKER PRINTS TWO UNIT TABLES IN ONE ROW AND THEY ARE NOT THE SAME TABLE.
 * MemUsage is binary -- `12.5MiB / 7.66GiB` -- and NetIO is decimal, `1.2MB`.
 * Both are read here, so both are in the map; a parser that knew only powers
 * of 1024 would report the network 5% low and slowly, which is the shape of
 * error nobody catches by looking. */
const BYTE_UNITS = { b: 1, kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12,
                     kib: 1024, mib: 1024 ** 2, gib: 1024 ** 3, tib: 1024 ** 4 };

function bytes(text) {
  const found = /([\d.]+)\s*([kmgt]?i?b)/i.exec(String(text ?? ""));
  const scale = found && BYTE_UNITS[found[2].toLowerCase()];
  return scale ? parseFloat(found[1]) * scale : 0;
}

function humanBytes(value) {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let n = Number(value) || 0, unit = 0;
  while (n >= 1024 && unit < units.length - 1) { n /= 1024; unit += 1; }
  return `${n < 10 ? n.toFixed(2) : n.toFixed(n < 100 ? 1 : 0)} ${units[unit]}`;
}

// "12.34%" -> 12.34, and "—" -> 0. A missing meter is a container docker stats
// did not report, which is a container using nothing, not a hole in the total.
const percent = (text) => {
  const n = parseFloat(String(text ?? "").replace(/[^\d.]/g, ""));
  return Number.isFinite(n) ? n : 0;
};

/* ------------------------------------------------------------------ donuts */

/* THE SLICES ARE THE STACK'S COLOUR, NOT A COLOUR OF THIS FILE'S. `hue` comes
 * down per group from palette.hues_for(), which is the same table the group
 * headings and card edges spend, so a ring reads against the grid beside it
 * without anybody learning a second key. Members of one stack are separated by
 * OPACITY rather than by a hue of their own: a stack is the thing you are
 * looking for when a box is pinned, and four Netbox containers that are four
 * unrelated colours hide the fact that Netbox is the answer. */
function sliceRows(valueOf) {
  const rows = [];
  for (const group of state.snapshot?.groups || []) {
    let within = 0;
    for (const container of group.containers) {
      const sample = state.resources[container.name];
      if (!sample) continue;
      const value = valueOf(sample);
      if (!(value > 0)) continue;
      rows.push({
        name: container.name,
        leaf: container.leaf || container.name,
        stack: group.label,
        hue: group.hue || "",
        shade: 1 - Math.min(within, 4) * 0.17,
        value,
      });
      within += 1;
    }
  }
  return rows.sort((first, second) => second.value - first.value);
}

/* A RING WITH FORTY SLICES IS A COLOUR WHEEL. Ten named and the rest summed is
 * the reading that survives a bench this size -- and the tail is kept as a
 * slice rather than dropped, because a ring whose slices do not add up to its
 * own centre number is worse than one with a grey wedge in it. */
function rollUpTail(rows, keep = 10) {
  if (rows.length <= keep) return rows;
  const tail = rows.slice(keep);
  return [...rows.slice(0, keep), {
    name: "", leaf: `…and ${tail.length} more`, stack: "", hue: "#6f7480", shade: 1,
    value: tail.reduce((sum, row) => sum + row.value, 0), rolled: true,
  }];
}

const RING = { radius: 48, width: 18 };
const RING_LENGTH = 2 * Math.PI * RING.radius;

function donutHTML(rows, centre, centreNote, format) {
  const total = rows.reduce((sum, row) => sum + row.value, 0);
  let travelled = 0;
  const arcs = rows.map((row) => {
    const length = (row.value / total) * RING_LENGTH;
    // A HAIRLINE, NOT A ROUND CAP. Two touching slices of one stack hue read
    // as a single slice; `stroke-linecap: round` separates them by overlapping
    // the neighbour, which moves the boundary rather than showing it.
    const drawn = Math.max(length - 1.4, 0.5);
    const arc = `<circle r="${RING.radius}" cx="60" cy="60" fill="none"
        stroke="${escapeAttr(row.hue || "#6f7480")}" stroke-opacity="${row.shade.toFixed(2)}"
        stroke-width="${RING.width}"
        stroke-dasharray="${drawn.toFixed(2)} ${(RING_LENGTH - drawn).toFixed(2)}"
        stroke-dashoffset="${(-travelled).toFixed(2)}" transform="rotate(-90 60 60)"
      ><title>${escapeHTML(row.name || row.leaf)} — ${escapeHTML(format(row.value))}</title></circle>`;
    travelled += length;
    return arc;
  }).join("");

  const legend = rows.map((row) => `
    <li${row.name ? ` data-container="${escapeAttr(row.name)}"` : ""}${row.rolled ? ' class="rolled"' : ""}>
      <span class="swatch" style="background: ${escapeAttr(row.hue || "#6f7480")};
                                  opacity: ${row.shade.toFixed(2)}"></span>
      <span class="who" title="${escapeAttr(row.name || row.leaf)}"
        >${escapeHTML(row.leaf)}${row.stack ? `<small> · ${escapeHTML(row.stack)}</small>` : ""}</span>
      <b>${escapeHTML(format(row.value))}</b>
      <span class="share">${((row.value / total) * 100).toFixed(1)}%</span>
    </li>`).join("");

  return `
    <div class="ring">
      <svg viewBox="0 0 120 120" role="img" aria-label="${escapeAttr(centre)} in ${rows.length} slice(s)">
        <circle class="track" r="${RING.radius}" cx="60" cy="60" fill="none"
                stroke-width="${RING.width}"/>
        ${arcs}
      </svg>
      <div class="centre"><b>${escapeHTML(centre)}</b><span>${escapeHTML(centreNote)}</span></div>
    </div>
    <ol class="legend">${legend}</ol>`;
}

function renderDonuts() {
  const host = $("#donuts");
  const samples = Object.values(state.resources);
  if (!samples.length) {
    host.innerHTML = `<p class="empty">No stats sample yet — docker stats reports only
       RUNNING containers, so an empty bench draws no ring.</p>`;
    return;
  }

  // COUNTED BEFORE THE ROLL-UP, drawn after it. The heading says how many
  // containers are in the total; the ring names ten of them and sums the rest.
  // Counting the drawn slices instead reported eleven containers on a bench of
  // twenty-four, and the eleventh was the word "more".
  const cpuAll = sliceRows((row) => percent(row.cpu_percent));
  const ramAll = sliceRows((row) => bytes((row.memory || "").split("/")[0]));
  const cpu = rollUpTail(cpuAll);
  const ram = rollUpTail(ramAll);
  const cpuTotal = cpuAll.reduce((sum, row) => sum + row.value, 0);
  const ramTotal = ramAll.reduce((sum, row) => sum + row.value, 0);

  // THE IDLE HALF, DRAWABLE AT LAST BECAUSE SOMETHING NOW CARRIES THE CORE
  // COUNT. Every slice above is in docker's units, where one fully busy core is
  // 100%; the box in those same units is therefore `cores × 100`, and the wedge
  // is the subtraction. `state.hostCpus` is the daemon's own NCPU, arriving on
  // /api/resources and /api/containers alike -- NOT nproc and not the browser's
  // hardwareConcurrency, both of which answer about the wrong machine. Zero
  // means the server has not said, and the ring below then goes back to what it
  // could always draw honestly: the containers' share of each other, captioned.
  // PLAN-1049.01.
  const cores = state.hostCpus;
  const boxCPU = cores * 100;
  // AND IT IS NOT CALLED "IDLE". Everything on this box that is not in a
  // container -- the desktop, a cargo build, the manager serving this page when
  // it is run at a terminal -- is inside this wedge, and docker can see none of
  // it. "Idle" would be the one number on this page that is confidently wrong.
  const spare = Math.max(boxCPU - cpuTotal, 0);
  const cpuRing = cores
    ? [...cpu, {name: "", leaf: "not in containers", stack: "", hue: "#6f7480",
                // `rolled` is the legend's DIM-AND-UNCLICKABLE style, which is
                // what this row needs for the same reason the tail did: it is
                // the one entry that is not a container you can open.
                shade: 1, value: spare, rolled: true}]
    : cpu;
  const boxShare = boxCPU ? (cpuTotal / boxCPU) * 100 : 0;
  // THE HOST'S OWN RAM, ASKED FOR FIRST AND INFERRED ONLY IF NOBODY ANSWERED.
  // This used to be the inference alone: docker reports an UNCONSTRAINED
  // container's limit as the whole machine's memory, so the widest limit in the
  // sample IS the box. That holds only while nothing sets a limit -- one
  // `mem_limit:` on the containers being sampled makes the widest limit a
  // CONTAINER's, and the ring then divides by 2 GiB on a 32 GiB box and calls
  // an idle bench 60% full, with nothing on screen to say it moved.
  // `state.hostMemory` is the daemon's own MemTotal off /api/resources and
  // /api/containers, which no compose file can shift. THE INFERENCE STAYS as
  // the fallback rather than being deleted: it is what the ring draws when
  // `docker info` will not answer, and it is right far more often than wrong.
  // PLAN-1049.02.
  const sampledRAM = Math.max(0, ...samples.map((row) => bytes((row.memory || "").split("/")[1])));
  const boxRAM = state.hostMemory || sampledRAM;

  host.innerHTML = `
    <div class="donut">
      <h3>⚙️ CPU — ${cores ? `${boxShare.toFixed(1)}% of ${cores} cores` : `${cpuTotal.toFixed(1)}%`}
          across ${cpuAll.length} container(s)</h3>
      ${cpuTotal > 0
        ? donutHTML(cpuRing,
                    cores ? `${boxShare.toFixed(1)}%` : `${cpuTotal.toFixed(1)}%`,
                    cores ? `of ${cores} cores on the box` : "summed · 100% = one core",
                    (value) => `${value.toFixed(2)}%`)
        : `<p class="empty">Every container is reporting 0.00% — nothing on this bench is busy.</p>`}
      <p class="note">${cores
        ? `docker counts ONE FULL CORE as 100%, so the <b>${cpuTotal.toFixed(1)}%</b> these
           containers report is ${boxShare.toFixed(1)}% of the ${cores} cores
           <code>docker info</code> says this box has — and the grey wedge is the rest of it.
           That wedge is NOT idle silicon: everything on this machine that is not in a container
           is in it, and docker cannot see any of it.`
        : `docker counts ONE FULL CORE as 100%, so this total is not a share of the box: on an
           8-core host it can reach 800% before anything is saturated. The ring divides what the
           containers are using between them; it cannot draw the idle half, because the server
           did not report a core count on this sample and a denominator this page invented would
           be the one number here nobody could check.`}</p>
    </div>

    <div class="donut">
      <h3>🧠 RAM — ${humanBytes(ramTotal)}${boxRAM ? ` of ${humanBytes(boxRAM)}` : ""} across ${ramAll.length} container(s)</h3>
      ${ramTotal > 0
        ? donutHTML(ram, humanBytes(ramTotal), boxRAM ? `of ${humanBytes(boxRAM)} on the box` : "in containers",
                    humanBytes)
        : `<p class="empty">No container is holding measurable memory.</p>`}
      <p class="note">The whole ring is what the CONTAINERS hold — ${boxRAM
        ? `${((ramTotal / boxRAM) * 100).toFixed(1)}% of the ${humanBytes(boxRAM)} ${state.hostMemory
             ? "<code>docker info</code> says this box has"
             : `docker reports as the limit for an unconstrained container, which is the host's
                own RAM only while no container in this sample sets a <code>mem_limit:</code> —
                the server did not report a host total on this sample`}`
        : "the host total was not in this sample"}. Everything else on the box is outside
         docker's view and therefore outside this ring.</p>
    </div>

    ${state.meters ? "" : `
      <p class="note wide">⏱ These numbers are as old as the last scan
         (${escapeHTML($("#scan-state").textContent || "—")}). Press
         <b>📈 Live Resources</b> in the toolbar to put them on the five-second sample.</p>`}`;

  // A slice is a container, and the pane on the right is what a container is
  // FOR here. Same click the card grid gives.
  $$("[data-container]", host).forEach((row) => {
    row.onclick = () => select(row.dataset.container);
  });
}

/* ------------------------------------------------------------------- ports */

/* WHAT IS ON 8080, AS A JOIN OF THE TWO HALVES THAT EACH KNOW HALF OF IT.
 *
 *   · docker knows every port it has BOUND, and nothing about what answers.
 *   · endpoints.sh knows what answers and under which scheme, and it is the
 *     one copy of that table -- the manager may not spell a port itself.
 *
 * NEITHER IS SUFFICIENT ALONE, and the two shortfalls are not symmetric. A
 * bound port with no endpoint row is a number with no name; an endpoint row
 * with no bound port is the case a ports table built from `docker ps` cannot
 * have at all -- the BareMetal supervisor on 8100 runs `network_mode: host`,
 * publishes nothing, and has no Ports column to be read out of. So the rows
 * are keyed on the PORT and both sides may create one. */
/* A RANGE IS N PORTS, AND THE JOIN ONLY LANDS IF IT IS DRAWN AS N ROWS.
 * `docker ps` folds a consecutive publication into `3209-3211 → 3209-3211/tcp`
 * and endpoints.sh names 3209, 3210 and 3211 one at a time, correctly -- they
 * are three different NMOS APIs. Kept folded, the table drew a range row with
 * no name beside three named rows that each said `not bound`, which is the one
 * reading that is wrong on both halves at once.
 *
 * SIXTY-FOUR IS THE CEILING and it is not a tuning knob: a container that
 * publishes `1-65535` is a container that would otherwise fill this pane with
 * sixty-five thousand rows, and the range said as one row is the honest
 * rendering of a publication nobody meant to enumerate. */
function spreadRange(text) {
  const [first, last] = String(text).split("-");
  if (last === undefined) return [first];
  const low = parseInt(first, 10), high = parseInt(last, 10);
  if (!Number.isFinite(low) || !Number.isFinite(high) || high < low || high - low > 63) {
    return [String(text)];
  }
  return Array.from({ length: high - low + 1 }, (_, step) => String(low + step));
}

function portRows() {
  const rows = new Map();
  const rowFor = (port, proto) => {
    const key = `${port}/${proto}`;
    if (!rows.has(key)) {
      rows.set(key, { port, proto, sort: parseInt(port, 10) || 0,
                      bound: [], endpoints: [] });
    }
    return rows.get(key);
  };

  for (const group of state.snapshot?.groups || []) {
    for (const container of group.containers) {
      for (const text of container.published || []) {
        // `3212 → 3212/tcp`, and `3209-3211 → 3209-3211/tcp` for a range.
        const parsed = /^([\d-]+)\s*→\s*([\d-]+)\/(\w+)$/.exec(text.trim());
        if (!parsed) continue;
        const hosts = spreadRange(parsed[1]);
        const targets = spreadRange(parsed[2]);
        hosts.forEach((port, index) => {
          rowFor(port, parsed[3]).bound.push({
            container: container.name, leaf: container.leaf || container.name,
            stack: group.label, hue: group.hue || "", tone: container.tone,
            status: container.status,
            // Docker maps a range one-for-one and in order, so the nth host
            // port is the nth container port. A pair of ranges that are not
            // the same length is not something docker prints; if one ever
            // arrives, the whole range is said rather than a wrong pairing.
            target: `${targets.length === hosts.length ? targets[index] : parsed[2]}/${parsed[3]}`,
          });
        });
      }
    }
  }

  const byName = {};
  for (const group of state.snapshot?.groups || []) {
    for (const container of group.containers) byName[container.name] = { container, group };
  }

  for (const endpoint of state.endpoints || []) {
    // THE AUTHORITY, PARSED THE WAY api.undeclared_ports() PARSES IT, and not
    // with `new URL`: half of these are `mqtt://` and `mysql://`, and one of
    // them carries credentials — `mysql://apkaudio:DEV.DB@localhost:3306/…`,
    // whose FIRST colon-and-digits is not a port. Same three steps as the
    // server: take what is between `://` and the next `/`, drop anything
    // before an `@`, and the port is what follows the last colon. `[::1]:8080`
    // survives that for free.
    const authority = ((endpoint.uri || "").split("://")[1] || "").split("/")[0].split("@").pop();
    const found = authority.includes(":") ? /^(\d+)$/.exec(authority.split(":").pop()) : null;
    if (!found) continue;
    const known = byName[endpoint.container];
    // The proto is the row's, not the endpoint's: an endpoint is named for a
    // port docker has bound over TCP, and inventing a second `8080/` row for
    // it would split the one fact the table exists to state.
    const row = rows.has(`${found[1]}/tcp`) ? rows.get(`${found[1]}/tcp`)
                                            : rowFor(found[1], "tcp");
    row.endpoints.push({
      ...endpoint,
      hue: known?.group.hue || "",
      leaf: known?.container.leaf || endpoint.container,
      stack: known?.group.label || "",
      hostNetworked: known?.container.network_mode === "host",
    });
  }

  return [...rows.values()].sort((first, second) =>
    first.sort - second.sort || first.proto.localeCompare(second.proto));
}

function portOpenHTML(row) {
  const open = row.endpoints.filter((e) => e.kind === "open");
  const copy = row.endpoints.filter((e) => e.kind === "copy");
  const links = open.map((e) => e.state === "up"
    ? `<a href="${escapeAttr(e.uri)}" target="_blank" rel="noreferrer">🌐 open ↗</a>`
    // LISTED, NOT OPENED, and the rule is already the Web Pages menu's: a
    // stopped container behind a link produces a browser error page, which
    // reads as a broken SITE rather than as a container that is not running.
    : `<span class="down">⏸️ ${escapeHTML(e.state)}</span>`);
  const copies = copy.map((e) =>
    `<button class="linky" data-copy="${escapeAttr(e.uri)}" title="${escapeAttr(e.uri)}">📋 copy URI</button>`);
  if (links.length || copies.length) return [...links, ...copies].join(" ");
  if (!row.bound.length) return `<span class="down">—</span>`;
  // NOTHING NAMED IT, SO THE SCHEME IS A GUESS AND SAYS SO. The PORT is not a
  // guess -- docker has it bound this second -- and the host is the one this
  // page was reached on, which is the machine the bench is on by definition.
  // It is styled down and titled rather than dropped: `endpoints.sh` names the
  // handful of services it knows, and a table that offered nothing for the
  // other thirty would send the reader to type the same URL by hand.
  const guess = `http://${location.hostname}:${String(row.port).split("-")[0]}/`;
  return `<a class="guess" href="${escapeAttr(guess)}" target="_blank" rel="noreferrer"
             title="No endpoint is declared for this port — docker has it bound, but the http:// is this page's guess.">🔎 try http ↗</a>`;
}

function renderPorts() {
  const host = $("#ports");
  const rows = portRows();
  if (!rows.length) {
    host.innerHTML = `<p class="empty">Nothing is publishing a port, and endpoints.sh named
       no address either.</p>`;
    return;
  }

  const named = rows.filter((row) => row.endpoints.length).length;
  const body = rows.map((row) => {
    // ONE CONTAINER, SAID ONCE. Three NetBox endpoints on 8081 are three
    // things to open and ONE container to name; repeating the name per
    // endpoint made the row read as three containers fighting over a port,
    // which is the one thing a port table must never say by accident.
    const seen = new Set();
    const who = row.bound.length
      ? row.bound.filter((b) => !seen.has(b.container) && seen.add(b.container)).map((b) => `
          <span class="who" data-container="${escapeAttr(b.container)}">
            <span class="swatch" style="background: ${escapeAttr(b.hue || "#6f7480")}"></span>
            ${escapeHTML(b.leaf)}<small> · ${escapeHTML(b.stack)}</small>
          </span>`).join("")
      : row.endpoints.filter((e) => !seen.has(e.container) && seen.add(e.container)).map((e) => `
          <span class="who" data-container="${escapeAttr(e.container)}">
            <span class="swatch" style="background: ${escapeAttr(e.hue || "#6f7480")}"></span>
            ${escapeHTML(e.leaf)}${e.hostNetworked
              ? `<small> · host networking, nothing published</small>`
              : `<small> · ${escapeHTML(e.stack || "not on this box")}</small>`}
          </span>`).join("");

    const what = row.endpoints.length
      ? row.endpoints.map((e) => `<span class="what">${escapeHTML(e.title ? `${e.title} — ${e.label}` : e.label)}</span>`).join("")
      : `<span class="what unnamed">unnamed — endpoints.sh declares nothing here</span>`;

    return `
      <tr>
        <td class="port">${escapeHTML(row.port)}<small>/${escapeHTML(row.proto)}</small></td>
        <td class="target">${row.bound.length
            ? escapeHTML([...new Set(row.bound.map((b) => b.target))].join(", "))
            : `<span class="down">not bound</span>`}</td>
        <td class="who-cell">${who || `<span class="down">—</span>`}</td>
        <td>${what}</td>
        <td class="open">${portOpenHTML(row)}</td>
      </tr>`;
  }).join("");

  host.innerHTML = `
    <table class="port-table">
      <thead><tr>
        <th>🔌 Host port</th><th>→ in container</th><th>Container</th>
        <th>What answers on it</th><th>Open</th>
      </tr></thead>
      <tbody>${body}</tbody>
    </table>
    <p class="note wide">${rows.length} port(s) — ${named} named by endpoints.sh, the rest bound by
       docker with nothing declaring what they are. A row with <b>not bound</b> is an address
       endpoints.sh knows and docker publishes no port for: a host-networked node has no Ports
       column to appear in, and a declared endpoint whose stack is down has nothing listening
       yet.</p>`;

  $$("[data-container]", host).forEach((cell) => {
    cell.onclick = () => select(cell.dataset.container);
  });
  $$("[data-copy]", host).forEach((button) => {
    button.onclick = () => navigator.clipboard.writeText(button.dataset.copy);
  });
}

/* ------------------------------------------------------------- detail pane */
function row(key, value, cls = "") {
  return `<div class="row"><span class="k">${escapeHTML(key)}</span><span class="v ${cls}">${value}</span></div>`;
}

function planeHTML(plane) {
  // A container with no app plane gets NO HEADING. Most of the bench has none,
  // and an empty "APP PLANE: none" on each of them is furniture teaching the
  // reader to scroll past the place the answer appears on the ones that do.
  if (!plane) return "";
  let body = "";
  if (plane.source) body += row("Read from", `<a href="${escapeAttr(plane.source)}" target="_blank" rel="noreferrer">${escapeHTML(plane.source)}</a>`, "url");
  if (plane.error)  body += row("Error", escapeHTML(plane.error), "t-hot");

  if (plane.plane === "supervisor" && plane.status) {
    const status = plane.status;
    body += row("Node", escapeHTML(status.node || ""));
    body += row("Status", escapeHTML(status.status || ""));
    body += row("Started", escapeHTML(status.startedAt || ""));
    if (status.broker) body += row("Broker", escapeHTML(`${status.broker.host}:${status.broker.port}`));
    body += `<ul>${(status.agents || []).map((agent) => {
      const word = !agent.enabled ? "disabled" : agent.running ? "running"
                 : agent.everySeconds ? "idle" : "stopped";
      const tone = appTone(word);
      const facts = [
        agent.pid ? `pid ${agent.pid}` : null,
        agent.everySeconds ? `every ${agent.everySeconds}s` : null,
        agent.restarts ? `${agent.restarts} restart(s)` : null,
        agent.lastExitCode !== null && agent.lastExitCode !== undefined ? `last exit ${agent.lastExitCode}` : null,
        agent.restartPolicy ? agent.restartPolicy : null,
      ].filter(Boolean).join(" · ");
      return `<li><span class="t-${tone}${appPulses(word) ? " pulse" : ""}">●</span>
        <b>${escapeHTML(agent.id)}</b> <span class="t-${tone}">${word}</span>
        — ${escapeHTML(agent.title || "")}<br><span class="v dim">&nbsp;&nbsp;&nbsp;${escapeHTML(facts)}</span></li>`;
    }).join("")}</ul>`;
  } else if (plane.plane === "broker") {
    if (plane.uptime) body += row("Uptime", escapeHTML(plane.uptime.human || ""));
    body += `<ul>${(plane.listeners || []).map((l) => {
      const tone = appTone(l.state === "up" ? "running" : "stopped");
      return `<li><span class="t-${tone}">●</span> ${escapeHTML(l.uri)} <span class="t-${tone}">${escapeHTML(l.state)}</span></li>`;
    }).join("")}</ul>`;
    const counters = Object.entries(plane.sys || {});
    if (counters.length) {
      body += counters.map(([k, v]) => row(k, escapeHTML(String(v)), "dim")).join("");
    }
  } else if (plane.plane === "static") {
    if (plane.builtAt) body += row("Image built", escapeHTML(plane.builtAt));
    body += `<ul>${(plane.trees || []).map((tree) => {
      const ok = String(tree.httpCode).startsWith("2");
      const tone = appTone(ok ? "running" : "stopped");
      return `<li><span class="t-${tone}">●</span> <b>${escapeHTML(tree.tree)}</b>
        <span class="t-${tone}">HTTP ${escapeHTML(String(tree.httpCode))}</span><br>
        <a class="v url" href="${escapeAttr(tree.url)}" target="_blank" rel="noreferrer">${escapeHTML(tree.url)}</a></li>`;
    }).join("")}</ul>`;
  }
  return `<h3>🧩 APP PLANE — WHAT IS RUNNING INSIDE</h3>${body}`;
}

/* THE HANDLES — how you talk to this container, in the two ways there are.
 *
 * FETCHED AFTER THE PANE IS PAINTED, not with it. The bus half holds a
 * subscription open for a settle window, and folding that into /api/container
 * would put four seconds between clicking a card and reading its diagnosis. So
 * the pane paints, this says it is listening, and the answer lands underneath.
 *
 * A SECTION THAT SAYS WHY IT IS EMPTY. Every other block in this pane is drawn
 * only when it has content; this one is always drawn, because the whole reason
 * it exists is somebody opening a container and finding no sign of an API. "No
 * routes" and "nobody asked" look identical as a blank space — so the reason
 * comes back from the script as a row and is printed where the rows would be.
 */
function surfaceHTML(surface) {
  const api = surface && surface.api;
  const bus = surface && surface.bus;
  let html = `<h3>🔧 API — HOOKS &amp; HANDLES</h3>`;

  if (!api) {
    html += row("HTTP", "no answer from api.sh for this container.", "dim");
  } else if (!api.routes || !api.routes.length) {
    html += row("HTTP", escapeHTML(api.reason || api.error || "no route table"), "dim");
  } else {
    /* WHERE THEY CAME FROM, ON THE PANE. `declared` is the service's own table,
     * `404` is its refusal read for the paths it names, `self-describing` is an
     * NMOS base path answering with its children. A reader who knows which of
     * the three this was knows how much to trust a missing row. */
    if (api.source) html += row("Read from", `${escapeHTML(api.source)} <span class="dim">(${escapeHTML(api.how || "")})</span>`, "url");
    if (api.note)   html += row("Note", escapeHTML(api.note), "dim");
    html += `<ul class="routes">${api.routes.map((route) => {
      /* A VERB IS NEVER A LINK. `POST /agents/<id>/stop` silences a node's
       * telemetry, and the GET/POST split this whole package is built on would
       * mean nothing if the pane offered the POSTs as things to click. */
      const handle = route.state === "open" && !route.path.includes("<")
        ? `<a class="v url" href="${escapeAttr(route.uri)}" target="_blank" rel="noreferrer">${escapeHTML(route.path)}</a>`
        : `<span class="v">${escapeHTML(route.path)}</span>`;
      return `<li><b class="verb verb-${escapeAttr(route.method.toLowerCase())}">${escapeHTML(route.method)}</b>
        ${handle}${route.what ? `<br><span class="v dim">&nbsp;&nbsp;&nbsp;${escapeHTML(route.what)}</span>` : ""}</li>`;
    }).join("")}</ul>`;
  }

  html += `<h3>📡 BUS — TOPICS THIS CONTAINER PUBLISHES</h3>`;
  if (!bus) {
    html += row("Bus", "no answer from topics.sh for this container.", "dim");
    return html;
  }
  if (bus.error) {
    html += row("Bus", escapeHTML(bus.error), "t-hot");
    return html;
  }
  html += row("Census", `${escapeHTML(bus.broker || "")} · listened ${escapeHTML(String(bus.observedSeconds))}s · ${(bus.topics || []).length} topic(s)`, "dim");
  if (!(bus.topics || []).length) {
    /* MQTT cannot tell a subscriber who published, so this is a real answer and
     * not a failure: nothing that arrived in the window named this container. */
    html += row("Topics", "nothing on the bus named this container as its publisher.", "dim");
    return html;
  }
  html += `<ul class="topics">${bus.topics.map((topic) => {
    const tone = busTone(topic.state);
    return `<li><span class="t-${tone}">●</span> <span class="v">${escapeHTML(topic.topic)}</span>
      <span class="t-${tone}">${escapeHTML(topic.state)}</span><br>
      <span class="v dim">&nbsp;&nbsp;&nbsp;${escapeHTML(topic.messages + " message(s) · " + topic.bytes + " B")}${
        topic.identity ? escapeHTML(` · ${topic.identityField}=${topic.identity}`) : " · nothing in the payload named a publisher"}</span></li>`;
  }).join("")}</ul>`;
  return html;
}

/* WHAT THIS CONTAINER IS, AND WHY THE BENCH NEEDS IT.
 *
 * THE ONLY BLOCK ON THIS PANE THAT IS NOT A MEASUREMENT, and it is drawn FIRST
 * for that reason: everything under it says how the container is, which is not
 * a readable answer to somebody who does not yet know what the container is
 * for. "Broker-SqlCapture is restarting" only means something once you know it
 * is the thing that writes the bus down.
 *
 * A SECTION THAT SAYS WHY IT IS EMPTY, the same rule surfaceHTML() follows. A
 * container with no entry in purpose.sh is printed as exactly that, naming the
 * file, because a missing paragraph and a container nobody has described look
 * identical as a blank space -- and the second one is fixed by writing four
 * lines in one table.
 */
function purposeHTML(purpose, name) {
  let html = `<h3>📘 WHAT THIS CONTAINER IS &amp; WHY IT IS NEEDED</h3>`;
  if (!purpose) {
    return html + row("Purpose",
      `no entry in 'docker scripts/purpose.sh' for ${escapeHTML(name)} — add one there, beside its stack.`,
      "dim");
  }
  html += `<div class="role">${escapeHTML(purpose.role)}</div>`;
  html += `<p class="purpose">${escapeHTML(purpose.what)}</p>`;
  html += `<p class="purpose why"><b>Why it is needed.</b> ${escapeHTML(purpose.why)}</p>`;
  return html;
}

function renderDetail(detail) {
  state.detail = detail;
  $("#detail-title").textContent = `🔍 ${detail.name}`;
  $("#copy-inspect").disabled = false;
  $("#view-script").disabled = !detail.config_path;

  const s = detail.state;
  let html = purposeHTML(detail.purpose, detail.name);
  html += `<h3>🩺 DIAGNOSIS &amp; STATUS</h3>`;
  html += `<div class="diagnosis">${escapeHTML(detail.diagnosis)}</div>`;
  html += row("State", `${escapeHTML(s.status)} | Running: ${s.running} | Exit Code: ${s.exit_code}`);
  html += row("Health", escapeHTML(detail.health) + ` | Restarts: ${s.restarts} | OOM Killed: ${s.oom_killed}`);
  html += row("Created", escapeHTML(detail.created));
  html += row("Image", escapeHTML(detail.image));

  html += planeHTML(detail.plane);

  html += `<h3>🌐 IP ADDRESSES &amp; NETWORKS USED</h3>`;
  if (!detail.networks.length) {
    html += row("Networks", "none", "dim");
  } else {
    // A host-networked container has a Networks entry with an empty IPAddress,
    // and that is correct rather than missing: it has the host's addresses.
    html += detail.networks.map((net) =>
      row(net.name, net.ip ? escapeHTML(net.ip) : "host networking — the host's own addresses",
          net.ip ? "" : "dim")).join("");
  }
  if (detail.mac) html += row("MAC", escapeHTML(detail.mac), "dim");

  html += `<h3>🔌 PORTS IN USE</h3>`;
  html += detail.ports.length
    ? `<ul>${detail.ports.map((p) => `<li>${escapeHTML(p)}</li>`).join("")}</ul>`
    : row("Ports", "none published", "dim");

  html += `<h3>⚙ SERVICES RUNNING &amp; EXECUTABLE COMMANDS</h3>`;
  if (detail.entrypoint.length) html += row("Entrypoint", escapeHTML(detail.entrypoint.join(" ")), "dim");
  if (detail.command.length)    html += row("Command", escapeHTML(detail.command.join(" ")), "dim");

  html += `<h3>📄 WHAT BUILT THIS CONTAINER</h3>`;
  html += row("Config", detail.config_path ? escapeHTML(detail.config_path)
                                           : "config-path.sh could not say.",
              detail.config_path ? "path" : "dim");

  html += `<div id="surface"><h3>🔧 API — HOOKS &amp; HANDLES</h3>
             <p class="empty">Asking ${escapeHTML(detail.name)} what it answers, and listening to the bus…</p></div>`;

  $("#detail").innerHTML = html;
  renderLaunchers(detail);
  loadSurface(detail.name);
}

/* THE SECOND FETCH. Guarded on the selection because the census takes seconds
 * and a person clicking across five cards would otherwise have five answers in
 * flight, each one overwriting the pane of a container they are no longer
 * looking at. */
async function loadSurface(name) {
  let surface = null;
  try {
    surface = await get(`/api/surface/${encodeURIComponent(name)}`);
  } catch (err) {
    surface = { container: name, api: null, bus: { error: String(err.message || err) } };
  }
  if (state.selected !== name) return;
  const host = $("#surface");
  if (host) host.innerHTML = surfaceHTML(surface);
}

function renderLaunchers(detail) {
  const host = $("#launchers");
  const buttons = [];
  for (const endpoint of detail.endpoints) {
    const scheme = endpoint.uri.split("://")[0];
    if (endpoint.kind === "open") {
      buttons.push(`<a class="btn ${scheme === "http" ? "accent" : "plain"} small"
        href="${escapeAttr(endpoint.uri)}" target="_blank" rel="noreferrer">🌐 Open ${escapeHTML(endpoint.label)} (${escapeHTML(endpoint.uri)})</a>`);
    } else {
      // A `mqtt://` or `mysql://` handed to a browser is at best a dialog
      // asking what application to use, so these are copied and never opened.
      buttons.push(`<button class="btn teal small" data-copy="${escapeAttr(endpoint.uri)}">📋 Copy ${escapeHTML(endpoint.label)} (${escapeHTML(endpoint.uri)})</button>`);
    }
  }
  // A published port the endpoint table does not know about — something running
  // beside this ecosystem. Its own page states its name; page-titles.sh fetched
  // and remembered it, so the launcher reads as a place and not as a number.
  for (const port of detail.undeclared) {
    const label = port.title ? `${port.title} (${port.port})` : `Open Port ${port.port}`;
    buttons.push(`<a class="btn plain small" href="${escapeAttr(port.uri)}" target="_blank" rel="noreferrer">🌐 ${escapeHTML(label)}</a>`);
  }

  const verbs = Object.entries(state.actions.container_actions)
    .filter(([key]) => key !== "logs")
    .map(([key, row]) => `<button class="btn plain small" data-cverb="${key}">${escapeHTML(row.label)}</button>`);
  verbs.push(`<button class="btn plain small" data-cverb="logs">📜 Logs</button>`);

  if (detail.name === "Netbox-App") {
    buttons.unshift(`<span class="btn plain small" style="border-color: #ffb74d; color: #ffb74d; font-weight: bold;">🔑 Dev Login: APKaudio / APKaudio1234!</span>`);
  }

  host.hidden = false;
  host.innerHTML = `<span class="lab">🚀 Launchers:</span>${buttons.join("")}
                    <span class="lab">· This container:</span>${verbs.join("")}`;

  $$("[data-copy]", host).forEach((button) => {
    button.onclick = () => navigator.clipboard.writeText(button.dataset.copy);
  });
  $$("[data-cverb]", host).forEach((button) => {
    button.onclick = () => runContainerAction(button.dataset.cverb, detail.name, button);
  });
}

async function select(name) {
  state.selected = name;
  $$(".card").forEach((card) => card.classList.toggle("selected", card.dataset.container === name));
  $("#detail").innerHTML = `<p class="empty">Inspecting ${escapeHTML(name)}…</p>`;
  try {
    renderDetail(await get(`/api/container/${encodeURIComponent(name)}`));
  } catch (err) {
    $("#detail").innerHTML = `<p class="empty t-hot">${escapeHTML(String(err.message || err))}</p>`;
  }
}

/* ---------------------------------------------------------------- cadences */
async function scan({ apps = true, quiet = false } = {}) {
  if (state.scanning) return;
  state.scanning = true;
  if (!quiet) $("#scan-state").textContent = "scanning…";
  try {
    renderGrid(await get(`/api/containers${apps ? "" : "?apps=0"}`));
    $("#scan-state").textContent = new Date().toLocaleTimeString();
    // The pane already open on a container is repainted along with the grid,
    // because the two disagreeing is the thing the follow cadence exists for.
    if (state.selected && !state.busy) {
      get(`/api/container/${encodeURIComponent(state.selected)}?live=1`)
        .then(renderDetail).catch(() => {});
    }
  } catch (err) {
    $("#scan-state").textContent = String(err.message || err);
  } finally {
    state.scanning = false;
  }
}

/* ARMED ON THE WALL CLOCK, NOT ON THE MOMENT THE SELECT CHANGED. Same
 * frequency either way; what the alignment buys is that a 15s scan lands on
 * :00, :15, :30 and :45 — the four tops of the pace clock — so the block of
 * log a scan produces is one colour, and the next one is the next colour. A
 * free-running cadence straddles the quarter and every scan comes out two
 * colours, which reads as two events. A swimmer leaves on the top; so does
 * the bench.
 *
 * ONLY WHEN THE INTERVAL DIVIDES THE MINUTE. 25s does not, so there is no
 * boundary to hold it to and it runs free — an alignment that has to lie
 * about where the boundary is would be worse than none. */
function armScan(seconds) {
  state.scanEvery = seconds;
  clearTimeout(state.scanPhase);
  clearInterval(state.scanTimer);
  state.scanPhase = null;
  state.scanTimer = null;
  if (!seconds) return;

  const run = () => { state.scanTimer = setInterval(() => scan({ quiet: true }), seconds * 1000); };
  if (60 % seconds) { run(); return; }

  // Epoch is on a minute boundary and Unix time has no leap seconds, so the
  // remainder is the distance to the next mark in every time zone.
  const step = seconds * 1000;
  state.scanPhase = setTimeout(() => { scan({ quiet: true }); run(); }, step - (Date.now() % step));
}

/* HOW MUCH OF THE CARD TO DRAW, and it is a CLASS ON THE GRID rather than a
 * branch in cardHTML(). Building three shapes of card would put the density in
 * the markup, so a level change would mean a re-render -- and a re-render of a
 * grid whose meters are 5s old redraws them as "—" until the next tick. The
 * card is always whole; manager.css hides what this level does not want.
 *
 * REMEMBERED, unlike the ⏱ cadence beside it, which resets to 15s every load
 * on purpose because leaving a fast poll armed costs the box something. A
 * detail level costs nothing and is a way of reading rather than a setting, so
 * the manager opens the way you left it. Wrapped because a browser with site
 * data blocked THROWS on the property access, and the grid is not optional. */
const DENSITIES = ["low", "med", "high"];

function applyDensity(level) {
  state.density = DENSITIES.includes(level) ? level : "high";
  $("#cards").className = `cards density-${state.density}`;
  try { localStorage.setItem("apk.manager.density", state.density); } catch { /* no store */ }
}

function savedDensity() {
  try { return localStorage.getItem("apk.manager.density"); } catch { return null; }
}

function armMeters(on) {
  state.meters = on;
  $("#live-resources").classList.toggle("on", on);
  $("#live-resources").textContent = on ? "📈 Live Resources (5s active)" : "📈 Live Resources (CPU / RAM)";
  clearInterval(state.meterTimer);
  state.meterTimer = on
    ? setInterval(() => get("/api/resources").then(applyMeters).catch(() => {}), 5000)
    : null;
}

/* A DEPTH, NOT A FLAG. A stop pressed during a rebuild puts two runs in flight
 * from one tab, and they finish in either order; a boolean meant whichever
 * returned FIRST re-enabled the whole bar while the other was still going. The
 * count is what `state.busy` has always been read for anyway -- everything that
 * tests it wants "is anything running", and a number answers that too. */
function follow(on) {
  state.busy = Math.max(0, (state.busy || 0) + (on ? 1 : -1));
  on = state.busy > 0;
  clearInterval(state.followTimer);
  // apps=0: apps.sh curls a supervisor that is in the middle of being
  // restarted, and waiting on it is what would make this cadence miss its beat.
  state.followTimer = on
    ? setInterval(() => scan({ apps: false, quiet: true }), 2000)
    : null;
  // EVERY BUTTON GOES DARK EXCEPT THE ONES THAT MEAN STOP. Disabling the whole
  // bar was right for a second build and wrong for 🛑 and 🚨: the tab that
  // started the rebuild is the tab whose hand is on it, and greying its stop
  // for the eleven minutes of a build leaves that hand nothing to press.
  // `preempts` comes from the server's action table — see api.action_table().
  $$(".btn[data-action], .btn[data-cverb], .btn[data-saction]").forEach((button) => {
    button.disabled = on && !preempts(button);
  });
  if (!on) scan();
}

function preempts(button) {
  const key = button.dataset.action;
  return Boolean(key && state.actions?.actions?.[key]?.preempts);
}

/* ------------------------------------------------------------------- verbs */
/* WHICH BUTTON IS THE ONE THAT IS RUNNING. follow() greys the whole bar for the
 * length of a verb — it has to, because the server takes ONE action at a time
 * and refuses the second rather than queueing it — and a bar of forty identical
 * dimmed buttons does not say which of them the press went to. Four bands and a
 * toolbar can offer the same verb, so "the page is busy" was the only thing the
 * page said back, and on a build that takes minutes that is indistinguishable
 * from a click that never landed.
 *
 * THE MARK IS ON THE ELEMENT THAT WAS PRESSED, not on the verb: two rows
 * offering `up-stack` for two different stacks are two different presses, and
 * lighting both would be the same lie one size smaller. The stylesheet keeps a
 * `.running` button at full contrast and pulses it while its neighbours dim. */
function markRunning(button, on) {
  if (!button) return;
  button.classList.toggle("running", on);
}

async function runAction(key, button) {
  const row = state.actions.actions[key];
  if (!row) return;
  if (row.confirm && !(await ask(row.label, row.confirm))) return;
  markRunning(button, true);
  follow(true);
  try {
    await post(`/api/action/${encodeURIComponent(key)}`);
  } finally {
    // A STOP AND THE RUN IT CANCELLED FINISH IN EITHER ORDER, and both land
    // here. follow() counts, so the bar comes back when the LAST of them ends.
    markRunning(button, false);
    follow(false);
  }
}

async function runContainerAction(key, name, button) {
  const row = state.actions.container_actions[key];
  if (!row) return;
  if (row.confirm && !(await ask(`${row.label} — ${name}`, row.confirm.replace(/\{name\}/g, name)))) return;
  markRunning(button, true);
  follow(true);
  try {
    await post(`/api/action/${encodeURIComponent(key)}`, { container: name });
  } finally {
    markRunning(button, false);
    follow(false);
  }
}

/* ONE STACK, AND THE NAME IS THE DIRECTORY UNDER APK:DOCKERS/. The bands hold
 * it already — it is the heading of the row the button sits in — so nothing
 * here maps a stack to a compose file; up-stack.sh does that, through the same
 * arrays the bench-wide verbs expand. */
async function runStackAction(key, stack, button) {
  const row = state.actions.stack_actions?.[key];
  if (!row || !stack) return;
  if (row.confirm && !(await ask(`${row.label} — ${stack}`,
                                 row.confirm.replace(/\{name\}/g, stack)))) return;
  markRunning(button, true);
  follow(true);
  try {
    await post(`/api/action/${encodeURIComponent(key)}`, { stack });
  } finally {
    markRunning(button, false);
    follow(false);
  }
}

/* ------------------------------------------------------------------- boot */
function escapeHTML(text) {
  return String(text ?? "").replace(/[&<>]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[ch]));
}
function escapeAttr(text) {
  return escapeHTML(text).replace(/"/g, "&quot;");
}

function wireMenus() {
  $$("[data-menu]").forEach((menu) => {
    const opener = $("[data-menu-open]", menu);
    const items = $(".menu-items", menu);
    opener.onclick = (event) => {
      event.stopPropagation();
      const wasOpen = !items.hidden;
      $$(".menu-items").forEach((other) => { other.hidden = true; });
      items.hidden = wasOpen;
    };
    items.onclick = () => { items.hidden = true; };
  });
  document.addEventListener("click", () => $$(".menu-items").forEach((m) => { m.hidden = true; }));
}

function labelVerbs() {
  // EVERY BUTTON'S WORDS COME FROM THE SERVER. A label typed here would be a
  // second name for a verb whose first name is in api.ACTIONS, and the two
  // would part company the first time one was edited.
  $$("[data-action]").forEach((button) => {
    const row = state.actions.actions[button.dataset.action];
    button.textContent = row ? row.label : button.dataset.action;
    button.onclick = () => runAction(button.dataset.action, button);
  });
  // THE SAME NAMING, ONE RUNG DOWN. A stack verb is drawn only by the bands,
  // never by the toolbar, and it carries the stack it is about on the element
  // — so the label is still the server's and the argument is the row's.
  $$("[data-saction]").forEach((button) => {
    const row = state.actions.stack_actions?.[button.dataset.saction];
    button.textContent = row ? row.label : button.dataset.saction;
    button.onclick = () => runStackAction(button.dataset.saction,
                                          button.dataset.stack, button);
  });
}

/* ONE CLICK IS GRANTED ONE WINDOW, AND THIS MENU HAS SEVEN PAGES IN IT.
 *
 * `open all` was `live.forEach((e) => window.open(e.uri))`. A browser gives a
 * click one window and blocks every one after it as a pop-up, so the button
 * opened the first live page and filed the other four under "Pop-ups blocked"
 * in the omnibox: a launcher that looks broken while it is being obeyed. Two
 * changes, and neither of them asks anybody to allow pop-ups for this origin:
 *
 *   · ONE PAGE IS A LINK, NOT A SCRIPT. `<a target="_blank">` is a navigation
 *     the person made, never a script-opened window, so it is never blocked —
 *     and with no feature string anywhere near it, it is a TAB.
 *   · EVERY PAGE IS ONE WINDOW. `open all` opens a single wall and draws one
 *     iframe per live endpoint into it. That is the whole bench on one screen,
 *     which is what the button was reaching for, and it spends exactly the one
 *     window a click is allowed to spend.
 *
 * A tile that stays blank is a page that refuses to be framed
 * (`X-Frame-Options`, or a `frame-ancestors` policy), which is the server's
 * ruling and not a fault here — so every tile also carries its own address as
 * a link out, and the wall says so in its own header rather than leaving a
 * grey rectangle to be read as a dead container.
 */
function openWebPageWall(live) {
  const wall = window.open("", "_blank");
  if (!wall) return; /* even the one window was refused; there is nothing to draw into */

  /* The wall is written into `about:blank` and inherits no stylesheet, so the
   * furniture greys are handed over by value. The tones stay behind: nothing
   * on this wall reports a state, and palette.py's rule is that a colour
   * meaning a condition has one home. */
  const css = getComputedStyle(document.documentElement);
  const tone = (name, fallback) => (css.getPropertyValue(name) || "").trim() || fallback;

  const tiles = live.map((e) => {
    const name = e.title ? `${e.title} — ${e.label}` : e.label;
    return `
      <section class="tile">
        <header>
          <span class="who">🌐 ${escapeHTML(name)}</span>
          <a href="${escapeAttr(e.uri)}" target="_blank" rel="noreferrer">${escapeHTML(e.uri)} ↗</a>
        </header>
        <iframe src="${escapeAttr(e.uri)}" title="${escapeAttr(name)}" loading="lazy"></iframe>
      </section>`;
  }).join("");

  wall.document.write(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>🚀 ${live.length} live page(s) — APK.audio</title>
<style>
  :root {
    --ground: ${tone("--ground", "#101014")}; --panel: ${tone("--panel", "#16161c")};
    --edge: ${tone("--edge", "#2a2a33")}; --ink: ${tone("--ink", "#e0e0e0")};
    --dim: ${tone("--dim", "#8b93a1")};
    --sans: system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--ground); color: var(--ink); font: 500 12px/1.4 var(--sans); }
  .bar { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap;
         padding: 10px 14px; border-bottom: 1px solid var(--edge); background: var(--panel); }
  .bar strong { font-size: 13px; }
  .bar span { color: var(--dim); font-size: 11px; }
  .wall { display: grid; gap: 10px; padding: 10px;
          grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); }
  .tile { display: flex; flex-direction: column; min-height: 46vh;
          border: 1px solid var(--edge); border-radius: 6px; overflow: hidden; background: var(--panel); }
  .tile header { display: flex; gap: 10px; justify-content: space-between; align-items: baseline;
                 padding: 6px 9px; border-bottom: 1px solid var(--edge); }
  .tile .who { font-weight: 600; }
  .tile a { color: var(--dim); text-decoration: none; font-size: 11px; white-space: nowrap; }
  .tile a:hover { color: var(--ink); text-decoration: underline; }
  .tile iframe { flex: 1; width: 100%; border: 0; background: #fff; }
</style></head>
<body>
  <div class="bar">
    <strong>🚀 ${live.length} live page(s)</strong>
    <span>one window, one frame each · a blank tile is a page that refuses to be framed — its address beside it opens in a tab</span>
  </div>
  <div class="wall">${tiles}</div>
</body></html>`);
  wall.document.close();
  wall.focus();
}

// endpoints.sh is `docker port` and an inspect PER CONTAINER, and both surfaces
// that want it can ask at once -- boot fills the menu while a remembered ports
// view asks for the table. One in flight at a time; the second caller gets the
// first one's answer, which is the same answer a second run would have taken
// seconds to produce.
async function loadWebPages() {
  if (state.endpointsLoading) return state.endpointsLoading;
  const run = loadWebPagesOnce();
  state.endpointsLoading = run;
  try { return await run; } finally { state.endpointsLoading = null; }
}

async function loadWebPagesOnce() {
  const host = $("#web-pages");
  try {
    const { endpoints } = await get("/api/endpoints");
    // ONE FETCH, TWO SURFACES. This menu wants the browsable rows; the port
    // table wants every row, including the `copy` ones a broker answers on.
    // A second call would be the same eight-second script run twice.
    state.endpoints = endpoints;
    if (state.view === "ports") renderPorts();
    const browsable = endpoints.filter((e) => e.kind === "open");
    const live = browsable.filter((e) => e.state === "up");
    host.innerHTML =
      `<button data-open-all>🚀 Open all ${live.length} live page(s) in one window</button><div class="sep"></div>` +
      browsable.map((e) => {
        const name = e.title ? `${e.title} — ${e.label}` : e.label;
        // A `down` endpoint is listed, not opened. Opening it produces a
        // browser error page that reads as a broken site rather than as a
        // stopped container, which is the thing a person is actually looking at.
        return e.state === "up"
          ? `<a href="${escapeAttr(e.uri)}" target="_blank" rel="noreferrer">🌐 ${escapeHTML(name)} — ${escapeHTML(e.uri)}</a>`
          : `<div class="note">⏸️ ${escapeHTML(name)} is ${escapeHTML(e.state)} — ${escapeHTML(e.uri)}</div>`;
      }).join("");
    const all = $("[data-open-all]", host);
    if (all) all.onclick = () => openWebPageWall(live);
  } catch (err) {
    host.innerHTML = `<div class="note">endpoints.sh returned nothing — is docker running?</div>`;
  }
}

async function boot() {
  wireMenus();
  // Before the stream, so the first line to arrive already has a dial to be
  // the colour of.
  buildPaceDial();
  syncPaceClock();
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) syncPaceClock();
  });
  openStream();

  applyPalette(await get("/api/palette"));
  state.actions = await get("/api/actions");
  labelVerbs();
  loadWebPages();

  // NOT `select`: that name is the module-level function the card grid calls to
  // open a container, and shadowing it here is how a click stops working.
  const cadence = $("#auto-refresh");
  // The floor is the server's, asked for rather than typed: a full scan is four
  // scripts against every container on the box and takes a second or two of any
  // gap already.
  [5, 10, 15, 20, 25, 30].forEach((seconds) => {
    const option = document.createElement("option");
    option.value = String(seconds);
    option.textContent = `Auto Refresh: ${seconds}s`;
    cadence.append(option);
  });
  cadence.value = "15";
  cadence.onchange = () => armScan(Number(cadence.value));
  armScan(15);

  const density = $("#density");
  density.value = DENSITIES.includes(savedDensity()) ? savedDensity() : "high";
  density.onchange = () => applyDensity(density.value);
  applyDensity(density.value);

  // REMEMBERED for the same reason the detail level is: which reading of the
  // bench you want is a way of working, not a setting, and it costs the box
  // nothing to come back to it.
  //
  // A RADIO GROUP AND NOT A `<select>` SINCE 2026-09-10, so `#view` is the
  // group and the value lives on whichever input is checked. `change` fires on
  // the input that just BECAME checked and not on the one that lost it, so
  // there is no need to ask which; the group's own name is what deselects the
  // other two. The `checked` in the markup is the cards default, and is
  // overwritten here before the first paint by whatever was remembered.
  const wanted = VIEWS.includes(savedView()) ? savedView() : "cards";
  $$("#view input[name=view]").forEach((radio) => {
    radio.checked = radio.value === wanted;
    radio.onchange = () => applyView(radio.value);
  });
  applyView(wanted);

  // Both halves of the port table: the scan re-reads what docker has bound,
  // and endpoints.sh re-reads what answers on it.
  $("#refresh").onclick = () => { scan(); if (state.view === "ports") loadWebPages(); };
  $("#live-resources").onclick = () => armMeters(!state.meters);
  $("#broadcast").onclick = () => post("/api/broadcast");
  $("#clear-log").onclick = () => post("/api/log/clear");

  $("#chat").onclick = async () => {
    const message = prompt("💬 Say something on APK.audio/System/Chat");
    if (!message) return;
    const result = await post("/api/chat", { message });
    // REPORTED, NOT ACTED ON. Typing `stop` into a chat box used to force-kill
    // the bench with no dialog at all.
    if (result.sounds_like_panic) runAction("panic", $(`.btn[data-action="panic"]`));
  };

  $("#copy-inspect").onclick = () => {
    if (state.detail) sheet(`📋 docker inspect ${state.detail.name}`,
                            JSON.stringify(state.detail.inspect, null, 2));
  };
  $("#view-script").onclick = async () => {
    if (!state.detail) return;
    const file = await get(`/api/config-script/${encodeURIComponent(state.detail.name)}`);
    sheet(`📄 ${file.path || state.detail.name}`, file.text || file.error || "");
  };

  $("#copy-log").onclick = () => {
    // THE TEXT IS ON SCREEN BEFORE THE COPY, and the selection is a FILTER
    // rather than a fixed tail — the lines you want are rarely the last five,
    // and when a rebuild fails they are eight red ones scattered through four
    // hundred. The button this replaces copied silently.
    sheet("📋 Execution log", logText(false), { filter: true });
  };
  $("#sheet-errors-only").onchange = (event) => {
    $("#sheet-body").value = logText(event.target.checked);
  };
  $("#sheet-copy").onclick = () => navigator.clipboard.writeText($("#sheet-body").value);
  $("#sheet-close").onclick = () => $("#sheet").close();

  scan();
}

function logText(errorsOnly) {
  return $$(".l", logBox)
    .filter((line) => !errorsOnly || line.classList.contains("err"))
    .map((line) => line.textContent)
    .join("\n");
}

boot();
