# OMR 3K connection profiles

Source candidate for 3K routers using MQVPN or provisioned Glorytun TCP. Requires
the negotiated v2 profile API in admin candidate `0.18+20261030-3k6`; an older VPS leaves profiles unavailable
rather than applying only one side. The existing published installer/frozen lock
has not been changed to install this candidate automatically.

LuCI provides quick controls on OMR Status and a **Connection profiles** page.
The RPC object is `omr.profiles`; read-only access exposes status, while save,
apply, confirm, rollback, delete and `set_quick` require the separate write ACL.

The Status switch has two saved slots, A and B, each selecting a built-in or
custom profile. Saving the pair does not apply tuning. The native A/B switch
starts the existing apply/Keep/Revert transaction; its position reflects the
confirmed profile. If the current configuration is outside the pair, activate
either labelled endpoint first. The pair and presets survive local backup and
sysupgrade. Controls are disabled while an apply is pending or permission or
availability checks fail.

| Profile | VPN transport | MPTCP scheduler | TCP CC | MQVPN scheduler / CC |
|---|---|---|---|---|
| Default | MQVPN | default | bbr (BBRv3) | minrtt / bbr2 |
| Performance | MQVPN | default | nanbbr3_light | wlb / bbr2 |
| Stability / Gaming | MQVPN | bpf_red | bbr (BBRv3) | minrtt / bbr2 |
| Performance (old) | Glorytun TCP, main proxy none | default | bbr (BBRv3) | inactive |
| Stability (old) | Glorytun TCP, main proxy none | bpf_red | bbr (BBRv3) | inactive |

These are selectable tuning goals, not measured performance guarantees. Default
resets the managed MQVPN tuning; Performance and Stability / Gaming preserve
other tuning and restore the recorded MQVPN proxy when returning from Glorytun.
The stable ID `gaming` is retained. The old profiles carry normally VPN-routed
TCP, UDP and ICMP inside Glorytun TCP, using distributed or redundant MPTCP
paths respectively. Existing bypass, local LAN, management and routing policies
remain effective; this is not an IPv6 or kill-switch guarantee.

Custom profiles capture tuning and a whitelist of transport, main-proxy flags
and operational tunnel addresses independently on router and VPS. Credentials,
WAN/LAN setup, forwarding definitions and WireGuard access gates are preserved.
Default keeps the original asymmetric reorder behavior: router enabled, VPS
disabled. Both VPNs must already be provisioned; the switcher does not create
or rotate keys. Older custom profiles without a transport snapshot must be
saved again before use.

Glorytun readiness requires its running procd instance, the effective `mptcp`
argument, the expected tunnel address and a reply from its configured IPv4 peer
to a ping bound to that TUN device. Blocking that peer's ICMP makes verification
fail and triggers rollback. MQVPN and Glorytun may use different device names;
the selected device is updated and restored with the transport.

Apply is asynchronous. It journals the previous managed values, applies/verifies
the VPS and router, updates the verified VPS tunnel target and asks for
**Keep profile** within 60 seconds. Revert,
timeout, partial failure and interrupted processes trigger recovery. The VPS has
its own 240-second rollback window and an independent systemd recovery timer.
Lost confirmation replies are resolved by transaction ID and server status.
An incomplete rollback remains visibly pending for retry. A profile change may
restart services and interrupt existing traffic; session-preserving WAN failover
is a separate feature.

The procd service starts at 45 and maintains a boot-specific monotonic lease.
The ordinary VPS synchronization script respects its guard during the active
transaction. Allowlisted values are written using an isolated libuci operation;
the Glorytun init uses this writer for its tunnel device. Pending network,
firewall or proxy changes block switching. Keep other configuration editors
closed during a switch: legacy proxy init/tracker commits do not share a global
editor lock, so an external edit created between checks is not atomically excluded.
Profile storage is private and included in local backup/sysupgrade preservation.
Kernel locks release when the owning process exits.

## Verification

Run transaction tests with Lua 5.1 and the source module path:

```sh
LUA_PATH='files/usr/lib/lua/?.lua;;' lua5.1 tests/test_profiles.lua
```

`tests/test_kernel_lock.py` and `tests/test_uci_isolation.py` require real
nixio/libuci/Lua bindings. Their docstrings list the `PROFILE_*` environment
variables; `LD_LIBRARY_PATH` must include their shared libraries. They use
temporary files/processes, never the router's actual configuration.

`tests/test_vps_contract.py` requires both source repositories, Lua-cjson and
curl. Set `PROFILE_LUA`, `LUA_CPATH` and `OMR_PROFILES_VPS_SOURCE` if the default
review layout is not used. It runs the real Lua transaction model against the
real Python VPS manager over loopback HTTP, with simulated kernel/service/UCI
adapters. It checks Default asymmetry, Performance with a lost confirmation
reply, all five profiles, MQVPN/Glorytun transitions, Xray flag restoration,
quick-pair persistence, route failure, timeout rollback and custom save/revert. This is contract
integration, not a full deployment or authentication test; the VPS FastAPI tests
separately cover authorization and request validation.

Frontend fixtures and browser-preview instructions are in
`luci-app-omr-profiles/tests`. OpenWrt package build/install, actual rpcd/procd,
systemd module-loader/recovery services, GUI over a real tunnel and paired-router
traffic acceptance still require a disposable installed-image test before release.
