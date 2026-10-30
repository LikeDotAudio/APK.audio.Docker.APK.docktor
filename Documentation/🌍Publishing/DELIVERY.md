# Delivery — MANAGER.Docktor

How DockTor is built, tested and shipped, and where it lands.

← [Wiki home](../README.md)

## Where it lands

The **DockTor** container on each bench host: image built from `Docker/Dockerfile.manager` with the
APK.audio root as context, run by `Docker/docker-compose.manager.yml` (compose project `apk-audio`).
Page and API at `http://localhost:8765/` — loopback only, there is no public URL.

## Build and ship

1. Commit here; push this submodule (`.apk.scripts/deploy_all.py` at the APK.audio root pushes every
   submodule) and bump the pointer in the root.
2. Rebuild the image on the bench: `K8/up-stack.sh docktor` or `K8/manager.sh up`. The dashboard runs the
   **copy baked into the image** (`/app/APK:DOCKERS/APK:docktor/SRC/…`), so edits to `K8/*.sh`,
   `SRC/manager/*.py` or `web/` take effect only after this rebuild. `up-stack.sh` refuses to recreate the
   manager from inside DockTor; run it from a host terminal.
3. Check: `curl -s localhost:8765/api/health` and `curl -s localhost:8765/api/endpoints`.

## Test

```sh
cd SRC && python3 -m pytest -q manager/test_readers_idle.py
cd SRC && python3 -c "import manager.api, manager.serve, manager.cli"   # imports headless
for f in K8/*.sh SRC/*.sh; do bash -n "$f"; done
K8/naming.sh            # includes plugin-includes.sh
K8/test-gates.sh        # pre-build gates (against a bench)
K8/verify.sh            # post-mount checks (against a running bench)
```

Smoke (`.apk.scripts/smoke.py`): HEAD is on origin — [SMOKE.md](../%F0%9F%A7%A9Manual%20and%20Artifacts/SMOKE.md).

## Not automated

- No CI workflow in this repository; nothing runs the tests above on push.
- Nothing rebuilds the DockTor image when this repo changes; a stale image keeps running old scripts.
- `verify.sh` and `test-gates.sh` need a live Docker host and are run by hand or from the dashboard.
