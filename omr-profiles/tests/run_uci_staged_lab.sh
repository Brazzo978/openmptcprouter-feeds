#!/bin/sh
# Disposable mount namespace: real libuci with an unrelated pending WAN delta.
set -eu
self="$(readlink -f "$0")"
root="$(dirname "$(dirname "$self")")"
if [ "${1:-}" = --inside ]; then
	# Hold an FD to the old /tmp so the isolated tmpfs does not hide the
	# locally compiled test libraries. Children use their parent's FD path.
	exec 9</tmp
	oldtmp="/proc/$$/fd/9"
	mount --make-rprivate /
	mount -t tmpfs tmpfs /tmp
	cd "$root"
	export LD_LIBRARY_PATH="$oldtmp/omr3k-profile-deps/root/usr/lib/x86_64-linux-gnu:$oldtmp/omrprofiles-uci-lab/uci-build:$oldtmp/omrprofiles-uci-lab/prefix/lib"
	export PROFILE_LUA="$oldtmp/omr3k-profile-deps/root/usr/bin/lua5.1"
	export PROFILE_NIXIO_CPATH="$oldtmp/omrprofiles-uci-lab/luci/libs/luci-lib-nixio/src"
	export PROFILE_NIXIO_LUAPATH="$oldtmp/omrprofiles-uci-lab/luci/libs/luci-lib-nixio/root/usr/lib/lua"
	export PROFILE_UCI_CPATH="$oldtmp/omrprofiles-uci-lab/uci-build/lua"
	export PROFILE_JSON_CPATH="$oldtmp/omr3k-profile-deps/root/usr/lib/x86_64-linux-gnu/lua/5.1"
	export PROFILE_ISOLATED_GLOBAL_UCI=1
	exec python3 tests/test_uci_isolation.py
fi
unshare --user --map-root-user --mount sh "$self" --inside
