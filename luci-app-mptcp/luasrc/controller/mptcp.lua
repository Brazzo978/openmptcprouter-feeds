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
		entry({"admin", "network", "mptcp", "mptcp_paths"}, template("mptcp/mptcp_paths"), _("Path live"), 4).leaf = true
		entry({"admin", "network", "mptcp", "mptcp_paths_data"}, post("mptcp_paths_data")).leaf = true
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

local function read_number(paths)
	local value = tonumber(read_first(paths))
	return value or 0
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

local function normalize_socket_host(value)
	local host = value or ""

	if host:sub(1, 1) == "[" then
		host = host:match("^%[([^%]]+)%]") or host
	else
		host = host:match("^(.+):%d+$") or host
	end

	host = host:gsub("%%.*$", "")
	host = host:gsub("^::ffff:", "")

	return host
end

local function parse_ss_pair(details, key)
	local first, second = details:match(key .. ":([%d%.]+)%/([%d%.]+)")
	return first or "", second or ""
end

local function parse_ss_token(details, key)
	for token in (details or ""):gmatch("%S+") do
		local value = token:match("^" .. key .. "[:=](.+)$")
		if value then
			return value:gsub("[,%)]$", "")
		end
	end
	return ""
end

local function parse_ss_after(details, key)
	local want_next = false
	for token in (details or ""):gmatch("%S+") do
		if want_next then
			return token:gsub("[,%)]$", "")
		end
		if token == key then
			want_next = true
		end
	end
	return ""
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
		local tokens = {}

		for token in (conn.summary or ""):gmatch("%S+") do
			tokens[#tokens + 1] = token
		end

		conn.netid = tokens[1] or ""
		conn.state = tokens[2] or ""
		conn.recvq = tokens[3] or ""
		conn.sendq = tokens[4] or ""
		conn.local_addr = tokens[5] or ""
		conn.peer_addr = tokens[6] or ""
		conn.local_host = normalize_socket_host(conn.local_addr)
		conn.peer_host = normalize_socket_host(conn.peer_addr)
		conn.is_mptcp = (conn.netid == "mptcp")
		conn.is_subflow = (not conn.is_mptcp and details:match("tcp%-ulp%-mptcp") ~= nil)
		conn.token = parse_ss_value(details, "token")
		conn.subflows = parse_ss_value(details, "subflows")
		conn.subflows_total = parse_ss_value(details, "subflows_total")
		conn.subflows_max = parse_ss_value(details, "subflows_max")
		conn.local_addr_used = parse_ss_value(details, "local_addr_used")
		conn.local_addr_max = parse_ss_value(details, "local_addr_max")
		conn.add_addr_accepted_max = parse_ss_value(details, "add_addr_accepted_max")
		conn.bytes_sent = parse_ss_value(details, "bytes_sent")
		conn.bytes_received = parse_ss_value(details, "bytes_received")
		conn.bytes_acked = parse_ss_value(details, "bytes_acked")
		conn.last_data_sent = parse_ss_value(details, "last_data_sent")
		conn.last_data_recv = parse_ss_value(details, "last_data_recv")
		conn.last_ack_recv = parse_ss_value(details, "last_ack_recv")
		conn.cwnd = parse_ss_value(details, "cwnd")
		conn.mss = parse_ss_value(details, "mss")
		conn.pmtu = parse_ss_value(details, "pmtu")
		conn.minrtt = parse_ss_value(details, "minrtt")
		conn.delivery_rate = parse_ss_value(details, "delivery_rate")
		if conn.delivery_rate == "" then
			conn.delivery_rate = parse_ss_after(details, "delivery_rate")
		end
		conn.pacing_rate = parse_ss_value(details, "pacing_rate")
		if conn.pacing_rate == "" then
			conn.pacing_rate = parse_ss_after(details, "pacing_rate")
		end
		conn.send_rate = parse_ss_after(details, "send")
		conn.rto = parse_ss_value(details, "rto")
		conn.ato = parse_ss_value(details, "ato")
		conn.rcvmss = parse_ss_value(details, "rcvmss")
		conn.advmss = parse_ss_value(details, "advmss")
		conn.snd_wnd = parse_ss_value(details, "snd_wnd")
		conn.rcv_wnd = parse_ss_value(details, "rcv_wnd")
		conn.rcv_space = parse_ss_value(details, "rcv_space")
		conn.rcv_ssthresh = parse_ss_value(details, "rcv_ssthresh")
		conn.rcv_rtt = parse_ss_value(details, "rcv_rtt")
		conn.unacked = parse_ss_value(details, "unacked")
		conn.retrans = parse_ss_token(details, "retrans")
		conn.lost = parse_ss_value(details, "lost")
		conn.reordering = parse_ss_value(details, "reordering")
		conn.reord_seen = parse_ss_value(details, "reord_seen")
		conn.segs_out = parse_ss_value(details, "segs_out")
		conn.segs_in = parse_ss_value(details, "segs_in")
		conn.data_segs_out = parse_ss_value(details, "data_segs_out")
		conn.data_segs_in = parse_ss_value(details, "data_segs_in")
		conn.delivered = parse_ss_value(details, "delivered")
		conn.busy = parse_ss_value(details, "busy")
		conn.app_limited = details:match("%f[%w]app_limited%f[%W]") ~= nil
		conn.rtt, conn.rttvar = parse_ss_pair(details, "rtt")
		conn.bbr_bw = details:match("bbr:%(bw:([^,%s%)]+)") or ""
		conn.bbr_mrtt = details:match("mrtt:([^,%s%)]+)") or ""
		conn.bbr_pacing_gain = details:match("pacing_gain:([^,%s%)]+)") or ""
		conn.bbr_cwnd_gain = details:match("cwnd_gain:([^,%s%)]+)") or ""
	end

	return connections
end

local function collect_mptcp_status()
	local endpoint_raw = luci.sys.exec("ip mptcp endpoint show 2>/dev/null") or ""
	local ss_raw = luci.sys.exec("ss -Mtin 2>/dev/null") or ""
	local available_schedulers = read_first({"/proc/sys/net/mptcp/available_schedulers"})

	return {
		kernel = {
			enabled = read_first({"/proc/sys/net/mptcp/enabled", "/proc/sys/net/mptcp/mptcp_enabled"}),
			scheduler = read_first({"/proc/sys/net/mptcp/scheduler", "/proc/sys/net/mptcp/mptcp_scheduler"}),
			available_schedulers = available_schedulers,
			pm_type = read_first({"/proc/sys/net/mptcp/pm_type"}),
			path_manager = read_first({"/proc/sys/net/mptcp/mptcp_path_manager"}),
			checksum = read_first({"/proc/sys/net/mptcp/checksum_enabled", "/proc/sys/net/mptcp/mptcp_checksum"}),
			add_addr_accepted = read_first({"/proc/sys/net/mptcp/add_addr_accepted"}),
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
	}
end

local function list_has_value(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then
			return true
		end
	end
	return false
end

local function collect_mptcp_interfaces(endpoints)
	local interfaces = {}
	local uci = luci.model.uci.cursor()
	local util = require "luci.util"

	uci:foreach("network", "interface", function(s)
		local name = s[".name"] or ""
		local hidden = name == "loopback" or name == "omrvpn" or name == "omr6in4" or name:match("^oip")
		if hidden then
			return
		end

		local dump = util.ubus("network.interface.%s" % name, "status", {}) or {}
		local dev = dump.l3_device or get_device(name)
		if dev == "" then
			dev = dump.device or s["device"] or s["ifname"] or ""
		end

		local addresses = {}
		for _, addr in ipairs(dump["ipv4-address"] or {}) do
			if addr.address then
				addresses[#addresses + 1] = addr.address
			end
		end
		for _, addr in ipairs(dump["ipv6-address"] or {}) do
			if addr.address then
				addresses[#addresses + 1] = addr.address
			end
		end

		local multipath = s["multipath"] or ""
		if multipath == "" then
			multipath = uci:get("openmptcprouter", name, "multipath") or ""
		end
		if multipath == "" then
			multipath = "off"
		end

		local matched_endpoint = nil
		for _, endpoint in ipairs(endpoints or {}) do
			if (dev ~= "" and endpoint.dev == dev) or list_has_value(addresses, endpoint.address) then
				matched_endpoint = endpoint
				break
			end
		end

		interfaces[#interfaces + 1] = {
			name = name,
			label = s["label"] or "",
			device = dev,
			proto = dump.proto or s["proto"] or "",
			up = dump.up == true,
			uptime = dump.uptime or 0,
			addresses = addresses,
			multipath = multipath,
			has_endpoint = matched_endpoint ~= nil,
			endpoint = matched_endpoint
		}
	end)

	table.sort(interfaces, function(a, b) return (a.name or "") < (b.name or "") end)
	return interfaces
end

local function read_interface_stats(dev)
	if not dev or dev == "" then
		return {}
	end

	local base = "/sys/class/net/" .. dev

	return {
		rx_bytes = read_number({base .. "/statistics/rx_bytes"}),
		tx_bytes = read_number({base .. "/statistics/tx_bytes"}),
		rx_packets = read_number({base .. "/statistics/rx_packets"}),
		tx_packets = read_number({base .. "/statistics/tx_packets"}),
		rx_errors = read_number({base .. "/statistics/rx_errors"}),
		tx_errors = read_number({base .. "/statistics/tx_errors"}),
		rx_dropped = read_number({base .. "/statistics/rx_dropped"}),
		tx_dropped = read_number({base .. "/statistics/tx_dropped"}),
		carrier = read_first({base .. "/carrier"}),
		operstate = read_first({base .. "/operstate"}),
		speed_mbps = read_number({base .. "/speed"})
	}
end

local function host_matches_interface(host, iface)
	if not host or host == "" or not iface then
		return false
	end

	for _, addr in ipairs(iface.addresses or {}) do
		if addr == host then
			return true
		end
	end

	if iface.endpoint and iface.endpoint.address == host then
		return true
	end

	return false
end

local function subflow_device(conn, interfaces)
	for _, iface in ipairs(interfaces or {}) do
		if host_matches_interface(conn.local_host, iface) then
			return iface.device or ""
		end
	end

	local zone = (conn.local_addr or ""):match("%%([^:%]]+)")
	if zone and zone ~= "" then
		return zone
	end

	return ""
end

local function parse_mptcp_counters(raw)
	local counters = {}
	local counter_map = {}

	for line in (raw or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		local name, value, rate = line:match("^(MPTcpExt%S+)%s+([%-]?%d+)%s+([%-]?[%d%.]+)")
		if not name then
			name, value = line:match("^(MPTcpExt%S+)%s+([%-]?%d+)")
		end
		if name and value then
			local item = {
				name = name,
				value = tonumber(value) or 0,
				rate = tonumber(rate) or 0
			}
			counters[#counters + 1] = item
			counter_map[name] = item.value
		end
	end

	return counters, counter_map
end

local function build_mptcp_metrics(status, interfaces)
	local mptcp_connections = 0
	local mptcp_subflows = 0
	local tcp_subflows = 0
	local active_paths = 0

	for _, iface in ipairs(interfaces or {}) do
		if iface.multipath == "on" or iface.multipath == "master" or iface.multipath == "backup" or iface.multipath == "handover" then
			active_paths = active_paths + 1
		end
	end

	for _, conn in ipairs(status.connections or {}) do
		if conn.is_mptcp then
			mptcp_connections = mptcp_connections + 1
			mptcp_subflows = mptcp_subflows + (tonumber(conn.subflows_total) or tonumber(conn.subflows) or 0)
		elseif conn.is_subflow then
			tcp_subflows = tcp_subflows + 1
		end
	end

	return {
		endpoint_count = #(status.endpoints or {}),
		interface_count = #(interfaces or {}),
		active_path_count = active_paths,
		connection_count = #(status.connections or {}),
		mptcp_connection_count = mptcp_connections,
		mptcp_subflow_count = mptcp_subflows,
		tcp_subflow_count = tcp_subflows
	}
end

function mptcp_status_data()
	luci.http.prepare_content("application/json")
	luci.http.write_json(collect_mptcp_status())
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
	local status = collect_mptcp_status()
	local monitor_raw = luci.sys.exec("multipath -m 2>/dev/null") or ""
	local nstat_raw = luci.sys.exec("nstat -az 2>/dev/null | grep -i '^MPTcpExt'") or ""
	local counter_source = nstat_raw ~= "" and nstat_raw or monitor_raw
	local counters, counter_map = parse_mptcp_counters(counter_source)
	local interfaces = collect_mptcp_interfaces(status.endpoints)

	status.interfaces = interfaces
	status.counters = counters
	status.counter_map = counter_map
	status.metrics = build_mptcp_metrics(status, interfaces)
	status.generated = os.time()
	status.raw.monitor = monitor_raw
	status.raw.nstat = nstat_raw

	luci.http.prepare_content("application/json")
	luci.http.write_json(status)
end

function mptcp_paths_data()
	local status = collect_mptcp_status()
	local interfaces = collect_mptcp_interfaces(status.endpoints)
	local paths = {}
	local by_dev = {}

	for _, iface in ipairs(interfaces or {}) do
		local role = iface.multipath or "off"
		if iface.device ~= "" and (role == "on" or role == "master" or role == "backup" or role == "handover") then
			local path = {
				name = iface.name,
				label = iface.label,
				device = iface.device,
				role = role,
				up = iface.up,
				addresses = iface.addresses,
				endpoint = iface.endpoint,
				has_endpoint = iface.has_endpoint,
				stats = read_interface_stats(iface.device),
				subflows = {},
				subflow_count = 0
			}

			paths[#paths + 1] = path
			by_dev[iface.device] = path
		end
	end

	for _, conn in ipairs(status.connections or {}) do
		if conn.is_subflow then
			local dev = subflow_device(conn, interfaces)
			local path = by_dev[dev]
			if path then
				path.subflow_count = path.subflow_count + 1
				path.subflows[#path.subflows + 1] = {
					key = (conn.local_addr or "") .. ">" .. (conn.peer_addr or "") .. ":" .. (conn.token or ""),
					local_addr = conn.local_addr,
					peer_addr = conn.peer_addr,
					local_host = conn.local_host,
					peer_host = conn.peer_host,
					bytes_sent = tonumber(conn.bytes_sent) or 0,
					bytes_received = tonumber(conn.bytes_received) or 0,
					bytes_acked = tonumber(conn.bytes_acked) or 0,
					recvq = tonumber(conn.recvq) or 0,
					sendq = tonumber(conn.sendq) or 0,
					rtt = tonumber(conn.rtt) or 0,
					rttvar = tonumber(conn.rttvar) or 0,
					cwnd = tonumber(conn.cwnd) or 0,
					minrtt = tonumber(conn.minrtt) or 0,
					mss = tonumber(conn.mss) or 0,
					pmtu = tonumber(conn.pmtu) or 0,
					rcvmss = tonumber(conn.rcvmss) or 0,
					advmss = tonumber(conn.advmss) or 0,
					snd_wnd = tonumber(conn.snd_wnd) or 0,
					rcv_wnd = tonumber(conn.rcv_wnd) or 0,
					rcv_space = tonumber(conn.rcv_space) or 0,
					rcv_ssthresh = tonumber(conn.rcv_ssthresh) or 0,
					rcv_rtt = tonumber(conn.rcv_rtt) or 0,
					unacked = tonumber(conn.unacked) or 0,
					retrans = conn.retrans,
					lost = tonumber(conn.lost) or 0,
					reordering = tonumber(conn.reordering) or 0,
					reord_seen = tonumber(conn.reord_seen) or 0,
					segs_out = tonumber(conn.segs_out) or 0,
					segs_in = tonumber(conn.segs_in) or 0,
					data_segs_out = tonumber(conn.data_segs_out) or 0,
					data_segs_in = tonumber(conn.data_segs_in) or 0,
					delivered = tonumber(conn.delivered) or 0,
					busy = conn.busy,
					app_limited = conn.app_limited,
					bbr_bw = conn.bbr_bw,
					bbr_mrtt = conn.bbr_mrtt,
					bbr_pacing_gain = conn.bbr_pacing_gain,
					bbr_cwnd_gain = conn.bbr_cwnd_gain,
					delivery_rate = conn.delivery_rate,
					pacing_rate = conn.pacing_rate,
					send_rate = conn.send_rate,
					rto = conn.rto,
					ato = conn.ato
				}
			end
		end
	end

	table.sort(paths, function(a, b)
		local order = { master = 1, on = 2, backup = 3, handover = 4, off = 5 }
		local ao = order[a.role or "off"] or 9
		local bo = order[b.role or "off"] or 9
		if ao ~= bo then
			return ao < bo
		end
		return (a.name or "") < (b.name or "")
	end)

	luci.http.prepare_content("application/json")
	luci.http.write_json({
		generated = os.time(),
		kernel = status.kernel,
		metrics = build_mptcp_metrics(status, interfaces),
		paths = paths,
		raw = {
			endpoints = status.raw.endpoints,
			ss = status.raw.ss
		}
	})
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
