# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📡 Is the DEVICE behind a card alive? Asked of the wire, never of docker.

OWNS two questions: where a card's device lives, and whether it answers there.
A running container is not evidence of life and an exited one is not evidence
of death, so the container's state is never consulted — only its labels, its
environment and its name, as clues to an address. A name docker has never heard
of is treated as the address itself.

WHERE, in order of trust:
  1. apk.audio.ip, then an IPv4 inside apk.audio.resource / APK_INSTRUMENT_RESOURCE
  2. an IPv4 spelled in the device id or container name
  3. a MAC (or a PTP EUI-64 clock identity) looked up in the neighbour table
  4. a hostname: DNS first, then one multicast-DNS question for <name>.local

ALIVE is any of: an ICMP echo reply, a TCP accept or RST on 80 or 111, or a
neighbour entry that is REACHABLE after the knock. ⚠️ Never 5025 — SCPI raw
sockets are single-session, and a knock there can evict the container that
owns the instrument.
"""

import re
import time
import socket
import struct
import subprocess

from .readers import inspect_container_json


IPV4 = re.compile(r"(?<![\d.])((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})(?![\d.])")
OCTETS = re.compile(r"(?<![0-9a-f])((?:[0-9a-f]{2}[-:]){5,7}[0-9a-f]{2})(?![0-9a-f])", re.I)
TCP_KNOCK_PORTS = (80, 111)
ICMP_WAIT_SECONDS = 1


# --------------------------------------------------------------------- where
def _mac_from_octets(text):
    """A MAC out of a 6-byte address, an EUI-64 (ff:fe in the middle), or a
    PTP port identity whose last six bytes are the MAC. None when nothing fits."""
    parts = re.split(r"[-:]", text.lower())
    if len(parts) == 8 and parts[3:5] == ["ff", "fe"]:
        parts = parts[:3] + parts[5:]
    return ":".join(parts[-6:]) if len(parts) >= 6 else None


def _neighbours():
    """{mac: (ip, state)} from `ip neigh`, IPv4 only."""
    try:
        output = subprocess.run(["ip", "-4", "neigh"], capture_output=True,
                                text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    table = {}
    for line in output.splitlines():
        fields = line.split()
        if "lladdr" in fields:
            table[fields[fields.index("lladdr") + 1].lower()] = (fields[0], fields[-1])
    return table


def _neighbour_state(ip):
    for addr, state in _neighbours().values():
        if addr == ip:
            return state
    return None


# A responder multicasts one record at most once a second (RFC 6762 §6), so two
# cards naming one device, pinged back to back, would see the second go silent.
# Remember an answer briefly, and ask a second time past the one-second window.
MDNS_CACHE_SECONDS = 30
_mdns_cache = {}


def _mdns_lookup(hostname):
    key = hostname.rstrip(".").lower()
    hit = _mdns_cache.get(key)
    if hit and time.monotonic() - hit[1] < MDNS_CACHE_SECONDS:
        return hit[0]
    ip = _mdns_a(key) or _mdns_a(key)
    if ip:
        _mdns_cache[key] = (ip, time.monotonic())
    return ip


def _mdns_a(hostname, timeout=1.2):
    """One multicast-DNS A question. The manager's container has no nss-mdns,
    so getaddrinfo cannot see .local — this asks the segment directly.
    Asked FROM 5353 and answered by multicast: embedded responders (Dante,
    RAVENNA cards) ignore legacy unicast questions from an ephemeral port.
    5353 is shared with the host's avahi through SO_REUSEADDR/SO_REUSEPORT."""
    want = hostname.rstrip(".").lower()
    labels = b"".join(bytes([len(p)]) + p.encode() for p in want.split("."))
    query = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0) + labels + b"\x00" + struct.pack(">HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.bind(("", 5353))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                        socket.inet_aton("224.0.0.251") + socket.inet_aton("0.0.0.0"))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        sock.sendto(query, ("224.0.0.251", 5353))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            sock.settimeout(max(0.05, deadline - time.monotonic()))
            data, _sender = sock.recvfrom(9000)
            ip = _a_record_for(data, want)
            if ip:
                return ip
    except (OSError, struct.error, IndexError):
        pass
    finally:
        sock.close()
    return None


def _read_name(data, offset):
    """(name, offset after it), following compression pointers."""
    parts, jumped, end = [], False, offset
    for _ in range(64):
        length = data[offset]
        if length == 0:
            offset += 1
            break
        if length & 0xC0 == 0xC0:
            if not jumped:
                end = offset + 2
            offset = ((length & 0x3F) << 8) | data[offset + 1]
            jumped = True
            continue
        parts.append(data[offset + 1:offset + 1 + length].decode("utf-8", "replace"))
        offset += 1 + length
    return ".".join(parts).lower(), (end if jumped else offset)


def _a_record_for(data, want):
    """The IPv4 an mDNS response gives for `want`, among every record it holds."""
    if len(data) < 12 or not data[2] & 0x80:            # responses only
        return None
    qd, an, ns, ar = struct.unpack(">HHHH", data[4:12])
    offset = 12
    for _ in range(qd):
        offset = _read_name(data, offset)[1] + 4
    for _ in range(an + ns + ar):
        name, offset = _read_name(data, offset)
        rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[offset:offset + 10])
        offset += 10
        if rtype == 1 and rdlen == 4 and name == want:
            return socket.inet_ntoa(data[offset:offset + 4])
        offset += rdlen
    return None


