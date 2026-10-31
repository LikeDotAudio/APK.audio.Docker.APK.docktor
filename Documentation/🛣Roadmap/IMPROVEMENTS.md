# 🛣 Improvements — MANAGER.Docktor (from the 2026-10-30 architecture audit)

What this repo should change to meet the standard, most valuable first. Source: [🔍Audits/ARCHITECTURE-AUDIT.md](../%F0%9F%94%8DAudits/ARCHITECTURE-AUDIT.md).
← [Roadmap](INDEX.md)

| # | Improvement | Category | Effort (S/M/L) | Evidence |
|---|---|---|---|---|
| 1 | Delete the 20 hand `emit_endpoint` rows. Every owner has labelled its container (Broker-Mosquitto, Storage-Portal, SQL-Proxy, Netbox-App, NMOS-Dev, Ember-Provider carry `audio.apk.purpose` + `audio.apk.endpoint.*` in their compose files) and `endpoints.sh` already lets labels win, but none of the six running containers carries them yet (checked 2026-10-30 with `docker inspect`). Needs owner: recreate them (`K8/up-stack.sh` per stack; Broker-Mosquitto on the operator-overlay restart), then delete the rows — deleting first would blank the dashboard rows of running containers | Coupling & Cohesion | S | `K8/endpoints.sh` hand rows, `self_described` |

Delivered items are in [🌍Publishing/DELIVERY.md](../%F0%9F%8C%8DPublishing/DELIVERY.md).
