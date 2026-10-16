-- Run: lua5.1 openmptcprouter-api/tests/diagnostic_logging.lua \
--      openmptcprouter-api/files/usr/share/omr/diagnostic.lua
local module_path = assert(arg[1], "module path required")
local config = {
	network = {
		wan1 = {[".name"]="wan1", multipath="master", proto="dhcp"},
		omrvpn = {device="tun0"},
		globals = {congestion="bbr"}
	},
	openmptcprouter = {
		settings = {vpn="mqvpn"},
		vps = {[".name"]="vps", [".type"]="server", master="1"}
	},
	mqvpn = {
		settings = {enable="1"}, interface={log_level="warn", mtu="1280"},
		multipath = {scheduler="minrtt", cc="bbr", fec_enable="1"},
		server = {port="65443"}, reorder={enabled="1"}
	}
}
package.preload["luci.model.uci"] = function()
	return {cursor=function()
		return {
			get=function(_, config_name, section, option)
				local s = config[config_name] and config[config_name][section]
				return s and s[option]
			end,
			foreach=function(_, config_name, section_type, callback)
				for _, section in pairs(config[config_name] or {}) do
					if section_type == "interface" and section[".name"] and section[".name"]:match("^wan") then callback(section)
					elseif section_type == "server" and section[".type"] == "server" then callback(section) end
				end
			end
		}
	end}
end
package.preload["luci.sys"] = function()
	return {
		exec=function(command)
			if command:find("network.interface.wan1", 1, true) then return "wanup" end
			if command:find("system board", 1, true) then return "board" end
			return "3600"
		end,
		call=function() return 0 end
	}
end
package.preload["luci.jsonc"] = function()
	return {parse=function(raw)
		if raw == "wanup" then return {up=true} end
		if raw == "board" then return {model="test board", release={version="0.64.2"}} end
		if raw == "remote" then return {entries={{timestamp=os.time(), scope="vps", source="mqvpn",
			component="mqvpn", severity="error", message="api_token=REMOTE-SECRET"}}} end
		error("unexpected JSON fixture " .. tostring(raw))
	end}
end
package.preload["nixio.fs"] = function()
	return {access=function(path) return path == "/sys/class/net/tun0" end}
end

local lines = {
	'Thu Oct 15 12:00:00 2026 daemon.err mqvpn: [ERR] local close err:0x0',
	'Thu Oct 15 12:00:01 2026 auth.warn dropbear: Bad password attempt for root from 192.0.2.1',
	'Thu Oct 15 12:00:02 2026 auth.warn dropbear: Bad password attempt for root from 192.0.2.2',
	'Thu Oct 15 12:00:03 2026 daemon.info OMR-VPS: Authorization: Basic YWJjOmRlZg==',
	'Thu Oct 15 12:00:04 2026 daemon.info OMR-VPS: Authorization: Digest username="alice", response="deadbeef"',
	'Thu Oct 15 12:00:05 2026 daemon.info OMR-VPS: user_password="two words" api_token=TOKEN ss_key=KEY v2ray_uuid=UUID',
	'Thu Oct 15 12:00:06 2026 daemon.info OMR-VPS: https://bob:secret@example.org/path',
	'Thu Oct 15 12:00:07 2026 daemon.info OMR-VPS: WireGuardPrivateKey=PRIVATE Bearer BEARER',
	'Thu Oct 15 12:00:08 2026 daemon.info OMR-VPS: socks5://qa:CANARY@example.invalid',
	'Thu Oct 15 12:00:09 2026 daemon.info OMR-VPS: ' .. string.rep('é', 600)
}
local original_popen = io.popen
io.popen = function(command)
	local result = {}
	if command:find("tail -n", 1, true) then
		function result:lines()
			local index = 0
			return function()
				index = index + 1
				return lines[index]
			end
		end
	elseif command:find("diagnostic_logs", 1, true) then
		function result:read() return "remote" end
	else error("unexpected command " .. command) end
	function result:close() return true end
	return result
end

local diagnostic = dofile(module_path)
local router = diagnostic.collect(100, "router", false)
assert(router.count == 9, "security lines should group and all other lines remain")
assert(router.snapshot.wan_up == 1 and router.snapshot.congestion == "bbr")
local by_source = {}
local saw_bounded = false
for _, entry in ipairs(router.entries) do
	assert(#entry.message <= 512, "exported message must stay within 512 bytes")
	if #entry.message == 512 then
		saw_bounded = true
		assert(entry.message:byte(#entry.message) ~= 0xC3, "UTF-8 character was split")
	end
	assert(not entry.message:find("YWJjOmRlZg==", 1, true))
	assert(not entry.message:find("deadbeef", 1, true))
	assert(not entry.message:find("two words", 1, true))
	assert(not entry.message:find("TOKEN", 1, true))
	assert(not entry.message:find("PRIVATE", 1, true))
	assert(not entry.message:find("BEARER", 1, true))
	assert(not entry.message:find("bob:secret", 1, true))
	assert(not entry.message:find("CANARY", 1, true))
	by_source[entry.source] = entry
end
assert(saw_bounded, "long UTF-8 fixture should reach the 512-byte cap")
assert(by_source.mqvpn.severity == "info", "normal QUIC close is informational")
assert(by_source.dropbear.repeats == 2, "security attempts should be grouped")
assert(diagnostic.collect(0, "router").error == "Invalid limit")
assert(diagnostic.collect(1001, "router").error == "Invalid limit")
assert(diagnostic.collect(10, "invalid").error == "Invalid scope")
local vps = diagnostic.collect(5, "vps", false)
assert(vps.count == 1 and vps.entries[1].scope == "vps")
assert(not vps.entries[1].message:find("REMOTE-SECRET", 1, true))
local report = diagnostic.collect(100, "all", true)
assert(report.kind == "omr_support_report" and report.schema_version == 2)
assert(report.metadata.vpn.mqvpn.multipath.scheduler == "minrtt")
assert(report.metadata.vpn.mqvpn.interface.log_level == "warn")
assert(report.metadata.vpn.mqvpn.auth == nil, "auth config must stay out of allowlist")
io.popen = original_popen
print("diagnostic logging fixtures passed")