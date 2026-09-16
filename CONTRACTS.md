# Contract Bindings Specification — `APK:docktor`

Part of the **APK.audio** system-wide contracts enforcer framework (`APK:PODS/contracts`).

---

## 📜 Contract Binding Philosophy

All messages, heartbeats, state announcements, and control commands in `APK:docktor` MUST conform strictly to the global contract rules defined in `APK:PODS/contracts`.

### 1. Mailbox Topic Structure
- **`incoming/{leaf}`** (*Module -> Bus*): Reports item state, telemetry, discoveries, and test results.
- **`outgoing/{leaf}`** (*Bus -> Module*): Subscribes to commands, setpoints, and test executions.

```text
APK.audio/System/Protocols/APK:docktor/incoming/{state,detail,interface,telemetry,discovered,selftest_result}
APK.audio/System/Protocols/APK:docktor/outgoing/{command,enable,selftest_run}
```

### 2. Retain Policy Rules
- **Conclusions & Positions (`retain = True`)**: `state`, `detail`, `interface`, `selftest`, `selftest_result`, `enable`.
- **Samples & Gestures (`retain = False`)**: `telemetry`, `discovered`, `command`, `selftest_run`.

---

## 🔌 Language Binding Integrations

- **Rust**: Link `apkaudio-contracts` crate (`APK:PODS/contracts/rust`)
- **TypeScript / Node**: Import `@apkaudio/contracts` package (`APK:PODS/contracts`)
- **Python**: Import `apkaudio_contracts` module (`APK:PODS/contracts/python`)

---

## 🛡️ Enforced Verification
Run the system contracts validator:
```bash
./.apk.scripts/check.sh comprotocols
```
