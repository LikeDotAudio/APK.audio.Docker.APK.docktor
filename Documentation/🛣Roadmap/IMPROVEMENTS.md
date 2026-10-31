# 🛣 Improvements — MANAGER.Docktor (from the 2026-10-30 architecture audit)

What this repo should change to meet the standard, most valuable first. Source: [🔍Audits/ARCHITECTURE-AUDIT.md](../%F0%9F%94%8DAudits/ARCHITECTURE-AUDIT.md).
← [Roadmap](INDEX.md)

| # | Improvement | Category | Effort (S/M/L) | Evidence |
|---|---|---|---|---|
| 1 | Delete the 18 remaining hand `emit_endpoint` rows. Every owner has labelled its container and `endpoints.sh` lets labels win; Broker-Mosquitto's rows are gone (its labels are live). Storage-Portal, SQL-Proxy, Netbox-App, NMOS-Dev and Ember-Provider still run without the labels (`docker inspect`, 2026-10-30). Needs owner: recreate those stacks (`K8/up-stack.sh`), then delete their rows — deleting first would blank the dashboard rows of running containers | Coupling & Cohesion | S | `K8/endpoints.sh` hand rows, `self_described` |

Delivered items are in [🌍Publishing/DELIVERY.md](../%F0%9F%8C%8DPublishing/DELIVERY.md).
