# OMR 3K connection profiles

Source candidate for MQVPN-based 3K routers. Requires the paired VPS profile API
in admin candidate `0.18+20261030-3k5`; an older VPS leaves profiles unavailable
rather than applying only one side. The existing published installer/frozen lock
has not been changed to install this candidate automatically.

LuCI provides quick controls on OMR Status and a **Connection profiles** page.
The RPC object is `omr.profiles`; read-only access exposes status, while save,
apply, confirm, rollback and delete require the separate write ACL.

| Profile | MPTCP scheduler | TCP CC | MQVPN scheduler | MQVPN CC |
|---|---|---|---|---|
| Default | default | bbr (BBRv3) | minrtt | bbr2 |
| Performance | default | nanbbr3_light | wlb | bbr2 |
| Gaming | bpf_red | bbr (BBRv3) | minrtt | bbr2 |

These are selectable tuning goals, not measured performance guarantees. Default
resets all managed tuning values. Performance/Gaming change the four fields
above and preserve other tuning. Custom profiles capture the current allowlisted
settings independently on router and VPS. Default deliberately restores the
original asymmetric reorder behavior: router enabled, VPS disabled. Addresses,
keys, credentials, WAN/LAN configuration, forwarding and remote-access gates are
outside the profile data. The active VPN type is not changed; MQVPN must already
be selected and configured.

Apply is asynchronous. It journals the previous managed values, applies/verifies
the VPS and router and asks for **Keep profile** within 60 seconds. Revert,
timeout, partial failure and interrupted processes trigger recovery. The VPS has
its own 240-second rollback window and an independent systemd recovery timer.
Lost confirmation replies are resolved by transaction ID and server status.
An incomplete rollback remains visibly pending for retry. A profile change may
restart services and interrupt existing traffic; session-preserving WAN failover
is a separate feature.

The procd service starts at 45 and maintains a boot-specific monotonic lease.
The ordinary VPS synchronization script respects its guard during the active
transaction. Only allowlisted tuning options are written using an isolated
libuci operation; pending external UCI changes are not silently committed.
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
reply, Gaming timeout rollback, and custom save/revert. This is contract
integration, not a full deployment or authentication test; the VPS FastAPI tests
separately cover authorization and request validation.

Frontend fixtures and browser-preview instructions are in
`luci-app-omr-profiles/tests`. OpenWrt package build/install, actual rpcd/procd,
systemd module-loader/recovery services, GUI over a real tunnel and paired-router
traffic acceptance still require a disposable installed-image test before release.