def _resolve_hostname(name):
    """(ip, how) for a hostname, or (None, None)."""
    # A bare label goes to mDNS only: through the container's resolver it walks
    # the search domains and stalls seconds per name before failing.
    candidates = [name] if name.endswith(".local") else (
        [name, f"{name}.local"] if "." in name else [f"{name}.local"])
    for candidate in candidates:
        if not candidate.endswith(".local"):
            try:
                return socket.gethostbyname(candidate), f"DNS {candidate}"
            except OSError:
                continue
        ip = _mdns_lookup(candidate)
        if ip:
            return ip, f"mDNS {candidate}"
    return None, None


def locate(name):
    """Where the device behind `name` lives: {target, source, tried}."""
    doc = inspect_container_json(name, quiet=True)
    tried = []
    if doc:
        doc = doc[0] if isinstance(doc, list) else doc
        labels = (doc.get("Config") or {}).get("Labels") or {}
        env = dict(e.split("=", 1) for e in (doc.get("Config") or {}).get("Env") or [] if "=" in e)
        device_id = labels.get("apk.audio.device_id", "")
        kinds = {labels.get("apk.audio.family", ""), labels.get("apk.audio.protocol", "")}
    else:
        labels, env, device_id, kinds = {}, {}, "", set()

    # 1. What the launcher wrote on the container.
    for source, value in (("label apk.audio.ip", labels.get("apk.audio.ip")),
                          ("label apk.audio.resource", labels.get("apk.audio.resource")),
                          ("env APK_INSTRUMENT_RESOURCE", env.get("APK_INSTRUMENT_RESOURCE"))):
        match = IPV4.search(value or "")
        if match:
            return {"target": match.group(1), "source": source, "tried": tried}
    tried.append("labels carry no IPv4")

    # The device's own name: the id and the container name, each also less a
    # leading apk- and <family|protocol>- — the launcher prefixes both.
    launched = name.lower().startswith("apk-")
    stem = name[4:] if launched else name
    kinds = {k.lower() for k in kinds if k}
    if launched:
        kinds.add(stem.split("-", 1)[0].lower())

    def bare(word):
        head, _, rest = word.partition("-")
        return rest if rest and head.lower() in kinds else word

    words = [bare(device_id), device_id, bare(stem), stem, name]
    words += [re.sub(r"(\.local)-\d+$", r"\1", w) for w in words if w]
    words = list({w.lower(): w for w in words if w}.values())

    # 2. An address spelled in the name.
    for word in words:
        match = IPV4.search(word)
        if match:
            return {"target": match.group(1), "source": f"IPv4 in name {word}", "tried": tried}

    # 3. A MAC, through the neighbour table.
    for word in words:
        # AirPlay/RAOP ids spell the MAC as twelve bare hex digits.
        bare_macs = [":".join(h[i:i + 2] for i in range(0, 12, 2))
                     for h in re.findall(r"(?<![0-9a-f])([0-9a-f]{12})(?![0-9a-f])", word, re.I)
                     if re.search(r"\d", h) and re.search(r"[a-f]", h, re.I)]
        for octets in OCTETS.findall(word) + bare_macs:
            mac = _mac_from_octets(octets)
            if not mac:
                continue
            hit = _neighbours().get(mac)
            if hit:
                return {"target": hit[0], "source": f"neighbour table {mac}", "tried": tried}
            if f"MAC {mac} not in the neighbour table" not in tried:
                tried.append(f"MAC {mac} not in the neighbour table")

    # 4. A hostname. Skip words that are only hex/MAC noise or devN placeholders.
    for word in (w for w in words if not (launched and w == name)):
        if OCTETS.search(word) or re.fullmatch(r"(dev\d+|[0-9a-f-]{16,})", word, re.I):
            continue
        ip, how = _resolve_hostname(word)
        if ip:
            return {"target": ip, "source": how, "tried": tried}
        tried.append(f"{word} does not resolve (DNS, mDNS)")

    return {"target": None, "source": None, "tried": tried}


# --------------------------------------------------------------------- alive
def _icmp(ip):
    """Round-trip milliseconds, or None. busybox and iputils both take -c/-W."""
    try:
        result = subprocess.run(["ping", "-c", "1", "-W", str(ICMP_WAIT_SECONDS), ip],
                                capture_output=True, text=True,
                                timeout=ICMP_WAIT_SECONDS + 2)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    match = re.search(r"time[=<]([\d.]+)\s*ms", result.stdout)
    return float(match.group(1)) if match else 0.0


def _tcp(ip, port, timeout=0.8):
    """True on accept or RST — both mean a host is on the wire."""
    started = time.monotonic()
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True, (time.monotonic() - started) * 1000
    except ConnectionRefusedError:
        return True, (time.monotonic() - started) * 1000
    except OSError:
        return False, None


def ping(name):
    """Locate the device behind `name` and knock. The answer the button paints."""
    where = locate(name)
    ip = where["target"]
    answer = dict(where, container=name, checked_at=time.strftime("%H:%M:%S"),
                  alive=None, method=None, rtt_ms=None)
    if not ip:
        answer["verdict"] = "unknown"
        return answer

    rtt = _icmp(ip)
    if rtt is not None:
        answer.update(alive=True, method="ICMP echo", rtt_ms=rtt)
    else:
        for port in TCP_KNOCK_PORTS:
            ok, ms = _tcp(ip, port)
            if ok:
                answer.update(alive=True, method=f"TCP {port}", rtt_ms=ms)
                break
        else:
            state = _neighbour_state(ip)
            if state == "REACHABLE":
                answer.update(alive=True, method="ARP REACHABLE")
            else:
                answer.update(alive=False, method=f"no ICMP, no TCP 80/111, ARP {state or 'none'}")
    answer["verdict"] = "alive" if answer["alive"] else "dead"
    return answer
