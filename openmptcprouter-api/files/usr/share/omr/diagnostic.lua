-- Read-only diagnostic collection for the LuCI support page.
local M = {}
local sys = require "luci.sys"
local json = require "luci.jsonc"
local uci = require "luci.model.uci".cursor()
local fs = require "nixio.fs"

local months = {Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6, Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12}
local valid_severity = {error=true, warning=true, notice=true, info=true, debug=true}

local function clip(text, maximum)
	if #text <= maximum then return text end
	local cutoff = maximum
	while cutoff > 0 do
		local next_byte = text:byte(cutoff + 1)
		if not next_byte or next_byte < 128 or next_byte > 191 then break end
		cutoff = cutoff - 1
	end
	return text:sub(1, cutoff)
end

local function clean(text, maximum)
	return clip((tostring(text or ""):gsub("[%c]", " ")), maximum)
end

local function secret_name(name)
	name = name:lower()
	return name:find("password", 1, true) or name:find("passwd", 1, true) or
		name:find("secret", 1, true) or name:find("token", 1, true) or
		name:find("credential", 1, true) or name:find("privatekey", 1, true) or
		name:find("private_key", 1, true) or name:find("presharedkey", 1, true) or
		name:find("preshared_key", 1, true) or name:match("[_%-]key$") or
		name:match("[_%-]uuid$") or name == "psk" or name == "key" or
		name == "auth" or name == "authorization"
end

local function redact(text)
	text = clean(text, 2048)
	if text:lower():find("-----begin ", 1, true) then return "[redacted key material]" end
	text = text:gsub("([%a][%w+%.%-]*://)[^/@%s]+@", "%1[redacted]@")
	-- Authorization schemes include Basic, Bearer and Digest. Hide the whole
	-- header value, including Digest parameters after the first comma.
	local search = 1
	while true do
		local first, last, key = text:find("([%w_%-]+)%s*:%s*", search)
		if not first then break end
		if key:lower():find("authorization", 1, true) then
			text = text:sub(1, first - 1) .. key .. ": [redacted]"
			break
		end
		search = last + 1
	end
	text = text:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)%S+", "%1[redacted]")
	-- Handle quoted values before bare values so embedded spaces cannot leak.
	text = text:gsub("([%w_%-]+)([\"']?%s*[:=]%s*[\"'])(.-)([\"'])", function(key, separator, value, quote)
		if secret_name(key) then return key .. separator .. "[redacted]" .. quote end
		return key .. separator .. value .. quote
	end)
	text = text:gsub("([%w_%-]+)(%s*[:=]%s*)([^%s,;&}\"']+)", function(key, separator, value)
		if secret_name(key) then return key .. separator .. "[redacted]" end
		return key .. separator .. value
	end)
	-- Keep the largest 1000-entry RPC response well below the ubus message limit.
	return clip(text, 512)
end

local function severity_of(level, message)
	local lower = message:lower()
	if lower:match("%[dbg%]") or lower:match("%[debug%]") then level = "debug"
	elseif lower:match("%[inf%]") or lower:match("%[info%]") then level = "info"
	elseif lower:match("%[wrn%]") or lower:match("%[warn%]") then level = "warning"
	elseif lower:match("%[err%]") or lower:match("%[error%]") then level = "error" end
	if lower:find("err:0x0", 1, true) and (lower:find("local close", 1, true) or lower:find("remote close", 1, true)) then return "info" end
	if level == "emerg" or level == "alert" or level == "crit" or level == "err" then return "error" end
	if level == "warn" then return "warning" end
	return valid_severity[level] and level or "info"
end

local function component_of(source, message)
	local text = (source .. " " .. message):lower()
	if text:find("mqvpn", 1, true) or text:find("xquic", 1, true) then return "mqvpn" end
	if text:find("glorytun", 1, true) or text:find("openvpn", 1, true) or text:find("dsvpn", 1, true) or
	   text:find("wireguard", 1, true) or text:find("ubond", 1, true) or text:find("softether", 1, true) then return "vpn" end
	if text:find("omr-tracker", 1, true) or text:find("post-tracking", 1, true) or text:find("wan", 1, true) then return "wan" end
	if text:find("mptcp", 1, true) or text:find("nanbbr", 1, true) then return "mptcp" end
	if text:find("omr-vps", 1, true) or text:find("vps", 1, true) then return "vps_sync" end
	if text:find("firewall", 1, true) then return "firewall" end
	if text:find("netifd", 1, true) or text:find("network", 1, true) then return "network" end
	if text:find("dropbear", 1, true) or text:find("auth", 1, true) then return "security" end
	return "system"
