# Security policy

PodCharge is a small local macOS app. Its build requests the App Sandbox and Bluetooth entitlements, with no network client/server entitlement. It has no accounts, analytics, updater, third-party packages, or bundled helper. It runs Apple's fixed local `system_profiler -json SPBluetoothDataType` command to find a selected device. These are reviewable design boundaries, not a security certification or a promise that all behavior is safe.

The app scans nearby BLE broadcasts and filters for a selected AirPods pair. Name or CoreBluetooth identifier matching does not authenticate a device cryptographically, and the radio can receive other nearby broadcasts. PodCharge stores selected-device status and preferences in its sandboxed container. Local builds are ad hoc signed, not Developer ID signed or notarized.

## Report a vulnerability

Please use GitHub's **Report a vulnerability** option on the repository's **Security** tab if private vulnerability reporting is enabled. If it is unavailable, open a public issue asking the maintainer for a private reporting channel **without including exploit details**. Please do not post sensitive findings in a public issue or pull request.

Include the affected commit, macOS version, reproduction steps, and impact. Redact AirPods names, Bluetooth addresses, captures, status files, and other personal data unless a specific detail is essential. There is no guaranteed response time or disclosure deadline. Security review contributions are welcome.

For repeatable local checks and their limits, see [Verification/README.md](Verification/README.md).
