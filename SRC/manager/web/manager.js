// Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
// MIT Licence. Full text in LICENSE at the root.
/* 🧠 The thin half. Ask /api, draw what came back, send a verb when clicked.
 * OWNS rendering, the three cadences and the dialogues. It spells no port, no
 * container name, no docker verb and no state colour: verbs arrive from
 * /api/actions with their own labels and confirm text, addresses from
 * /api/endpoints, colours from /api/palette. */

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/* THREE CADENCES, DIFFERENT WORK (below the first line of code on purpose —
 * check.sh prologue measures the comment run a file OPENS with):
 *   · METERS  /api/resources on 5s while "Live Resources" is armed. Numbers
 *             into cards that already exist; it never creates one.
 *   · SCAN    /api/containers on the ⏱ interval. The whole grid.
 *   · FOLLOW  /api/containers?apps=0 on 2s, only while an action runs, and it
 *             overrides both — a grid titled LIVE may not be suspended by the
 *             one event that invalidates every card on it.
 * NONE OF THEM ACTS: every cadence is a GET, and the server refuses a script
 * that changes the bench over GET. */

const state = {
  palette: null,
  actions: { actions: {}, container_actions: {} },
  selected: null,
  detail: null,
  meters: false,
  density: "high",
  view: "cards",
  // THE LAST SNAPSHOT AND STATS SAMPLE, HELD RATHER THAN RE-ASKED FOR. The
  // donut and the port table are second readings of what the cadences already
  // fetched; re-fetching per switch would be a third cadence on the box.
  snapshot: null,
  resources: {},
  // WHAT THE BOX IS — cores and RAM — held rather than re-read, because it
  // arrives on whichever cadence answered last and the rings need it on both.
  // 0 means the server has not said; renderDonuts() then draws a different CPU
  // ring rather than guessing a denominator.
  hostCpus: 0,
  hostMemory: 0,
  endpoints: [],
  scanEvery: 0,
  scanTimer: null,
  scanPhase: null,  // the one-shot that walks the scan onto a pace-clock mark
  autoRebuildTimer: null,
  autoRebuildSeconds: 30,
  autoRebuildKey: null,
  autoRebuildCancelled: false,
  meterTimer: null,
  followTimer: null,
  busy: 0,          // a DEPTH of runs in flight, not a flag -- see follow()
  scanning: false,
  // SCROLL THE READING BACK TO ITS FIRST ROW ON THE NEXT PAINT. Set by a verb,
  // consumed once by renderGrid(). The scrollport is #grid-body and every view
  // draws INSIDE it (overflow: visible), so a repaint does not rewind it the
  // way replacing the contents of a scroller would: pressing 💥 Free Every
  // Published Port while scrolled to 3211 left the refreshed table sitting at
  // 3211, and the rows the verb actually changed were above the fold.
  rewind: false,
};

/* --------------------------------------------------------------- transport */
/* WHERE /api IS, WORKED OUT RATHER THAN SPELLED. Every route is written the way
 * the manager server answers it and resolved against the directory this page
 * was served from. At an origin root that changes nothing; under a prefix
 * (APK:OS relays the manager at /manager/) it is the difference between
 * working and asking the OS for a route it has never heard of.
 * THE PREFIX IS NOT CONFIGURED AND MUST NOT BECOME CONFIGURABLE: it is read off
 * document.baseURI, so the page is correct wherever it is mounted. */
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

/* Same rule, second vocabulary: live / retained / departed are topics.sh words
 * and palette.py owns what each looks like. */
const busTone = (word) =>
  (state.palette && state.palette.bus_state_tones[word]) || "unknown";

/* ------------------------------------------------------------------ the log
 * A BAR IS ONE LINE REDRAWN, NOT A NEW ONE. brief.LogBrief on the server sends
 * `bar` where it means overwrite and `bardone` where it means overwrite once
 * more and freeze. Holding the element is the whole trick. */
const logBox = $("#log");
let liveBar = null;

