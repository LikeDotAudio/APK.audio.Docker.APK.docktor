# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📡 Where the broker candidate list comes from — one import site for the package.

OWNS nothing but the lookup. The ORDER (configured first, loopback next, public
brokers only behind the double opt-in) is not decided in DockTor and must not
be copied into it: it is the house broker-candidate module, and this file only
says which copy of it this process loads.

    module()       the candidate module, or raises ImportError naming both homes
    public_hosts() the host names that are NOT ours (empty when unavailable)

WHERE IT IS LOOKED FOR, in order (2026-10-30 audit, DockTor #1):
  1. `apkaudio_contracts.broker_candidates` — the versioned contracts package,
     pip-installed into the image from contracts/python. This is the home.
  2. NODE.BareMetal's `Baremetal:Manager/mqtt_broker_discovery.py` under
     paths.BAREMETAL_ROOT — the transitional home, while the contracts package
     does not carry the module yet. Same API; it goes when (1) ships.
Before this file the sys.path insert lived at three call sites in report.py.
"""

import os
import sys

from .paths import BAREMETAL_ROOT

_cached = None


def module():
    """The broker-candidate module. ImportError when neither home has it."""
    global _cached
    if _cached is not None:
        return _cached
    try:
        from apkaudio_contracts import broker_candidates as found
    except ImportError:
        legacy = os.path.join(BAREMETAL_ROOT, "Baremetal:Manager")
        if legacy not in sys.path:
            sys.path.insert(0, legacy)
        try:
            import mqtt_broker_discovery as found
        except ImportError as err:
            raise ImportError(
                "no broker-candidate module: neither apkaudio_contracts.broker_candidates "
                f"nor mqtt_broker_discovery.py under {legacy}") from err
    _cached = found
    return found


def public_hosts():
    """The public broker host names — the hosts this bench does not own."""
    try:
        return {row[0] for row in module().PUBLIC_MQTT_BROKERS}
    except Exception:
        return set()
