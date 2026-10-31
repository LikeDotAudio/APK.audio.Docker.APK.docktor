# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📡 Where the broker candidate list comes from — one import site for the package.

OWNS nothing but the lookup. The ORDER (configured first, loopback next, public
brokers only behind the double opt-in) is not decided in DockTor and must not
be copied into it: it is `apkaudio_contracts.broker_candidates` (contracts
36273b972, NODE.BareMetal's mqtt_broker_discovery API verbatim), pip-installed
into the image. Until 2026-10-30 this file fell back to NODE.BareMetal's copy by
sys.path; that fallback and the image's COPY of it are gone (DockTor #1).

    module()       the candidate module (ImportError when the package is absent)
    public_hosts() the host names that are NOT ours (empty when unavailable)
"""

from . import paths  # noqa: F401 — puts a checkout's contracts/python on sys.path


def module():
    """apkaudio_contracts.broker_candidates."""
    from apkaudio_contracts import broker_candidates
    return broker_candidates


def public_hosts():
    """The public broker host names — the hosts this bench does not own."""
    try:
        return {row[0] for row in module().PUBLIC_MQTT_BROKERS}
    except Exception:
        return set()
