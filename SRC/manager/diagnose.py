# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""🩺 What an inspect payload MEANS. Pure functions, no docker, no Tk.

WHAT THIS MODULE OWNS. Reading a `docker inspect` dict and saying, in English,
what state the container is in; turning its port bindings into strings; and
asking the script collection for the two tables the GUI used to hold inline.

WHY IT IS SEPARATE. All of this lived inside `_render_details()`, a 173-line
method that also built Tk widgets, so the exit-code table could not be read
without reading a text box being populated, and could not be tested at all. The
split is the whole benefit: everything here takes a dict and returns data.

THE TWO TABLES IT DOES NOT HOLD. `service_endpoints()` and
`configuration_path()` call `endpoints.sh` and `config-path.sh`. They used to be
Python literals in the window — two disagreeing copies of the port table, and a
third spelling of the compose paths — in a module whose own header says it
spells no port number and no container name.
"""

from .runner import run_management_script


# ---------------------------------------------------------------------------
# EXIT CODES. The table is data because it was a seven-branch if/elif chain
# whose ordering carried a real rule: OOMKilled is asked BEFORE the code,
# because the kernel's OOM killer sends SIGKILL and the container therefore
# reports 137 — the same 137 as `docker stop` on a process that ignored SIGTERM.
# The two are not the same event and the flag is the only thing that separates
# them, so a table keyed on the code alone would call every OOM a manual stop.
# ---------------------------------------------------------------------------
EXIT_CODE_DIAGNOSES = {
    0:   ("🛑", "EXITED CLEANLY", "Container finished its task or was stopped gracefully."),
    1:   ("💥", "CRASHED / ERROR", "Container process exited with an application error."),
    137: ("🛑", "TERMINATED", "Stopped via SIGKILL / docker stop or out-of-memory."),
    143: ("🛑", "STOPPED", "Gracefully shut down via SIGTERM signal."),
    152: ("⚠️", "TIMEOUT / CPU LIMIT", "Exited due to CPU quota or signal limit."),
}


def diagnose_state(data):
    """One line saying what this container's State means. Never empty.

    `data` is what inspect.sh returns. A running container is judged on its
    healthcheck, a stopped one on why it stopped, and a container with no
    healthcheck defined is ACTIVE rather than unknown — most images here define
    none, and painting those amber would make the normal case look wrong.
    """
    state = data.get('State', {}) or {}
    health = (state.get('Health', {}) or {}).get('Status', '')

    if state.get('Running', False):
        if health == 'healthy':
            return "🟢 RUNNING & HEALTHY — Container is active and passing all health checks."
        if health == 'unhealthy':
            return "⚠️ RUNNING BUT UNHEALTHY — Container process is running but failing health checks."
        return "🟢 ACTIVE RUNNING — Container process is active and running cleanly."

    if state.get('OOMKilled', False):
        return ("💥 OOM KILLED (Exit Code 137) — Container ran out of memory and was "
                "killed by Linux OOM killer.")

    code = state.get('ExitCode', 0)
    if code in EXIT_CODE_DIAGNOSES:
        emoji, headline, detail = EXIT_CODE_DIAGNOSES[code]
        return f"{emoji} {headline} (Exit Code {code}) — {detail}"
    return f"🔴 EXITED WITH ERROR (Exit Code {code}) — Container terminated unexpectedly."


def health_status(data):
    """The healthcheck verdict, or the words for having none."""
    state = data.get('State', {}) or {}
    return (state.get('Health', {}) or {}).get('Status', 'No Healthcheck Defined')


def port_mappings(data):
    """Every port this container declares, as `HOST:PORT -> CONTAINER/PROTO`.

    An UNBOUND port is listed too, marked. `NetworkSettings.Ports` carries a key
    with a null value for a port the image EXPOSEs that nothing published, and
    dropping those rows loses the distinction between a container with no ports
    and a container whose ports are all internal — which is most of the reason
    someone opens this pane.
    """
    mappings = []
    for container_port, bindings in (data.get('NetworkSettings', {}).get('Ports', {}) or {}).items():
        if not bindings:
            mappings.append(f"{container_port} (Internal/Unbound)")
            continue
        for binding in bindings:
            host_ip = binding.get('HostIp', '0.0.0.0')
            mappings.append(f"{host_ip}:{binding.get('HostPort', '')} -> {container_port}")
    return mappings


def network_addresses(data):
    """`(network name, IP)` for each network, IP `None` when it has none.

    A host-networked container has a Networks entry with an empty IPAddress, and
    that is correct rather than missing: it has the host's addresses. The caller
    is expected to say so rather than print a blank.
    """
    networks = (data.get('NetworkSettings', {}) or {}).get('Networks', {}) or {}
    return [(name, detail.get('IPAddress') or None) for name, detail in networks.items()]


# ---------------------------------------------------------------------------
# THE TWO TABLES THAT ARE NOT HERE.
# ---------------------------------------------------------------------------
def service_endpoints(container_name=None, quiet=False):
    """Every address the ecosystem answers on, from `endpoints.sh`.

    `quiet` is for a repaint rather than a click -- the auto-refresh ripple
    re-draws these launchers on its interval, and announcing the script each
    time is the bus traffic run_management_script's own docstring forbids.

    Returns dicts: container, kind (`open` for a browser, `copy` for a URI),
    label, uri, state (`up` / `declared` / `down`).

    THE GUI HELD THIS TWICE AND THE TWO COPIES DISAGREED. `open_all_web_pages()`
    opened 8080, 4444 and 3001; `_update_service_buttons()` offered 8080, 1883,
    9001 and 3306. No compose file in this repository publishes 4444 or 3001, so
    the first button opened two dead tabs every time, and NEITHER list had 8100
    — the BareMetal supervisor, which is real and is missed by anything that
    discovers endpoints from a Ports column, because the node runs
    `network_mode: host` and therefore has no Ports column at all.

    An empty list on failure, not an exception. This decorates a pane; a script
    that will not run must not take the pane down with it.
    """
    exit_code, output = run_management_script('endpoints.sh',
                                              [container_name] if container_name else [],
                                              quiet=quiet)
    if exit_code != 0:
        return []
    endpoints = []
    for line in output.strip().splitlines():
        if not line or line.startswith('@EVENT '):
            continue
        fields = (line.split('\t') + [''] * 5)[:5]
        endpoints.append({"container": fields[0], "kind": fields[1], "label": fields[2],
                          "uri": fields[3], "state": fields[4]})
    return endpoints


def configuration_path(container_name, quiet=False):
    """The compose file or Dockerfile that built a container, or None.

    `quiet` for the auto-refresh repaint -- see service_endpoints() above.

    `config-path.sh` asks the container's own compose label first and falls back
    to a name table. The Python this replaces did it the other way round, so a
    guess from a substring match beat the answer docker had recorded.
    """
    exit_code, output = run_management_script('config-path.sh', [container_name],
                                              quiet=quiet)
    if exit_code != 0:
        return None
    for line in output.strip().splitlines():
        if line and not line.startswith('@EVENT '):
            return line.strip()
    return None