function logRecord(record) {
  if (record.kind === "clear") { logBox.textContent = ""; liveBar = null; return; }

  const pinned = logBox.scrollTop + logBox.clientHeight >= logBox.scrollHeight - 24;

  if (record.kind === "bar" || record.kind === "bardone") {
    if (!liveBar) {
      liveBar = document.createElement("span");
      // Stamped when the bar STARTS and never restamped: it is one line being
      // overwritten, so a bar that changed colour under a build would be
      // reporting the clock rather than the build.
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
  // Only when the reader was already at the bottom: scrolling a log somebody
  // scrolled UP takes away what they were reading.
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
 * A SWIM PACE CLOCK, AND THE LOG READS OFF IT. Four hands fifteen seconds apart
 * on a 60-at-the-top dial; the one at the top is the colour every log line
 * takes as it arrives, so the ink says which quarter of the minute each block
 * of output landed in.
 * SYNCHRONISED TO THE WALL CLOCK, which a CSS animation is not: an
 * unsynchronised dial has red at the top at an arbitrary moment and the log
 * colour would mean nothing outside one tab. A negative animation-delay of each
 * offset PLUS the seconds already elapsed puts red on top at :00 in every tab,
 * and makes the log colour a pure function of the second of the minute.
 * NO TIMER: phase is set once here and once when the tab returns to the front
 * (a backgrounded tab may have had its animations throttled). */
const LANES = [
  // `top` is the second of the minute at which this hand is at 60, which makes
  // it both the hand phase and the quarter it owns. One table, both jobs.
  { colour: "orange", top:  0 },
  { colour: "yellow", top: 15 },
  { colour: "green",  top: 30 },
  { colour: "blue",   top: 45 },
];

/* THE QUARTER A LINE BELONGS TO IS THE SERVER `at`, NOT THE MOMENT THIS TAB
 * DREW IT. Every record carries the epoch second it was written and the ring
 * replays its backlog to every tab, so a browser-clock colour would paint four
 * hundred lines of history in one colour and two tabs would disagree about the
 * same line. Epoch is on a minute boundary, so the remainder is the seconds. */
const paceQuarter = (at = Date.now() / 1000) => Math.floor((at % 60) / 15);

/* 120 ticks and 12 numerals, drawn rather than typed: a mark per second and a
 * shorter one per half-second is the density that makes a hand between two
 * marks readable at a glance instead of countable. */
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
    // -90° so that 60 lands at the top rather than at three o clock.
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
    // minute turns over — the offset it needs to reach 60 at `top`.
    if (hand) hand.style.animationDelay = `-${((60 - lane.top) % 60) + intoMinute}s`;
  }
  const minute = $("#pace-minute-hand");
  if (minute) minute.style.animationDelay = `-${now.getMinutes() * 60 + intoMinute}s`;
}

/* ------------------------------------------------------------------ dialogs */
/* ONE DIALOG ELEMENT, REUSED, WHICH IS WHY EVERY FIELD IS RESET ON THE WAY IN.
 * `verify` is a word that must be TYPED before the go button arms — the third
 * ask of ☢️ NUKE EVERYTHING, where the risk is not a misread sentence but a
 * hand already in the rhythm of clicking "Do it".
 * returnValue IS SET TO "no" BEFORE EVERY OPEN. Escape closes a <dialog>
 * without touching returnValue, so the string left behind by the last press is
 * still there — a person who pressed "Do it" once and then dismissed a later
 * dialog with Escape would have been answering yes. */
function ask(title, body, { verify = null } = {}) {
  return new Promise((resolve) => {
    const dialog = $("#ask");
    const input = $("#ask-verify");
    const yes = $("#ask-yes");
    $("#ask-title").textContent = title;
    $("#ask-body").textContent = body;
    $("#ask-verify-word").textContent = verify || "";
    $("#ask-verify-wrap").hidden = !verify;
    input.value = "";
    // The button SAYS the word it is waiting for, so the dimmed state reads as
    // "not yet" rather than as a broken dialog.
    yes.textContent = verify ? `☢️ ${verify}` : "Do it";
    yes.disabled = Boolean(verify);
    input.oninput = verify
      ? () => { yes.disabled = input.value.trim().toUpperCase() !== verify; }
      : null;
    // ENTER DOES NOTHING HERE, AND THAT IS THE POINT. The form is
    // method="dialog", so a bare Enter submits its FIRST button — Cancel —
    // and somebody who typed the word and pressed Enter would be told nothing
    // and see the dialog vanish. Neither answer is right for a keystroke that
    // was aimed at a text field: the armed button is the only way through.
    input.onkeydown = (event) => { if (event.key === "Enter") event.preventDefault(); };
    dialog.returnValue = "no";
    dialog.onclose = () => {
      input.oninput = null;
      input.onkeydown = null;
      resolve(dialog.returnValue === "yes");
    };
    dialog.showModal();
    if (verify) input.focus();
  });
}

/* ASK EVERY QUESTION THE SERVER ATTACHED TO THIS VERB, IN ORDER. A `no` or an
 * Escape at any of them is the end of it — nothing is sent.
 * WHY MORE THAN ONE ASK IS NOT JUST A LOUDER ONE: the three nuke dialogs are
 * three different facts (the containers, then the DATA, then the minutes it
 * costs to come back), and a person who would stop at the second is not
 * protected by a longer first. The count is drawn in the title so the dialogs
 * are not mistaken for one that failed to close. */
async function askAll(row) {
  const confirms = row.confirms?.length ? row.confirms
                 : (row.confirm ? [row.confirm] : []);
  for (let step = 0; step < confirms.length; step += 1) {
    const last = step === confirms.length - 1;
    const title = confirms.length > 1
      ? `${row.label} — ask ${step + 1} of ${confirms.length}`
      : row.label;
    // The typed word guards the LAST ask only: asking for it three times
    // teaches the hand to type it, which is the opposite of the point.
    if (!(await ask(title, confirms[step], { verify: last ? row.verify : null }))) {
      return false;
    }
  }
  return true;
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
 * because that is what a subscriber can compare; a person wants "3.2h". Two
 * surfaces render this, on the same thresholds staleness.sh human() uses. */
function behind(s) {
  return s < 90 ? `${s}s`
    : s < 5400 ? `${Math.round(s / 60)}m`
    : s < 172800 ? `${(s / 3600).toFixed(1)}h`
    : `${(s / 86400).toFixed(1)} days`;
}

function cardHTML(container) {
  const r = container.resources || {};
  const dot = `<span class="dot t-${container.tone}${container.pulse ? " pulse" : ""}">●</span>`;

  // ON THE CARD, because that is where a person is looking when they decide
  // whether to trust what they see: every other field about a stale container
  // is green and correct, so the one fact that contradicts them rides here.
  // ONLY "yes" DRAWS: a missing `staleness` means NOT ASKED (the fast cadence
  // skips the reader), `unbuilt` is the dark band news one step earlier, and
  // `unknown` is the reader declining — violet for either would put a colour
  // meaning "we do not know" on the grid, which is what grey already means.
  const verdict = container.staleness;
  const isStale = !!verdict && verdict.stale === "yes";
  // NOT A TONE SWAP: container.tone still answers "how is this container
  // doing" and a stale one is usually fine. Violet is a second, separate line,
  // and the border says which card to look at from across the room.
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

  const repoLookup = {
    "Broker-Mosquitto": { name: "apk-mqtt-broker", path: "file:///home/anthony/Documents/GitProjects/apk-mqtt-broker" },
    "Broker-SqlCapture": { name: "apk-mqtt-broker", path: "file:///home/anthony/Documents/GitProjects/apk-mqtt-broker" },
    "Storage-Broker": { name: "apk-sql-database", path: "file:///home/anthony/Documents/GitProjects/apk-sql-database" },
    "Storage-MariaDB": { name: "apk-sql-database", path: "file:///home/anthony/Documents/GitProjects/apk-sql-database" },
    "Storage-PHP": { name: "apk-sql-database", path: "file:///home/anthony/Documents/GitProjects/apk-sql-database" },
    "Storage-Portal": { name: "apk-sql-database", path: "file:///home/anthony/Documents/GitProjects/apk-sql-database" },
    "Storage-Schema-Init": { name: "apk-sql-database", path: "file:///home/anthony/Documents/GitProjects/apk-sql-database" },
    "NMOS-Registry": { name: "apk-nmos-discovery", path: "file:///home/anthony/Documents/GitProjects/apk-nmos-discovery" },
    "NMOS-Node": { name: "apk-nmos-discovery", path: "file:///home/anthony/Documents/GitProjects/apk-nmos-discovery" },
    "NMOS-Sandbox": { name: "apk-nmos-discovery", path: "file:///home/anthony/Documents/GitProjects/apk-nmos-discovery" },
    "APK-NMOS-Bridge": { name: "apk-nmos-discovery", path: "file:///home/anthony/Documents/GitProjects/apk-nmos-discovery" },
    "Ember-Provider": { name: "apk-ember-server", path: "file:///home/anthony/Documents/GitProjects/apk-ember-server" },
    "Ember-Docs": { name: "apk-ember-server", path: "file:///home/anthony/Documents/GitProjects/apk-ember-server" },
    "Netbox-App": { name: "apk-netbox-server", path: "file:///home/anthony/Documents/GitProjects/apk-netbox-server" },
    "Netbox-Postgres": { name: "apk-netbox-server", path: "file:///home/anthony/Documents/GitProjects/apk-netbox-server" },
    "Netbox-Valkey": { name: "apk-netbox-server", path: "file:///home/anthony/Documents/GitProjects/apk-netbox-server" },
    "Netbox-Valkey-Cache": { name: "apk-netbox-server", path: "file:///home/anthony/Documents/GitProjects/apk-netbox-server" },
    "Netbox-Worker": { name: "apk-netbox-server", path: "file:///home/anthony/Documents/GitProjects/apk-netbox-server" },
    "DockTor": { name: "apk-docktor", path: "file:///home/anthony/Documents/GitProjects/apk-docktor" },
    "AES70-Dev": { name: "apk-protocol-aes70", path: "file:///home/anthony/Documents/GitProjects/apk-protocol-aes70" },
    "AES70-Site": { name: "apk-protocol-aes70", path: "file:///home/anthony/Documents/GitProjects/apk-protocol-aes70" },
    "Node-BareMetal": { name: "apk-baremetal", path: "file:///home/anthony/Documents/GitProjects/apk-baremetal" },
    "apk-yo": { name: "apk-yo", path: "file:///home/anthony/Documents/GitProjects/apk-yo" },
    "Portal-Broker": { name: "apk-webportal", path: "file:///home/anthony/Documents/GitProjects/apk-webportal" },
    "Portal-Heartbeat": { name: "apk-webportal", path: "file:///home/anthony/Documents/GitProjects/apk-webportal" }
  };

  const repo = repoLookup[container.name];
  if (repo) {
    lines.push(`🐙 repo: ${repo.name} (${repo.path})`);
  }

  // NOT an idle container: a host-networked container has no veth, so docker
  // stats has nothing to count and prints 0B / 0B forever. Said on the meter,
  // or that zero reads as a node that stopped talking.
  // THE STATE EMOJI AND ITS SENTENCE ARE TWO SPANS, which is what lets the
  // folded card keep the first and drop the second: at `low` density the
  // stylesheet keeps the emoji at twice the type size and hides the words, so
  // nothing here changes per density.
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

/* WHAT NO CARD IS ABOUT. The two bands below are about containers — one
 * missing, one lying. This one is about the BOX, and about the container that
 * is still here and stopped, because those had nowhere to go.
 * On 2026-09-09 the root filesystem filled and nothing here said so: every
 * writer failed in the same minute, MariaDB crash-looped, three NetBox
 * containers exited 1 and were down for hours. The stack was not dark, so the
 * band below drew nothing and the disk was never on this page at all.
 * IT IS HIDDEN ON A HEALTHY BENCH, AND THAT IS THE POINT: a meter always drawn
 * is a meter nobody reads; a band that appears is an event. The threshold is
 * the SERVER (readers.DISK_WARNING_PERCENT) and arrives as `level`. */
function renderBenchHealth(snapshot) {
  const host = $("#bench-health");
  const disk = (snapshot.host && snapshot.host.disk) || {};
  // MID-ACTION SUPPRESSION FOR THE STOPPED HALF ONLY: a rebuild stops
  // containers on its way through, so naming them during one is naming the
  // happy path — while a disk 96% full is exactly as true mid-rebuild, and a
  // rebuild is when it is most likely to end the build.
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

/* WHAT THE GRID CANNOT DRAW. Every card is a container that exists, so a stack
 * whose containers were all removed has no card — and on a page made of cards
 * an absence and a thing that was never here are the same picture.
 * THE TWO KINDS ARE NOT THE SAME NEWS, which is why `restorable` is on the
 * wire: a dark stack this tool DRIVES is a remount that did not take, so the
 * row carries the button; one it does not drive is down until a person runs the
 * command, so the row carries the command.
 * AND THE BUTTON IS SCOPED TO ITS ROW. It used to be `up` — the whole bench —
 * under a heading naming ONE stack, and on the row this band draws most often
 * it rebuilt every stack EXCEPT that one, because for_each_stack does not drive
 * the manager compose file. */
function renderDarkStacks(snapshot) {
  const host = $("#dark-stacks");
  const dark = snapshot.dark_stacks || [];
  host.hidden = !dark.length;
  if (!dark.length) { host.innerHTML = ""; return; }

  // THE REASON IS SAID ONCE, ABOVE THE ROWS; the rows carry only what differs.
  // Three stacks each repeating one paragraph filled half the pane and pushed
  // the containers that ARE running below the fold.
  const stranded = dark.filter((row) => !row.restorable);
  // A DRIVEN STACK IS SUPPOSED TO BE DARK MID-REBUILD. `action_running` is the
  // server ACTION_LOCK, so this holds for a rebuild started in another tab too,
  // and follow(false) rescans when the verb finishes — a stack still dark then
  // is the real finding. The stranded rows stay visible throughout.
  const driven = snapshot.action_running ? [] : dark.filter((row) => row.restorable);
  // THE PAGE HAS TO BE ABLE TO ACCUSE ITSELF, and this is the case where the
  // answer sits in front of the reader: the manager runs network_mode: host, so
  // a terminal manager and the containerised one contend for the SAME
  // 127.0.0.1:8765 and the terminal one wins by being first, which after a
  // panic it always is. The container cannot bind, DockTor shows dark-and-
  // driven, and the log truthfully says the remount succeeded. `manager` on the
  // snapshot is who is serving THIS page.
  const servedBy = snapshot.manager || {};
  const selfHeld = servedBy.containerised === false &&
        driven.some((row) => row.stack === "DockTor");
  // A ROW THAT NAMES A FAULT THIS PAGE CAN FIX CARRIES THE FIX. The driven rows
  // used to end at "read the execution log" — a diagnosis handed to somebody
  // already looking at the one screen that could act on it. `data-action` is
  // the same wiring the toolbar uses, so the label is the SERVER and follow()
  // greys this one with the rest.
  // The stranded rows get a command instead: no verb here drives those compose
  // files, so a button would be one that cannot work.
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

  // The verbs are named by the server, so the buttons just planted are
  // labelled and wired here. Guarded: the first grid can land before
  // /api/actions answers.
  if (state.actions) labelVerbs();
}

/* WHAT THE GRID DRAWS WRONG. The band above covers the container that is not
 * there; this covers the one that IS there and is lying. A stale image runs,
 * answers its health check, moves its meters and draws a green card while the
 * code inside it was replaced hours ago. The card carries the verdict too, and
 * this band stays anyway: a fact on one tile among forty has to be FOUND. The
 * band is the count and the newest file; the card is where the finding lands.
 * SUPPRESSED MID-ACTION for the reason the driven dark rows are: a rebuild in
 * flight makes this change under the reader, and a warning that fires on the
 * happy path is learnt as noise. */
function renderStaleImages(snapshot) {
  const host = $("#stale-images");
  const stale = snapshot.action_running ? [] : (snapshot.stale_services || []);

  if (!stale.length) {
    if (state.autoRebuildTimer) {
      clearInterval(state.autoRebuildTimer);
      state.autoRebuildTimer = null;
    }
    state.autoRebuildKey = null;
    state.autoRebuildCancelled = false;
    state.autoRebuildSeconds = 30;
    host.hidden = true;
    host.innerHTML = "";
    return;
  }

  host.hidden = false;

  const currentKey = stale.map((r) => r.container || r.service || r.image).sort().join(",");
  if (state.autoRebuildKey !== currentKey) {
    state.autoRebuildKey = currentKey;
    state.autoRebuildSeconds = 30;
    state.autoRebuildCancelled = false;
    if (state.autoRebuildTimer) {
      clearInterval(state.autoRebuildTimer);
      state.autoRebuildTimer = null;
    }
  }

  if (!state.autoRebuildTimer && !state.autoRebuildCancelled && !snapshot.action_running) {
    state.autoRebuildTimer = setInterval(() => {
      if (snapshot.action_running || state.autoRebuildCancelled) {
        clearInterval(state.autoRebuildTimer);
        state.autoRebuildTimer = null;
        return;
      }
      state.autoRebuildSeconds -= 1;
      const countEl = $("#stale-timer-count");
      if (countEl) {
        countEl.textContent = `${state.autoRebuildSeconds}`;
      }
      if (state.autoRebuildSeconds <= 0) {
        clearInterval(state.autoRebuildTimer);
        state.autoRebuildTimer = null;
        const btn = $('button[data-action="rebuild-all"]') || $("#stale-rebuild-now");
        runAction("rebuild-all", btn, true);
      }
    }, 1000);
  }

  host.innerHTML = `
    <div class="dark-stack stale auto-rebuild-banner" style="background: rgba(239, 68, 68, 0.15); border: 1px solid #ef4444; margin-bottom: 15px; padding: 14px 18px; border-radius: 8px;">
      <div style="display: flex; align-items: center; justify-content: space-between; gap: 15px; flex-wrap: wrap;">
        <div>
          <h3 style="margin: 0; font-size: 1.15em; color: #f87171; display: flex; align-items: center; gap: 8px;">
            <span>⚡ Vigilant Auto-Rebuild Scheduled</span>
            ${!state.autoRebuildCancelled ? `
              <span style="background: #ef4444; color: #fff; padding: 2px 8px; border-radius: 12px; font-size: 0.85em; font-weight: bold;">
                <span id="stale-timer-count">${state.autoRebuildSeconds}</span>s countdown
              </span>
            ` : `
              <span style="background: #6b7280; color: #fff; padding: 2px 8px; border-radius: 12px; font-size: 0.85em; font-weight: bold;">
                PAUSED
              </span>
            `}
          </h3>
          <p style="margin: 4px 0 0 0; font-size: 0.9em; opacity: 0.95;">
            ${!state.autoRebuildCancelled ? 
              `DockTor detected <b>${stale.length} stale container${stale.length > 1 ? "s" : ""}</b> running older code. Automatic rebuild &amp; remount will execute when timer expires.` :
              `Automatic rebuild has been paused by user. Click <b>Rebuild Now</b> to execute rebuild.`
            }
          </p>
        </div>
        <div style="display: flex; gap: 8px;">
          <button id="stale-rebuild-now" class="btn small violet" style="white-space: nowrap;">⚡ Rebuild Now</button>
          ${!state.autoRebuildCancelled ? `
            <button id="stale-cancel-timer" class="btn small dark" style="white-space: nowrap;">⏸ Cancel Countdown</button>
          ` : `
            <button id="stale-resume-timer" class="btn small dark" style="white-space: nowrap;">▶ Resume Countdown</button>
          `}
        </div>
      </div>
    </div>
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

  const nowBtn = $("#stale-rebuild-now", host);
  if (nowBtn) {
    nowBtn.onclick = () => {
      if (state.autoRebuildTimer) {
        clearInterval(state.autoRebuildTimer);
        state.autoRebuildTimer = null;
      }
      state.autoRebuildCancelled = true;
      runAction("rebuild-all", nowBtn, true);
    };
  }

  const cancelBtn = $("#stale-cancel-timer", host);
  if (cancelBtn) {
    cancelBtn.onclick = () => {
      if (state.autoRebuildTimer) {
        clearInterval(state.autoRebuildTimer);
        state.autoRebuildTimer = null;
      }
      state.autoRebuildCancelled = true;
      renderStaleImages(snapshot);
    };
  }

  const resumeBtn = $("#stale-resume-timer", host);
  if (resumeBtn) {
    resumeBtn.onclick = () => {
      state.autoRebuildCancelled = false;
      state.autoRebuildSeconds = 30;
      renderStaleImages(snapshot);
    };
  }

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
  // EVERY CARD METERS, INTO THE ONE MAP THE OTHER VIEWS READ. The scan carries
  // a stats sample of its own, so the donut is live on the ⏱ cadence with the
  // five-second one disarmed — just slower.
  for (const group of snapshot.groups || []) {
    for (const container of group.containers) {
      if (container.resources) state.resources[container.name] = container.resources;
      else delete state.resources[container.name];
    }
  }
  // NEVER BACK TO ZERO. A scan that could not reach docker still returns a
  // document with host.cpus 0; letting that overwrite a count we have would
  // take the idle wedge off the ring for one tick and put the caption back,
  // which reads as the page changing its mind about the box.
  if (snapshot.host && snapshot.host.cpus) state.hostCpus = snapshot.host.cpus;
  if (snapshot.host && snapshot.host.memory_bytes) state.hostMemory = snapshot.host.memory_bytes;
  renderBenchHealth(snapshot);
  renderDarkStacks(snapshot);
  renderStaleImages(snapshot);
  const host = $("#cards");
  if (!snapshot.count) {
    // AND THE BAND IS ALREADY DRAWN, above this guard on purpose: an empty
    // bench is exactly when "which stacks are missing" is the only question,
    // and returning earlier would answer it with one grey sentence.
    host.innerHTML = `<p class="empty">No containers. Mount the stack to see them here.</p>`;
    return;
  }
  // THE STACK IS DRAWN ONCE AND COLOURED THROUGHOUT. `--group` is set on the
  // heading and the block of cards under it, and the stylesheet spends it on
  // the heading text and each card left edge — never on the dot, the status,
  // the meters or the app rows, which are the state tones and must keep
  // meaning health. The colour comes from palette.py with the rest.
  host.innerHTML = snapshot.groups.map((group) => {
    const hue = ` style="--group: ${escapeAttr(group.hue || "")}"`;
    return `
    <div class="group-head${group.ours ? " ours" : ""}"${hue}>${escapeHTML(group.label)} · ${group.containers.length}</div>
    <div class="group"${hue}>${group.containers.map(cardHTML).join("")}</div>`;
  }).join("");

  $$(".card", host).forEach((card) => {
    card.onclick = (event) => {
      // ANY BUTTON ON THE TILE, not just the ✕: a list of exempt attributes
      // is a list that goes stale the third time.
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
  // THE FIX WHERE THE FINDING IS. The band above is the COUNT — how a stale
  // container gets found among forty; this is how it gets acted on without
  // scrolling back up. Same server verb, same one-at-a-time lock.
  $$("[data-rebuild]", host).forEach((button) => {
    const row = state.actions && state.actions.container_actions.rebuild;
    button.textContent = row ? row.label : "rebuild";
    button.onclick = (event) => {
      event.stopPropagation();
      runContainerAction("rebuild", button.dataset.rebuild, button);
    };
  });
  renderViews();
  // AFTER THE PAINT, ONCE. The first scan to land after a verb is the answer to
  // that verb, and it is read from the top: a list still parked where the
  // reader left it looks like the list that was there before.
  if (state.rewind) rewindPane();
}

/* THE ONE PLACE THE READING IS SCROLLED BY THE PAGE rather than by the person.
 * Clears the flag whether or not the scrollport is there, so a paint before
 * boot cannot leave a rewind armed for whatever happens to repaint next. */
function rewindPane() {
  state.rewind = false;
  const body = $("#grid-body");
  if (body) body.scrollTop = 0;
}

/* METERS ONLY, into cards that already exist. Building a card from a stats
 * sample would make one with no status, ports or image. */
function applyMeters(resources) {
  state.resources = resources.containers;
  if (resources.host && resources.host.cpus) state.hostCpus = resources.host.cpus;
  if (resources.host && resources.host.memory_bytes) state.hostMemory = resources.host.memory_bytes;
  // The ring is the same sample, so it moves on the same tick. REBUILT rather
  // than written into: a donut geometry is its data.
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
 * THREE READINGS OF ONE SNAPSHOT, AND ONLY THE CARDS ARE A GRID. Everything
 * below is drawn from state.snapshot and state.resources — no view fetches
 * anything of its own except the endpoint table, which is a join the docker
 * half cannot supply. Switching view HIDES #cards rather than emptying it, so
 * the meter cadence keeps writing into them and coming back is a toggle.
 * WHY EITHER EXISTS: a card grid answers "how is this container" forty times
 * and cannot be read for the two questions asked at a broken bench — WHO IS
 * EATING THE BOX (a comparison ACROSS cards, so it exists on none of them) and
 * WHAT IS ON 8080. */
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
  // THE SCROLL OFFSET BELONGS TO THE READING YOU LEFT. One scrollport holds all
  // three, so card forty and port row forty are the same number of pixels down
  // and nothing else would put the new reading at its own first row.
  rewindPane();
  // The docker half of the port table rides the scan cadence; the endpoint
  // half is endpoints.sh — docker port plus an inspect per container — and is
  // far too expensive to put on a cadence. Re-read on arrival instead.
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
 * DOCKER PRINTS TWO UNIT TABLES IN ONE ROW AND THEY ARE NOT THE SAME TABLE:
 * MemUsage is binary (`12.5MiB / 7.66GiB`) and NetIO is decimal (`1.2MB`).
 * Both are read here, so both are in the map — a parser that knew only powers
 * of 1024 would report the network 5% low, which nobody catches by looking. */
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
/* THE SLICES ARE THE STACK COLOUR, not a colour of this file: `hue` comes down
 * per group from palette.hues_for(), the same table the group headings and card
 * edges spend. Members of one stack are separated by OPACITY rather than by a
 * hue of their own — four Netbox containers in four unrelated colours hide the
 * fact that Netbox is the answer. */
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
 * the reading that survives a bench this size, and the tail is kept as a slice
 * rather than dropped: a ring whose slices do not add up to its own centre
 * number is worse than one with a grey wedge in it. */
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
    // A HAIRLINE, NOT A ROUND CAP: two touching slices of one stack hue read as
    // one slice, and stroke-linecap: round separates them by overlapping the
    // neighbour, which moves the boundary rather than showing it.
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

  // COUNTED BEFORE THE ROLL-UP, drawn after it: the heading says how many
  // containers are in the total, and the ring names ten and sums the rest.
  // Counting drawn slices reported eleven containers on a bench of twenty-four,
  // and the eleventh was the word "more".
  const cpuAll = sliceRows((row) => percent(row.cpu_percent));
  const ramAll = sliceRows((row) => bytes((row.memory || "").split("/")[0]));
  const cpu = rollUpTail(cpuAll);
  const ram = rollUpTail(ramAll);
  const cpuTotal = cpuAll.reduce((sum, row) => sum + row.value, 0);
  const ramTotal = ramAll.reduce((sum, row) => sum + row.value, 0);

  // THE IDLE HALF, drawable because something now carries the core count.
  // Every slice above is in docker units, where one fully busy core is 100%, so
  // the box in those units is cores × 100 and the wedge is the subtraction.
  // state.hostCpus is the daemon own NCPU — NOT nproc and not the browser
  // hardwareConcurrency, which answer about the wrong machine. Zero means the
  // server has not said, and the ring falls back to the containers share of
  // each other, captioned.
  const cores = state.hostCpus;
  const boxCPU = cores * 100;
  // AND IT IS NOT CALLED "IDLE": everything on this box that is not in a
  // container — the desktop, a cargo build, a terminal manager — is inside this
  // wedge, and docker can see none of it.
  const spare = Math.max(boxCPU - cpuTotal, 0);
  const cpuRing = cores
    ? [...cpu, {name: "", leaf: "not in containers", stack: "", hue: "#6f7480",
                // `rolled` is the legend DIM-AND-UNCLICKABLE style, for the
                // reason the tail needs it: not a container you can open.
                shade: 1, value: spare, rolled: true}]
    : cpu;
  const boxShare = boxCPU ? (cpuTotal / boxCPU) * 100 : 0;
  // THE HOST OWN RAM, ASKED FOR FIRST AND INFERRED ONLY IF NOBODY ANSWERED.
  // The inference alone was: docker reports an UNCONSTRAINED container limit as
  // the whole machine memory, so the widest limit in the sample IS the box —
  // which holds only while nothing sets a limit. One mem_limit: makes it a
  // CONTAINER limit, and the ring then divides by 2 GiB on a 32 GiB box and
  // calls an idle bench 60% full with nothing on screen to say it moved.
  // state.hostMemory is the daemon own MemTotal, which no compose file shifts.
  // THE INFERENCE STAYS as the fallback for a docker info that will not answer.
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
/* WHAT IS ON 8080, AS A JOIN OF THE TWO HALVES THAT EACH KNOW HALF OF IT:
 *   · docker knows every port it has BOUND, and nothing about what answers.
 *   · endpoints.sh knows what answers and under which scheme, and it is the
 *     one copy of that table.
 * NEITHER IS SUFFICIENT ALONE, and the shortfalls are not symmetric: a bound
 * port with no endpoint row is a number with no name, while an endpoint row
 * with no bound port cannot exist at all in a table built from docker ps — the
 * BareMetal supervisor on 8100 runs network_mode: host and publishes nothing.
 * So rows are keyed on the PORT and both sides may create one.
 * A RANGE IS N PORTS, AND THE JOIN ONLY LANDS IF IT IS DRAWN AS N ROWS: docker
 * ps folds a consecutive publication into `3209-3211 → 3209-3211/tcp` while
 * endpoints.sh correctly names three different NMOS APIs. Kept folded, the
 * table drew an unnamed range row beside three named rows each saying "not
 * bound" — wrong on both halves at once.
 * SIXTY-FOUR IS THE CEILING and not a tuning knob: a container publishing
 * 1-65535 would otherwise fill this pane with sixty-five thousand rows. */
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
            // port is the nth container port. A pair of ranges of different
            // lengths is not something docker prints; if one arrives, the whole
            // range is said rather than a wrong pairing.
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
    // THE AUTHORITY, PARSED THE WAY api.undeclared_ports() PARSES IT and not
    // with `new URL`: half of these are mqtt:// and mysql://, and one carries
    // credentials whose FIRST colon-and-digits is not a port. Same three steps
    // as the server — what is between :// and the next /, drop anything before
    // an @, and the port is what follows the last colon. [::1]:8080 survives.
    const authority = ((endpoint.uri || "").split("://")[1] || "").split("/")[0].split("@").pop();
    const found = authority.includes(":") ? /^(\d+)$/.exec(authority.split(":").pop()) : null;
    if (!found) continue;
    const known = byName[endpoint.container];
    // The proto is the row, not the endpoint: an endpoint is named for a port
    // docker bound over TCP, and a second `8080/` row would split the one fact
    // the table exists to state.
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
    // LISTED, NOT OPENED, the Web Pages menu rule: a stopped container behind
    // a link produces a browser error page, which reads as a broken SITE.
    : `<span class="down">⏸️ ${escapeHTML(e.state)}</span>`);
  const copies = copy.map((e) =>
    `<button class="linky" data-copy="${escapeAttr(e.uri)}" title="${escapeAttr(e.uri)}">📋 copy URI</button>`);
  if (links.length || copies.length) return [...links, ...copies].join(" ");
  if (!row.bound.length) return `<span class="down">—</span>`;
  // NOTHING NAMED IT, SO THE SCHEME IS A GUESS AND SAYS SO. The PORT is not a
  // guess — docker has it bound this second — and the host is the one this page
  // was reached on. Styled down and titled rather than dropped: a table that
  // offered nothing for the other thirty would send the reader to type the
  // same URL by hand.
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
    // things to open and ONE container to name; repeating the name per endpoint
    // read as three containers fighting over a port.
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
  // and an empty "APP PLANE: none" on each is furniture teaching the reader to
  // scroll past the place the answer appears on the ones that do.
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
 * FETCHED AFTER THE PANE IS PAINTED: the bus half holds a subscription open for
 * a settle window, and folding it into /api/container would put four seconds
 * between clicking a card and reading its diagnosis.
 * A SECTION THAT SAYS WHY IT IS EMPTY. Every other block is drawn only when it
 * has content; this one is always drawn, because the whole reason it exists is
 * somebody opening a container and finding no sign of an API — "no routes" and
 * "nobody asked" look identical as a blank space. */
function surfaceHTML(surface) {
  const api = surface && surface.api;
  const bus = surface && surface.bus;
  let html = `<h3>🔧 API — HOOKS &amp; HANDLES</h3>`;

  if (!api) {
    html += row("HTTP", "no answer from api.sh for this container.", "dim");
  } else if (!api.routes || !api.routes.length) {
    html += row("HTTP", escapeHTML(api.reason || api.error || "no route table"), "dim");
  } else {
    /* WHERE THEY CAME FROM: `declared` is the service own table, `404` its
     * refusal read for the paths it names, `self-describing` an NMOS base path
     * answering with its children. A reader who knows which knows how much to
     * trust a missing row. */
    if (api.source) html += row("Read from", `${escapeHTML(api.source)} <span class="dim">(${escapeHTML(api.how || "")})</span>`, "url");
    if (api.note)   html += row("Note", escapeHTML(api.note), "dim");
    html += `<ul class="routes">${api.routes.map((route) => {
      /* A VERB IS NEVER A LINK. `POST /agents/<id>/stop` silences a node
       * telemetry, and the GET/POST split this package is built on would mean
       * nothing if the pane offered the POSTs as things to click. */
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
    /* MQTT cannot tell a subscriber who published, so this is a real answer
     * and not a failure: nothing in the window named this container. */
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
 * THE ONLY BLOCK ON THIS PANE THAT IS NOT A MEASUREMENT, and drawn FIRST for
 * that reason: everything under it says how the container is, which is not
 * readable to somebody who does not yet know what it is for.
 * A SECTION THAT SAYS WHY IT IS EMPTY, the rule surfaceHTML() follows: a
 * container with no purpose.sh entry is printed as exactly that, naming the
 * file, because that is fixed by writing four lines in one table. */
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
    // and that is correct rather than missing: it has the host addresses.
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

/* THE SECOND FETCH. Guarded on the selection because the census takes seconds,
 * and clicking across five cards would leave five answers in flight each
 * overwriting the pane of a container nobody is looking at. */
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
      // A mqtt:// or mysql:// handed to a browser is at best a dialog asking
      // what application to use, so these are copied and never opened.
      buttons.push(`<button class="btn teal small" data-copy="${escapeAttr(endpoint.uri)}">📋 Copy ${escapeHTML(endpoint.label)} (${escapeHTML(endpoint.uri)})</button>`);
    }
  }
  // A published port the endpoint table does not know about. Its own page
  // states its name; page-titles.sh fetched and remembered it, so the launcher
  // reads as a place and not as a number.
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
    // The pane already open on a container is repainted with the grid, because
    // the two disagreeing is what the follow cadence exists for.
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
 * frequency either way; the alignment buys that a 15s scan lands on :00, :15,
 * :30 and :45 — the four tops of the pace clock — so the block of log a scan
 * produces is one colour. A free-running cadence straddles the quarter and
 * every scan comes out two colours, which reads as two events.
 * ONLY WHEN THE INTERVAL DIVIDES THE MINUTE: 25s does not, so it runs free. */
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

/* HOW MUCH OF THE CARD TO DRAW, as a CLASS ON THE GRID rather than a branch in
 * cardHTML(): three shapes of card would put the density in the markup, so a
 * level change would mean a re-render — and re-rendering a grid whose meters
 * are 5s old redraws them as "—" until the next tick. The card is always
 * whole; manager.css hides what this level does not want.
 * REMEMBERED, unlike the ⏱ cadence, which resets to 15s every load because
 * leaving a fast poll armed costs the box something. Wrapped because a browser
 * with site data blocked THROWS on the property access. */
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
 * from one tab and they finish in either order; a boolean meant whichever
 * returned FIRST re-enabled the whole bar while the other was still going. */
function follow(on) {
  state.busy = Math.max(0, (state.busy || 0) + (on ? 1 : -1));
  on = state.busy > 0;
  clearInterval(state.followTimer);
  // apps=0: apps.sh curls a supervisor in the middle of being restarted, and
  // waiting on it is what would make this cadence miss its beat.
  state.followTimer = on
    ? setInterval(() => scan({ apps: false, quiet: true }), 2000)
    : null;
  // EVERY BUTTON GOES DARK EXCEPT THE ONES THAT MEAN STOP. Disabling the whole
  // bar was right for a second build and wrong for 🛑 and 🚨: the tab that
  // started the rebuild is the tab whose hand is on it. `preempts` comes from
  // the server action table.
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
 * length of a verb — it has to, because the server takes ONE action at a time —
 * and a bar of forty identical dimmed buttons does not say which press landed.
 * On a build that takes minutes, "the page is busy" is indistinguishable from a
 * click that never landed.
 * THE MARK IS ON THE ELEMENT THAT WAS PRESSED, not on the verb: two rows
 * offering up-stack for two stacks are two different presses. */
function markRunning(button, on) {
  if (!button) return;
  button.classList.toggle("running", on);
}

async function runAction(key, button, skipConfirm = false) {
  const row = state.actions.actions[key];
  if (!row) return;
  if (!skipConfirm && !(await askAll(row))) return;
  markRunning(button, true);
  follow(true);
  try {
    await post(`/api/action/${encodeURIComponent(key)}`);
  } finally {
    // A STOP AND THE RUN IT CANCELLED FINISH IN EITHER ORDER, and both land
    // here. follow() counts, so the bar comes back when the LAST of them ends.
    markRunning(button, false);
    // ARMED BEFORE follow(false), which is what triggers the scan that paints
    // the answer. A bench-wide verb changes rows anywhere in the list, so the
    // refreshed list is read from its first row.
    state.rewind = true;
    // THE HALF THE SCAN DOES NOT CARRY. The port table is a join: docker's
    // bound ports ride the scan, but what ANSWERS on each one is endpoints.sh,
    // off the cadence because it is a docker port plus an inspect per
    // container. A verb that just took every published port away leaves that
    // half saying `open ↗` until something asks again — so with the table on
    // screen, something does.
    if (state.view === "ports") loadWebPages();
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
 * it already, so nothing here maps a stack to a compose file — up-stack.sh does
 * that, through the same arrays the bench-wide verbs expand. */
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
  // EVERY BUTTON WORDS COME FROM THE SERVER. A label typed here would be a
  // second name for a verb whose first name is in api.ACTIONS.
  $$("[data-action]").forEach((button) => {
    const row = state.actions.actions[button.dataset.action];
    button.textContent = row ? row.label : button.dataset.action;
    button.onclick = () => runAction(button.dataset.action, button);
  });
  // THE SAME NAMING, ONE RUNG DOWN. A stack verb is drawn only by the bands and
  // carries the stack it is about on the element, so the label is still the
  // server and the argument is the row.
  $$("[data-saction]").forEach((button) => {
    const row = state.actions.stack_actions?.[button.dataset.saction];
    button.textContent = row ? row.label : button.dataset.saction;
    button.onclick = () => runStackAction(button.dataset.saction,
                                          button.dataset.stack, button);
  });
}

/* ONE CLICK IS GRANTED ONE WINDOW, AND THIS MENU HAS SEVEN PAGES IN IT.
 * `open all` was live.forEach((e) => window.open(e.uri)), so a browser opened
 * the first live page and filed the rest under "Pop-ups blocked": a launcher
 * that looks broken while it is being obeyed. Two changes, neither of which
 * asks anybody to allow pop-ups:
 *   · ONE PAGE IS A LINK, NOT A SCRIPT. <a target="_blank"> is a navigation the
 *     person made, so it is never blocked — and with no feature string, a TAB.
 *   · EVERY PAGE IS ONE WINDOW. `open all` opens a single wall and draws one
 *     iframe per live endpoint into it, spending the one window a click gets.
 * A tile that stays blank is a page refusing to be framed (X-Frame-Options, or
 * frame-ancestors), which is the server ruling — so every tile carries its own
 * address as a link out and the wall says so in its header. */
function openWebPageWall(live) {
  const wall = window.open("", "_blank");
  if (!wall) return; /* even the one window was refused; there is nothing to draw into */

  /* The wall is written into about:blank and inherits no stylesheet, so the
   * furniture greys are handed over by value. The tones stay behind: nothing
   * here reports a state, and palette.py rule is that a colour meaning a
   * condition has one home. */
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

// endpoints.sh is docker port plus an inspect PER CONTAINER, and both surfaces
// that want it can ask at once. One in flight at a time; the second caller gets
// the first answer, which is the same answer a second run would take seconds
// to produce.
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
    // ONE FETCH, TWO SURFACES: this menu wants the browsable rows, the port
    // table wants every row including the `copy` ones a broker answers on.
    state.endpoints = endpoints;
    if (state.view === "ports") renderPorts();
    const browsable = endpoints.filter((e) => e.kind === "open");
    const live = browsable.filter((e) => e.state === "up");
    host.innerHTML =
      `<button data-open-all>🚀 Open all ${live.length} live page(s) in one window</button><div class="sep"></div>` +
      browsable.map((e) => {
        const name = e.title ? `${e.title} — ${e.label}` : e.label;
        // A `down` endpoint is listed, not opened: opening it produces a
        // browser error page that reads as a broken site rather than as a
        // stopped container.
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
  // The floor is the server, asked for rather than typed: a full scan is four
  // scripts against every container and takes a second or two of any gap.
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

  // REMEMBERED for the reason the detail level is: which reading of the bench
  // you want is a way of working, not a setting.
  // A RADIO GROUP AND NOT A <select>, so #view is the group and the value lives
  // on whichever input is checked. `change` fires on the input that just BECAME
  // checked, so there is no need to ask which. The `checked` in the markup is
  // the cards default and is overwritten here before the first paint.
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
    // rather than a fixed tail — when a rebuild fails the lines you want are
    // eight red ones scattered through four hundred. The button this replaces
    // copied silently.
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