end

local function parse_line(line)
	-- logd/logread: "Thu Oct 15 12:00:00 2026 daemon.info source: message".
	local _, month, day, hour, minute, second, year, severity, source, message =
		line:match("^(%a+) (%a+) +(%d+) (%d+):(%d+):(%d+) (%d+) %S+%.(%a+) ([^:]+): (.*)$")
	if not month then
		month, day, hour, minute, second, year, severity, source, message =
			line:match("^(%a+) +(%d+) (%d+):(%d+):(%d+) (%d+) %S+%.(%a+) ([^:]+): (.*)$")
	end
	if not (month and months[month]) then return nil end
	local timestamp = os.time({year=tonumber(year), month=months[month], day=tonumber(day),
		hour=tonumber(hour), min=tonumber(minute), sec=tonumber(second)})
	if not timestamp then return nil end
	source = redact(clean(source:gsub("%[%d+%]$", ""), 80))
	severity = severity_of(severity, message)
	local component = component_of(source, message)
	if component == "system" and not source:lower():match("^omr") and severity ~= "error" and severity ~= "warning" then return nil end
	local security = message:match("^(Bad password attempt.-) from ")
	return {timestamp=timestamp, scope="router", source=source, component=component,
		severity=severity, message=redact(security or message), security_group=security ~= nil}
end

