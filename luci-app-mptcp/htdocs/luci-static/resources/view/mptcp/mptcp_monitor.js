'use strict';
'require view';
'require poll';
'require rpc';

var callStatus = rpc.declare({
	object: 'luci.mptcp', method: 'mptcp_status_data', expect: { '': {} }
});

var counterInfo = {
	MPTcpExtMPTCPRetrans: [_('MPTCP retransmissions'), _('Packets resent on an MPTCP connection')],
	MPTcpExtSubflowStale: [_('Stale subflows'), _('Paths marked stale by the kernel')],
	MPTcpExtDataCsumErr: [_('Checksum errors'), _('Received data failed its MPTCP checksum')],
	MPTcpExtDSSCorruptionReset: [_('DSS corruption resets'), _('Connections reset after invalid data sequence information')],
	MPTcpExtMPJoinSynAckHMacFailure: [_('JOIN authentication failures'), _('A subflow could not authenticate its JOIN')],
	MPTcpExtMPJoinAckHMacFailure: [_('JOIN authentication failures'), _('A subflow could not authenticate its JOIN')],
	MPTcpExtMPRstTx: [_('MPTCP resets sent'), _('MPTCP connections reset by this router')],
	MPTcpExtMPRstRx: [_('MPTCP resets received'), _('MPTCP connections reset by the peer')],
	MPTcpExtMPFastcloseTx: [_('Fast closes sent'), _('Abrupt connection closes sent')],
	MPTcpExtMPFastcloseRx: [_('Fast closes received'), _('Abrupt connection closes received')]
};

function pmName(v) {
	if (String(v) === '0') return _('In-kernel') + ' (0)';
	if (String(v) === '1') return _('Userspace') + ' (1)';
	return value(v);
}function value(v) { return v === null || v === undefined || v === '' ? '-' : String(v); }
function number(v) { var n = Number(v); return isFinite(n) ? n : 0; }
function bytes(v) {
	var n = number(v), units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return n.toFixed(i ? 1 : 0) + ' ' + units[i];
}
function cell(content, tag) { return E(tag || 'td', {}, content); }
function table(headers, rows) {
	return E('div', { 'class': 'omr-monitor-scroll' }, E('table', { 'class': 'omr-monitor-table' }, [
		E('thead', {}, E('tr', {}, headers.map(function(h) { return cell(h, 'th'); }))),
		E('tbody', {}, rows)
	]));
}
function badge(label, kind) { return E('span', { 'class': 'omr-monitor-badge ' + (kind || '') }, value(label)); }
function sessionPaths(p) {
	var seen = 0, single = 0, unknown = 0;
	(p.connections || []).forEach(function(c) {
		if (!c.is_mptcp) return;
		seen++;
		var raw = c.subflows_total;
		if (raw === '' || raw === null || raw === undefined) raw = c.subflows;
		if (raw === '' || raw === null || raw === undefined || !isFinite(Number(raw))) unknown++;
		else if (Number(raw) < 2) single++;
	});
	if (number((p.metrics || {}).mptcp_connection_count) > seen) unknown++;
	return { single: single, unknown: unknown };
}
function textBlock(title, detail) {
	return E('span', {}, [ E('strong', {}, value(title)), E('small', {}, value(detail)) ]);
}

