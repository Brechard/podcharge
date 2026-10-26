# Local verification

Run these checks on a local build from this checkout:

```sh
./scripts/test.sh
./scripts/test-install.sh
./scripts/build.sh
./scripts/verify-security.sh build/PodCharge.app
./scripts/verify-security.sh --probe build/PodCharge.app
```

The test script exercises the decoder, target selection, and charging warning logic, then type-checks the monitor. The installer test builds and security-checks the app, installs it into a temporary destination without opening it, then checks clean replacement, failure preservation, rollback, and rejection of symlink or unexpected targets. It checks installation behavior, not Bluetooth behavior on supported hardware. The security script checks the app signature and signed entitlements, scans production source for common network and updater APIs, checks linked libraries, and looks for packaged helper executables. Its source-process allowance is limited to the fixed local `system_profiler` invocation.

With `--probe`, the script additionally builds and signs a temporary app with the same entitlements and attempts one TCP connection to `127.0.0.1:9`. It passes only if the sandbox returns `EPERM`. The probe does not launch PodCharge. A failed or inconclusive result needs investigation; do not treat another network error as proof of sandbox denial.

These checks are guardrails, not an audit. Source scans can miss indirect behavior, linked-library inspection does not prove what system frameworks do internally, and the loopback probe covers one attempt under copied entitlements. Ad hoc signature verification establishes bundle integrity under that signature, not Developer ID certification or notarization. Review the source, build settings, and signed bundle for each release, and test actual app behavior on supported hardware. Keep device captures and local status files out of public reports.