local function local_entries(limit)
	local entries, seen, groups = {}, {}, {}
	local dir = uci:get("openmptcprouter", "settings", "diagnostic_log_storage") == "ram" and "/tmp/omr-diagnostic-log" or "/etc/openmptcprouter-logs"
	local pipe = io.popen("tail -n 5000 " .. dir .. "/diagnostic.log.old " .. dir .. "/diagnostic.log 2>/dev/null; logread -l 1000 2>/dev/null")
	if not pipe then return entries end
	for line in pipe:lines() do
		if not seen[line] then
			seen[line] = true
			local entry = parse_line(line)
			if entry then
				local key = entry.source .. ":" .. entry.severity .. ":" .. entry.message
				local prior = entry.security_group and groups[key]
				if prior and entry.timestamp - prior.timestamp >= 0 and entry.timestamp - prior.timestamp <= 300 then
					prior.timestamp = entry.timestamp
					prior.repeats = (prior.repeats or 1) + 1
					prior.message = entry.message .. " (repeated " .. prior.repeats .. " times)"
				else
					local groupable = entry.security_group
					entry.security_group = nil
					entries[#entries + 1] = entry
					if groupable then groups[key] = entry end
				end
			end
		end
	end
	pipe:close()
	table.sort(entries, function(a, b) return a.timestamp > b.timestamp end)
	while #entries > limit do table.remove(entries) end
	return entries
end

local function remote_entries(limit)
	local pipe = io.popen("/etc/init.d/openmptcprouter-vps diagnostic_logs " .. tostring(limit) .. " 2>/dev/null")
	if not pipe then return {}, "VPS diagnostics unavailable" end
	local raw = pipe:read("*a") or ""
	pipe:close()
	local ok, payload = pcall(json.parse, raw)
	if not ok or type(payload) ~= "table" or type(payload.entries) ~= "table" then return {}, "VPS diagnostics unavailable" end
	local result = {}
	for _, item in ipairs(payload.entries) do
		if #result >= limit then break end
		if type(item) == "table" and tonumber(item.timestamp) and type(item.message) == "string" then
			local severity = clean(item.severity, 12)
			result[#result + 1] = {timestamp=math.floor(tonumber(item.timestamp)), scope="vps",
				source=redact(clean(item.source, 80)), component=redact(clean(item.component, 40)),
				severity=valid_severity[severity] and severity or "info", message=redact(item.message)}
		end
	end
	return result, type(payload.error) == "string" and redact(clean(payload.error, 120)) or nil
end

local function snapshot()
	local wans, up = 0, 0
	uci:foreach("network", "interface", function(section)
		local name = section[".name"]
		if name:match("^wan%d+$") and section.multipath ~= "off" then
			wans = wans + 1
			local ok, data = pcall(json.parse, sys.exec("ubus call network.interface." .. name .. " status 2>/dev/null"))
			if ok and type(data) == "table" and data.up == true then up = up + 1 end
		end
	end)
	local tunnel = uci:get("network", "omrvpn", "device") or "tun0"
	if not tunnel:match("^[%w_.%-]+$") then tunnel = "tun0" end
	return {vpn=clean(uci:get("openmptcprouter", "settings", "vpn") or "none", 40),
		congestion=clean(uci:get("network", "globals", "congestion") or sys.exec("sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null"), 32),
		aggressiveness=clean(uci:get("network", "globals", "nanbbr_aggressiveness"), 8),
		tunnel=tunnel, tunnel_up=fs.access("/sys/class/net/" .. tunnel) and true or false,
		wan_up=up, wan_total=wans}
end

local function report_metadata()
	local ok, board = pcall(json.parse, sys.exec("ubus call system board 2>/dev/null"))
	if not ok or type(board) ~= "table" then board = {} end
	local release = type(board.release) == "table" and board.release or {}
	local wans, servers = {}, {}
	uci:foreach("network", "interface", function(section)
		if section[".name"]:match("^wan%d+$") and section.multipath ~= "off" then
			wans[#wans + 1] = {name=section[".name"], protocol=clean(section.proto, 24), multipath=clean(section.multipath, 24)}
		end
	end)
	uci:foreach("openmptcprouter", "server", function(section)
		servers[#servers + 1] = {name=clean(section[".name"], 40), disabled=section.disabled == "1",
			master=section.master == "1", admin_error=section.admin_error == "1", token_error=section.token_error == "1"}
	end)
	local function config(config_name, section_name, fields)
		local data = {}
		for _, field in ipairs(fields) do data[field] = clean(uci:get(config_name, section_name, field), 32) end
		return data
	end
	return {router={model=clean(board.model, 80), board_name=clean(board.board_name, 80),
			kernel=clean(board.kernel, 80), distribution=clean(release.distribution, 40),
			version=clean(release.version, 40), target=clean(release.target, 80),
			uptime_seconds=math.floor(tonumber(sys.exec("cut -d' ' -f1 /proc/uptime 2>/dev/null")) or 0)},
		wans=wans, server_sync=servers,
		vpn={active=clean(uci:get("openmptcprouter", "settings", "vpn"), 40),
			mqvpn={running=sys.call("pidof mqvpn >/dev/null 2>&1") == 0,
				settings=config("mqvpn", "settings", {"enable"}),
				interface=config("mqvpn", "interface", {"tun_name", "log_level", "mtu", "manage_routes", "kill_switch", "reconnect"}),
				multipath=config("mqvpn", "multipath", {"scheduler", "cc", "auto_wan",
					"reinjection_control", "reinjection_mode", "fec_enable", "fec_scheme",
					"sync_path_labels", "init_max_path_id"}),
				server=config("mqvpn", "server", {"port"}),
				reorder=config("mqvpn", "reorder", {"enabled", "max_wait_ms", "cap_packets"})}}}
end

function M.collect(limit, scope, report)
	if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 or limit > 1000 then return {error="Invalid limit", entries={}} end
	if scope ~= "all" and scope ~= "router" and scope ~= "vps" then return {error="Invalid scope", entries={}} end
	local entries, remote_error = {}, nil
	if scope ~= "vps" then for _, item in ipairs(local_entries(limit)) do entries[#entries + 1] = item end end
	if scope ~= "router" then
		local remote
		remote, remote_error = remote_entries(limit)
		for _, item in ipairs(remote) do entries[#entries + 1] = item end
	end
	table.sort(entries, function(a, b) return a.timestamp > b.timestamp end)
	while #entries > limit do table.remove(entries) end
	local result = {generated_at=os.time(), entries=entries, count=#entries, snapshot=snapshot(), vps_error=remote_error}
	if report then
		result.kind = "omr_support_report"
		result.schema_version = 2
		result.metadata = report_metadata()
	end
	return result
end

return M