# OpenMPTCProuter v0.64.2-3K client feed

This branch is based on official feed commit 818fa5116eefc99325e0f231e819dc51b062ef85 and pairs with the pinned 3K build repository and VPS base.

The default congestion control is BBRv3, registered as bbr. BBR1, BBR2, nanqinlang and 12 NanBBR variants are added by the matching kernel patches. Existing explicit congestion choices remain intact; the VAR control exposes 1..100 with 25/50/80 presets and verified application.

The port includes the advanced .14 Path diagnostics in native LuCI JS/UBus, the eight BPF schedulers and Weight-RR hook fix, effective TCP XRay reverse port forwarding, remote WireGuard GUI support through the VPS, and SQM 90% / autorate 100/65/25 settings. The official improved Bandwidth view is preserved.

Diagnostic logs now use the native LuCI JS/UBus page. The read-only diagnostic_logs method accepts limit (1..1000) and scope (all, router, vps); support_report exports a JSON report with allowlisted router, WAN, VPS sync and current MQVPN schema fields. The VPS side is fetched through the existing authenticated client proxy. The support report includes the newest 500 entries and exported messages are capped at 512 bytes to bound the UBus payload. Log messages are redacted before they reach the UI or export, but arbitrary free-form application text cannot be proven secret-free and should be reviewed before sharing.

The logd collector stores local history under /etc/openmptcprouter-logs/diagnostic.log by default, with one .old rotation; each file is capped at about 1 MiB. This preserves the .14 persistent behavior. To use RAM, set openmptcprouter.settings.diagnostic_log_storage=ram, commit UCI and restart omr-diagnostic-log. The collector uses logread -l and logread -f, keeping omr-events and the LuCI events page separate.

Client modem management, MLVPN and OpenVPN bonding paths are removed. Ordinary OpenVPN remains. The build profile supplies English-only LuCI, Ookla speedtest, speedtestcpp and btop.

MQVPN retains official 0.16.2; private changes to its old engine are outside this port. The paired VPS retains legacy client support.

Validation includes diagnostic fixtures, scheduler hook cases, SQM ratio cases, NanBBR init validation and rollback, API tests and real TLS XRay reverse forwarding. The firmware boots in an isolated VM and the eight schedulers load and select. Multi-WAN and the complete remote WireGuard path require a deployment test.

The inherited multi-target GitHub Actions workflow clones Ysurac repositories and cannot resolve this fork's branch name. It excludes omr-v0.64.2-3K. Build the frozen x86_64/6.18 release through the matching build repository and run-build-3k.sh; final firmware, BIOS/UEFI, TCP and BPF validation reports are recorded there. This workflow-only exclusion does not change the pinned release feed code b5f28146bc807d90c2bda0da8d83111c2bf34f71.
