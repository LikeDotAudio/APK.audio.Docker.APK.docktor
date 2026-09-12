# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🩺 What an inspect payload MEANS. Pure functions, no docker, no Tk.

OWNS reading a `docker inspect` dict and saying in English what state the
container is in, turning its port bindings into strings, and asking the script
collection for the two tables the GUI used to hold inline.
SEPARATE because all of this lived inside a 173-line _render_details() that
also built Tk widgets, so the exit-code table could not be read or tested.
Everything here takes a dict and returns data.
THE TWO TABLES IT DOES NOT HOLD: service_endpoints() and configuration_path()
call endpoints.sh and config-path.sh. They used to be Python literals — two
disagreeing copies of the port table and a third spelling of the compose paths.
"""

from .runner import run_management_script


# ---------------------------------------------------------------------------
# EXIT CODES. Data rather than a seven-branch if/elif whose ordering carried a
# real rule: OOMKilled is asked BEFORE the code, because the OOM killer sends
# SIGKILL and the container reports 137 — the same 137 as `docker stop` on a
# process that ignored SIGTERM. A table keyed on the code alone would call
# every OOM a manual stop.
# ---------------------------------------------------------------------------
EXIT_CODE_DIAGNOSES = {
    0:   ("🛑", "EXITED CLEANLY", "Container finished its task or was stopped gracefully."),
    1:   ("💥", "CRASHED / ERROR", "Container process exited with an application error."),
    137: ("🛑", "TERMINATED", "Stopped via SIGKILL / docker stop or out-of-memory."),
    143: ("🛑", "STOPPED", "Gracefully shut down via SIGTERM signal."),
    152: ("⚠️", "TIMEOUT / CPU LIMIT", "Exited due to CPU quota or signal limit."),
}


def diagnose_state(data):
    """One line saying what this container State means. Never empty.

    A running container is judged on its healthcheck, a stopped one on why it
    stopped, and a container with no healthcheck is ACTIVE rather than unknown:
    most images here define none, and amber would make the normal case look
    wrong.
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

    An UNBOUND port is listed too, marked: NetworkSettings.Ports carries a null
    value for a port the image EXPOSEs that nothing published, and dropping
    those loses the difference between a container with no ports and one whose
    ports are all internal.
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
    """`(network name, IP)` for each network, IP None when it has none.

    A host-networked container has a Networks entry with an empty IPAddress,
    which is correct rather than missing: it has the host addresses. The caller
    says so rather than printing a blank.
    """
    networks = (data.get('NetworkSettings', {}) or {}).get('Networks', {}) or {}
    return [(name, detail.get('IPAddress') or None) for name, detail in networks.items()]


# THE TWO TABLES THAT ARE NOT HERE.
def service_endpoints(container_name=None, quiet=False):
    """Every address the ecosystem answers on, from `endpoints.sh`.

    `quiet` is for a repaint rather than a click.
    Returns dicts: container, kind (`open` for a browser, `copy` for a URI),
    label, uri, state (up / declared / down).
    THE GUI HELD THIS TWICE AND THE COPIES DISAGREED: one opened 8080, 4444 and
    3001 (no compose file publishes the last two), the other 8080, 1883, 9001
    and 3306 — and neither had 8100, the BareMetal supervisor, which anything
    discovering endpoints from a Ports column misses because that node runs
    network_mode: host and has no Ports column at all.
    An empty list on failure: this decorates a pane.
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

    `quiet` for the auto-refresh repaint.
    config-path.sh asks the container own compose label first and falls back to
    a name table. The Python this replaces did it the other way round, so a
    substring guess beat the answer docker had recorded.
    """
    exit_code, output = run_management_script('config-path.sh', [container_name],
                                              quiet=quiet)
    if exit_code != 0:
        return None
    for line in output.strip().splitlines():
        if line and not line.startswith('@EVENT '):
            return line.strip()
    return None
