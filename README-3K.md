# OpenMPTCProuter v0.64.2-3K client feed

This branch is based on official feed commit 818fa5116eefc99325e0f231e819dc51b062ef85 and pairs with the pinned 3K build repository and VPS base.

The default congestion control is BBRv3, registered as bbr. BBR1, BBR2, nanqinlang and 12 NanBBR variants are added by the matching kernel patches. Existing explicit congestion choices remain intact; the VAR control exposes 1..100 with 25/50/80 presets and verified application.

The port includes the advanced .14 Path diagnostics in native LuCI JS/UBus, the eight BPF schedulers and Weight-RR hook fix, effective TCP XRay reverse port forwarding, remote WireGuard GUI support through the VPS, and SQM 90% / autorate 100/65/25 settings. The official improved Bandwidth view is preserved.

Client modem management, MLVPN and OpenVPN bonding paths are removed. Ordinary OpenVPN remains. The build profile supplies English-only LuCI, Ookla speedtest, speedtestcpp and btop.

MQVPN retains official 0.16.2; private changes to its old engine are outside this port. The paired VPS retains legacy client support.

Validation includes diagnostic fixtures, scheduler hook cases, SQM ratio cases, NanBBR init validation and rollback, API tests and real TLS XRay reverse forwarding. The firmware boots in an isolated VM and the eight schedulers load and select. Multi-WAN and the complete remote WireGuard path require a deployment test.

The inherited multi-target GitHub Actions workflow clones Ysurac repositories and cannot resolve this fork's branch name. It excludes omr-v0.64.2-3K. Build the frozen x86_64/6.18 release through the matching build repository and run-build-3k.sh; final firmware, BIOS/UEFI, TCP and BPF validation reports are recorded there. This workflow-only exclusion does not change the pinned release feed code b5f28146bc807d90c2bda0da8d83111c2bf34f71.
