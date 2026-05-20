-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Copyright 2011 Jo-Philipp Wich <jow@openwrt.org>
-- Copyright 2018-2023 Ycarus (Yannick Chabanois) <ycarus@zugaina.org>
-- Licensed to the public under the Apache License 2.0.

module("luci.controller.mptcp", package.seeall)


function index()
	local uname = nixio.uname()
	entry({"admin", "network", "mptcp"}, alias("admin", "network", "mptcp", "settings"), _("MPTCP"))
	if uname ~= nil and uname.release:sub(1,1) == "5" then
		entry({"admin", "network", "mptcp", "settings"}, cbi("mptcp"), _("Settings"),2).leaf = true
	else
		entry({"admin", "network", "mptcp", "settings"}, view("mptcp/mptcp"), _("Settings"),2).leaf = true
	end
	entry({"admin", "network", "mptcp", "bandwidth"}, template("mptcp/multipath"), _("Bandwidth"), 3).leaf = true
	entry({"admin", "network", "mptcp", "multipath_bandwidth"}, call("multipath_bandwidth")).leaf = true
	entry({"admin", "network", "mptcp", "interface_bandwidth"}, call("interface_bandwidth")).leaf = true
	if uname ~= nil and uname.release:sub(1,1) == "5" then
		entry({"admin", "network", "mptcp", "mptcp_check"}, template("mptcp/mptcp_check"), _("MPTCP Support Check"), 4).leaf = true
	end
	entry({"admin", "network", "mptcp", "mptcp_check_trace"}, post("mptcp_check_trace")).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_fullmesh"}, template("mptcp/mptcp_fullmesh"), _("MPTCP Fullmesh"), 5).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_fullmesh_data"}, post("mptcp_fullmesh_data")).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_connections"}, template("mptcp/mptcp_connections"), _("Established connections"), 6).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_connections_data"}, post("mptcp_connections_data")).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_status_data"}, call("mptcp_status_data")).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_monitor"}, template("mptcp/mptcp_monitor"), _("MPTCP monitoring"), 6).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_monitor_data"}, post("mptcp_monitor_data")).leaf = true
end

