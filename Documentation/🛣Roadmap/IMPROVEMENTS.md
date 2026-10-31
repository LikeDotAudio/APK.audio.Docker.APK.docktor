# 🛣 Improvements — MANAGER.Docktor (from the 2026-10-30 architecture audit)

What this repo should change to meet the standard, most valuable first. Source: [🔍Audits/ARCHITECTURE-AUDIT.md](../%F0%9F%94%8DAudits/ARCHITECTURE-AUDIT.md).
← [Roadmap](INDEX.md)

| # | Improvement | Category | Effort (S/M/L) | Evidence |
|---|---|---|---|---|
| 1 | Stop COPYing BareMetal's `mqtt_broker_discovery.py` and `contracts/tokens/brand.json` into the image. Done here: the image pip-installs `apkaudio_contracts`; `brokers.py` is the one import site and already prefers `apkaudio_contracts.broker_candidates`; `paths.py` has one spelling each. Waiting on foundation W01 (contracts handoff filed: ship `broker_candidates` and the brand token as package data), then delete the two COPY lines and the BareMetal fallback in `brokers.py` | Coupling & Cohesion | S | `Docker/Dockerfile.manager` (two COPY lines marked TRANSITIONAL), `SRC/manager/brokers.py` |
| 2 | Delete the remaining 18 hand `emit_endpoint` rows once their owners label their containers. Done here: `endpoints.sh` lets a self-described container's labels win over its hand rows; Broker-Mosquitto is labelled (its two rows go once the broker is recreated with the labels). Waiting on DATABASE.server.SQL (Storage-Portal, SQL-Proxy), DATABASE.server.NETBOX (Netbox-App, and its probe stops parsing this file), PROTOCOL.discovery.NMOS (NMOS-Dev), PROTOCOL.DEV.EMBER (Ember-Provider) — handoffs filed | Coupling & Cohesion | S | `K8/endpoints.sh` `self_described`, hand rows |

Delivered items are in [🌍Publishing/DELIVERY.md](../%F0%9F%8C%8DPublishing/DELIVERY.md).