return view.extend({
	_previousCounters: null,
	_busy: false,

	_set: function(id, child) {
		var node = document.getElementById(id);
		if (!node) return;
		while (node.firstChild) node.removeChild(node.firstChild);
		if (child != null) node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
	},

	_panel: function(title, description, id) {
		return E('section', { 'class': 'omr-monitor-panel' }, [
			E('h3', {}, title), E('p', { 'class': 'omr-monitor-muted' }, description),
			E('div', { 'id': id }, _('Loading…'))
		]);
	},

	render: function() {
		if (!document.querySelector('link[href*="mptcp_monitor.css"]')) {
			var link = document.createElement('link');
			link.rel = 'stylesheet';
			link.href = L.resource('mptcp/css/mptcp_monitor.css');
			document.head.appendChild(link);
		}
		this._previousCounters = null;
		var root = E('div', { 'class': 'omr-monitor' }, [
			E('div', { 'class': 'omr-monitor-hero' }, [
				E('div', {}, [ E('h2', {}, _('MPTCP monitoring')),
					E('p', {}, _('Live view of paths, connections, subflows and kernel events.')),
					E('p', { 'class': 'omr-monitor-muted' }, [ _('Last update'), ': ', E('span', { 'id': 'omr-monitor-updated' }, '-') ]) ]),
				E('span', { 'id': 'omr-monitor-state' }, badge(_('Loading'), 'info'))
			]),
			E('div', { 'class': 'omr-monitor-help' }, [
				textBlock(_('MPTCP'), _('One connection can use several TCP subflows.')),
				textBlock(_('Endpoint'), _('An IP address advertised to the MPTCP kernel.')),
				textBlock(_('Subflow'), _('A real TCP path beneath a connection.')),
				textBlock(_('Scheduler'), _('The algorithm that selects a path for packets.'))
			]),
			E('div', { 'id': 'omr-monitor-cards', 'class': 'omr-monitor-cards' }),
			this._panel(_('What needs attention'), _('Checks based on configured paths and changing kernel counters.'), 'omr-monitor-alerts'),
			this._panel(_('WAN paths and kernel endpoints'), _('Configured interface role compared with the endpoint visible to the kernel.'), 'omr-monitor-interfaces'),
			this._panel(_('Active MPTCP connections'), _('Logical sessions and their subflow counts.'), 'omr-monitor-connections'),
			this._panel(_('TCP subflows and path quality'), _('Real paths, latency and congestion information when available.'), 'omr-monitor-subflows'),
			this._panel(_('MPTCP event counters'), _('Totals since boot and changes since the previous refresh.'), 'omr-monitor-counters'),
			E('details', { 'class': 'omr-monitor-panel' }, [ E('summary', {}, _('Raw diagnostics for advanced troubleshooting')), E('pre', { 'id': 'omr-monitor-raw' }, '') ])
		]);
		poll.add(L.bind(this._update, this), 5);
		requestAnimationFrame(L.bind(this._update, this));
		return root;
	},

	_cards: function(p) {
		var k = p.kernel || {}, m = p.metrics || {}, sessions = number(m.mptcp_connection_count);
		var subflows = number(m.mptcp_subflow_count || m.tcp_subflow_count);
		var enabled = value(k.enabled) === '1';
		var active = number(m.active_path_count), configured = number(m.configured_path_count), sessionState = sessionPaths(p);
		var health = value(k.enabled) === '-' ? _('Unknown') : !enabled ? _('Disabled') : active < 2 ? _('Check paths') : sessionState.single ? _('Single path') : sessionState.unknown ? _('Unknown') : _('Healthy');
		var items = [
			[_('Health'), health, enabled && active >= 2 ? _('MPTCP available') : _('Needs attention')],
			[_('Paths'), String(active) + ' / ' + String(configured), _('usable / configured WAN paths')],
			[_('Connections'), value(m.mptcp_connection_count), _('active MPTCP sessions')],
			[_('Subflows'), String(subflows), _('active subflows')],
			[_('Scheduler'), value(k.scheduler), value(k.available_schedulers) !== '-' ? _('Available: ') + k.available_schedulers : _('current scheduler')],
			[_('Congestion'), value(k.congestion), _('TCP congestion control')],
			[_('Path manager'), pmName(k.pm_type || k.path_manager), _('path manager')],
			[_('Checksum'), value(k.checksum) === '1' ? _('Enabled') : value(k.checksum) === '0' ? _('Disabled') : value(k.checksum), _('MPTCP checksum')]
		];
		this._set('omr-monitor-cards', E('div', { 'class': 'omr-monitor-cards' }, items.map(function(item) {
			return E('div', { 'class': 'omr-monitor-card' }, [ E('small', {}, item[0]), E('strong', {}, item[1]), E('span', {}, item[2]) ]);
		})));
	},

	_alerts: function(p, map) {
		var k = p.kernel || {}, m = p.metrics || {}, alerts = [], old = this._previousCounters;
		var configured = number(m.configured_path_count), up = number(m.up_path_count), active = number(m.active_path_count), sessions = number(m.mptcp_connection_count), sessionState = sessionPaths(p);
		if (value(k.enabled) === '0') alerts.push(['error', _('MPTCP is disabled'), _('Enable MPTCP to use multiple paths.')]);
		if (configured < 2) alerts.push(['warning', _('Fewer than two MPTCP paths configured'), _('Aggregation needs at least two configured paths.')]);
		else if (active < 2) alerts.push(['warning', _('Fewer than two usable MPTCP paths'), _('Check WAN link state and kernel endpoints.')]);
		if (up > active) alerts.push(['warning', _('Kernel endpoint mismatch'), _('At least one up path has no kernel endpoint.')]);
		if (sessionState.single) alerts.push(['warning', _('MPTCP session uses one path'), _('At least one active session has fewer than two subflows.')]);
		if (sessionState.unknown) alerts.push(['info', _('Subflow count unavailable'), _('Some active sessions did not report a subflow count.')]);
		if (!sessions) alerts.push(['info', _('No active MPTCP session'), _('Start traffic through OMR to see live sessions.')]);
		Object.keys(counterInfo).forEach(function(name) {
			if (!old || old[name] == null || map[name] == null) return;
			var delta = number(map[name]) - number(old[name]);
			if (delta > 0) alerts.push([/CsumErr|Corruption|HMacFailure/.test(name) ? 'error' : 'warning', counterInfo[name][0], counterInfo[name][1] + ' (+' + delta + ')']);
		});
		if (!alerts.length) alerts.push(['ok', _('MPTCP looks healthy'), _('No immediate path or counter issues detected.')]);
		this._set('omr-monitor-alerts', E('div', { 'class': 'omr-monitor-alerts' }, alerts.map(function(a) {
			return E('div', { 'class': 'omr-monitor-alert ' + a[0] }, [ badge(a[0].toUpperCase(), a[0]), textBlock(a[1], a[2]) ]);
		})));
	},

	_interfaces: function(list) {
		if (!list.length) return this._set('omr-monitor-interfaces', _('No network interfaces were reported.'));
		var rows = list.map(function(i) {
			var ep = i.endpoint || {};
			var flags = ['signal', 'subflow', 'backup', 'fullmesh'].filter(function(f) { return ep[f]; });
			return E('tr', {}, [ cell(textBlock(i.label || i.name, i.device || i.proto)),
				cell(textBlock(i.multipath || 'off', i.proto)), cell(badge(i.up ? _('Up') : _('Down'), i.up ? 'ok' : 'warning')),
				cell((i.addresses || []).join(', ') || '-'),
				cell(i.has_endpoint ? value(ep.address || ep.dev) : i.multipath === 'off' ? _('Not used') : badge(_('Missing'), 'warning')),
				cell(flags.join(', ') || '-') ]);
		});
		this._set('omr-monitor-interfaces', table([_('Interface'), _('Role'), _('State'), _('Address'), _('Kernel endpoint'), _('Flags')], rows));
	},

	_connections: function(list) {
		var rows = list.filter(function(c) { return c.is_mptcp; }).map(function(c) {
			var sf = value(c.subflows_total || c.subflows), max = c.subflows_max ? ' / ' + c.subflows_max : '';
			return E('tr', {}, [ cell(textBlock(c.local_addr, c.peer_addr)), cell(badge(sf + max, number(sf) > 1 ? 'ok' : 'warning')),
				cell([_('Sent: '), bytes(c.bytes_sent), E('br'), _('Received: '), bytes(c.bytes_received), E('br'), _('Acked: '), bytes(c.bytes_acked)]),
				cell([_('TX: '), value(c.last_data_sent), E('br'), _('RX: '), value(c.last_data_recv), E('br'), _('ACK: '), value(c.last_ack_recv)]),
				cell(_('Logical connection; subflows below show its actual paths.')) ]);
		});
		this._set('omr-monitor-connections', rows.length ? table([_('Connection'), _('Subflows'), _('Traffic'), _('Last activity (ms)'), _('Meaning')], rows) : _('No established MPTCP connection. Generate traffic through the router to populate this table.'));
	},

	_subflows: function(list) {
		var rows = list.filter(function(c) { return c.is_subflow; }).map(function(c) {
			return E('tr', {}, [ cell(textBlock(c.local_addr, c.peer_addr)),
				cell([_('Recv: '), value(c.recvq), E('br'), _('Send: '), value(c.sendq)]),
				cell([_('RTT: '), value(c.rtt), ' ms', E('br'), _('BBR bw: '), value(c.bbr_bw), E('br'), _('BBR min RTT: '), value(c.bbr_mrtt)]),
				cell(['cwnd ', value(c.cwnd), E('br'), 'mss ', value(c.mss), E('br'), 'pmtu ', value(c.pmtu)]),
				cell(_('Lower RTT and stable BBR bandwidth usually indicate a better path.')) ]);
		});
		this._set('omr-monitor-subflows', rows.length ? table([_('Path'), _('Queue'), _('RTT / BBR'), _('Window'), _('Meaning')], rows) : _('No individual TCP subflow is visible.'));
	},

	_counters: function(p, map) {
		var old = this._previousCounters, names = Object.keys(map).sort(function(a, b) { return (counterInfo[a] ? 0 : 1) - (counterInfo[b] ? 0 : 1) || a.localeCompare(b); });
		if (!names.length) return this._set('omr-monitor-counters', _('No MPTCP counter was reported.'));
		var rows = names.filter(function(name) { return counterInfo[name] || number(map[name]) > 0; }).map(function(name) {
			var info = counterInfo[name] || [name, _('Kernel MPTCP diagnostic counter')];
			var delta = old && old[name] != null ? number(map[name]) - number(old[name]) : null;
			return E('tr', {}, [ cell(textBlock(info[0], name)), cell(String(map[name])),
				cell(badge(delta == null || delta < 0 ? '-' : delta ? '+' + delta : '0', delta > 0 ? 'warning' : '')),
				cell(info[1]) ]);
		});
		this._set('omr-monitor-counters', table([_('Counter'), _('Value'), _('Delta'), _('Description')], rows));
	},

	_update: function() {
		if (this._busy) return Promise.resolve();
		this._busy = true;
		var self = this;
		return callStatus().then(function(p) {
			var map = p.counter_map || {};
			(p.counters || []).forEach(function(c) { map[c.name] = c.value; });
			self._set('omr-monitor-state', badge(_('Live'), 'ok'));
			self._set('omr-monitor-updated', p.generated ? new Date(number(p.generated) * 1000).toLocaleTimeString() : _('now'));
			self._cards(p);
			self._alerts(p, map);
			self._interfaces(p.interfaces || []);
			self._connections(p.connections || []);
			self._subflows(p.connections || []);
			self._counters(p, map);
			var raw = p.raw || {};
			self._set('omr-monitor-raw', 'ip mptcp endpoint show\n' + value(raw.endpoints) + '\n\nss -Mtin\n' + value(raw.ss) + '\n\nnstat -az MPTcpExt\n' + value(raw.nstat) + '\n\nmultipath -m\n' + value(raw.monitor));
			self._previousCounters = Object.assign({}, map);
			self._busy = false;
		}).catch(function(err) {
			self._busy = false;
			self._set('omr-monitor-state', badge(_('Error'), 'error'));
			self._set('omr-monitor-alerts', E('div', { 'class': 'omr-monitor-alert error' }, [ badge('ERR', 'error'), textBlock(_('Unable to read MPTCP monitoring data'), err && err.message || _('RPC request failed')) ]));
		});
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