local function parse_bwc_output(raw)
	local jsonc = require "luci.jsonc"
	local rows = {}

	raw = raw or ""
	raw = raw:gsub("[%r\n]+", "")
	raw = raw:gsub("%]%s*,?%s*%[", "],[")
	raw = raw:gsub(",%s*$", "")

	if raw == "" then
		return rows
	end

	local candidates = {}
	if raw:sub(1, 2) == "[[" then
		candidates[#candidates + 1] = raw
	end
	candidates[#candidates + 1] = "[" .. raw .. "]"

	for _, candidate in ipairs(candidates) do
		local ok, parsed = pcall(jsonc.parse, candidate)
		if ok and type(parsed) == "table" then
			for _, row in ipairs(parsed) do
				if type(row) == "table" and #row >= 5 then
					local clean = {
						tonumber(row[1]) or 0,
						tonumber(row[2]) or 0,
						tonumber(row[3]) or 0,
						tonumber(row[4]) or 0,
						tonumber(row[5]) or 0
					}
					if clean[1] > 0 then
						rows[#rows + 1] = clean
					end
				end
			end
			table.sort(rows, function(a, b) return a[1] < b[1] end)
			return rows
		end
	end

	return rows
end

function interface_bandwidth(iface)
	luci.http.prepare_content("application/json")
	local raw = luci.sys.exec("luci-bwc -i %q 2>/dev/null" % iface) or ""
	luci.http.write_json(parse_bwc_output(raw))
end


function multipath_bandwidth()
	local result = { }
	local total_by_time = { }
	local uci = luci.model.uci.cursor()

	uci:foreach("network", "interface", function(s)
		local intname = s[".name"]
		local label = s["label"]
		local dev = get_device(intname)
		if dev == "" then
			dev = get_device(s["device"])
			if dev == "" then
				dev = get_device(s["ifname"])
			end
		end

		local multipath = s["multipath"] or ""
		if dev ~= "lo" and dev ~= "" then
			if multipath == "" then
				multipath = uci:get("openmptcprouter", intname, "multipath") or ""
			end
			if multipath == "" then
				multipath = "off"
			end
			if multipath == "on" or multipath == "master" or multipath == "backup" or multipath == "handover" then
				local rows = parse_bwc_output(luci.sys.exec("luci-bwc -i %q 2>/dev/null" % dev) or "")
				local key = label and (intname .. " (" .. label .. ")") or intname
				result[key] = rows

				for _, row in ipairs(rows) do
					local t = row[1]
					if not total_by_time[t] then
						total_by_time[t] = { t, 0, 0, 0, 0 }
					end
					total_by_time[t][2] = total_by_time[t][2] + row[2]
					total_by_time[t][3] = total_by_time[t][3] + row[3]
					total_by_time[t][4] = total_by_time[t][4] + row[4]
					total_by_time[t][5] = total_by_time[t][5] + row[5]
				end
			end
		end
	end)

	result["total"] = {}
	for _, row in pairs(total_by_time) do
		result["total"][#result["total"] + 1] = row
	end
	table.sort(result["total"], function(a, b) return a[1] < b[1] end)

	luci.http.prepare_content("application/json")
	luci.http.write_json(result)
end

function get_device(interface)
	if not interface or interface == "" then
		return ""
	end
	local dump = require("luci.util").ubus("network.interface.%s" % interface, "status", {})
	if dump and dump['l3_device'] then
		return dump['l3_device']
	else
		return ""
	end
end

local function trim(value)
	return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function read_first(paths)
	for _, path in ipairs(paths) do
		local fh = io.open(path, "r")
		if fh then
			local value = trim(fh:read("*l") or "")
			fh:close()
			if value ~= "" then
				return value
			end
		end
	end
	return ""
end

local function parse_endpoint_line(line)
	local endpoint = { raw = line, flags = {} }
	local tokens = {}

	for token in line:gmatch("%S+") do
		tokens[#tokens + 1] = token
	end

	for i, token in ipairs(tokens) do
		if i == 1 then
			endpoint.address = token
		elseif token == "id" and tokens[i + 1] then
			endpoint.id = tokens[i + 1]
		elseif token == "dev" and tokens[i + 1] then
			endpoint.dev = tokens[i + 1]
		elseif token == "subflow" or token == "signal" or token == "backup" or token == "fullmesh" then
			endpoint.flags[#endpoint.flags + 1] = token
		end
	end

	return endpoint
end

local function parse_endpoints(raw)
	local endpoints = {}

	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" then
			endpoints[#endpoints + 1] = parse_endpoint_line(line)
		end
	end

	return endpoints
end

local function parse_ss_value(details, key)
	local value = details:match(key .. "[:=]([%w%.%-]+)")
	return value or ""
end

local function parse_ss_mptcp(raw)
	local connections = {}
	local current = nil

	for line in (raw or ""):gmatch("[^\r\n]+") do
		if line:match("^Netid%s+") then
			-- Header line.
		elseif line:match("^%S") then
			current = { summary = trim(line), details = {} }
			connections[#connections + 1] = current
		elseif current then
			current.details[#current.details + 1] = trim(line)
		end
	end

	for _, conn in ipairs(connections) do
		local details = table.concat(conn.details, " ")
		conn.token = parse_ss_value(details, "token")
		conn.subflows = parse_ss_value(details, "subflows")
		conn.subflows_total = parse_ss_value(details, "subflows_total")
		conn.bytes_sent = parse_ss_value(details, "bytes_sent")
		conn.bytes_received = parse_ss_value(details, "bytes_received")
		conn.bytes_acked = parse_ss_value(details, "bytes_acked")
		conn.last_data_sent = parse_ss_value(details, "last_data_sent")
		conn.last_data_recv = parse_ss_value(details, "last_data_recv")
		conn.last_ack_recv = parse_ss_value(details, "last_ack_recv")
	end

	return connections
end

function mptcp_status_data()
	local endpoint_raw = luci.sys.exec("ip mptcp endpoint show 2>/dev/null") or ""
	local ss_raw = luci.sys.exec("ss -Mtin 2>/dev/null") or ""
	local available_schedulers = read_first({"/proc/sys/net/mptcp/available_schedulers"})

	luci.http.prepare_content("application/json")
	luci.http.write_json({
		kernel = {
			enabled = read_first({"/proc/sys/net/mptcp/enabled", "/proc/sys/net/mptcp/mptcp_enabled"}),
			scheduler = read_first({"/proc/sys/net/mptcp/scheduler", "/proc/sys/net/mptcp/mptcp_scheduler"}),
			available_schedulers = available_schedulers,
			pm_type = read_first({"/proc/sys/net/mptcp/pm_type"}),
			path_manager = read_first({"/proc/sys/net/mptcp/mptcp_path_manager"}),
			checksum = read_first({"/proc/sys/net/mptcp/checksum_enabled", "/proc/sys/net/mptcp/mptcp_checksum"}),
			add_addr_timeout = read_first({"/proc/sys/net/mptcp/add_addr_timeout"}),
			stale_loss_cnt = read_first({"/proc/sys/net/mptcp/stale_loss_cnt"}),
			congestion = read_first({"/proc/sys/net/ipv4/tcp_congestion_control"})
		},
		endpoints = parse_endpoints(endpoint_raw),
		connections = parse_ss_mptcp(ss_raw),
		raw = {
			endpoints = endpoint_raw,
			ss = ss_raw
		}
	})
end

function mptcp_check_trace(iface)
	luci.http.prepare_content("text/plain")
	local tracebox
	local uci    = require "luci.model.uci".cursor()
	local interface = get_device(iface)
	local server = uci:get("shadowsocks-libev", "sss0", "server") or ""
	if server == "" then return end
	if interface == "" then
		tracebox = io.popen("tracebox -s /usr/share/tracebox/omr-mptcp-trace.lua " .. server)
	else
		tracebox = io.popen("tracebox -s /usr/share/tracebox/omr-mptcp-trace.lua -i " .. interface .. " " .. server)
	end
	if tracebox then
		while true do
			local ln = tracebox:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
		tracebox:close()
	end
	return
end

function mptcp_fullmesh_data()
	luci.http.prepare_content("text/plain")
	local fullmesh
	fullmesh = io.popen("multipath -f")
	if fullmesh then
		while true do
			local ln = fullmesh:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
		fullmesh:close()
	end
	return
end

function mptcp_monitor_data()
	luci.http.prepare_content("text/plain")
	local fullmesh
	fullmesh = io.popen("multipath -m")
	if fullmesh then
		while true do
			local ln = fullmesh:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
		fullmesh:close()
	end
	return
end

function mptcp_connections_data()
	luci.http.prepare_content("text/plain")
	local connections
	connections = io.popen("multipath -c")
	if connections then
		while true do
			local ln = connections:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
		connections:close()
	end
	return
end
