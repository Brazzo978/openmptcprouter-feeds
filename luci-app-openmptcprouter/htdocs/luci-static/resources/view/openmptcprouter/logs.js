'use strict';
'require view';
'require rpc';
'require poll';

var callLogs = rpc.declare({
	object: 'openmptcprouter',
	method: 'diagnostic_logs',
	params: [ 'limit', 'scope' ],
	expect: { '': {} }
});
var callReport = rpc.declare({
	object: 'openmptcprouter',
	method: 'support_report',
	expect: { '': {} }
});

var componentLabels = {
	mqvpn: 'MQVPN', vpn: 'VPN', wan: 'WAN', mptcp: 'MPTCP',
	vps_sync: 'VPS sync', firewall: 'Firewall', network: 'Network',
	security: 'Security', system: 'System'
};

function option(value, label) {
	return E('option', { value: value }, label);
}

function dateText(timestamp) {
	var n = Number(timestamp);
	return isFinite(n) && n > 0 ? new Date(n * 1000).toLocaleString() : '-';
}

return view.extend({
	load: function() {
		return callLogs(500, 'all').catch(function() { return { entries: [], error: _('Unable to load logs') }; });
	},

	render: function(data) {
		this.entries = Array.isArray(data.entries) ? data.entries : [];
		this.snapshot = data.snapshot || {};
		this.generatedAt = data.generated_at;
		this.vpsError = data.vps_error || data.error || '';
		this.busy = false;
		var style = E('style', {}, [
			'.omr-log-toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:end;margin:12px 0}',
			'.omr-log-control{min-width:130px}.omr-log-control label{display:block;font-size:12px;font-weight:600;margin-bottom:3px}',
			'.omr-log-control select,.omr-log-control input{box-sizing:border-box;height:32px;width:100%}',
			'.omr-log-search{flex:1;min-width:190px}.omr-log-actions{display:flex;gap:6px;margin-left:auto;align-items:center}',
			'.omr-log-summary{display:grid;grid-template-columns:repeat(6,minmax(90px,1fr));border:1px solid #d5d8dc;margin:10px 0}',
			'.omr-log-summary>div{padding:8px 10px;border-right:1px solid #d5d8dc;min-width:0}',
			'.omr-log-summary span{display:block;color:#687078;font-size:11px}',
			'.omr-log-summary strong{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
			'.omr-log-state{display:flex;justify-content:space-between;gap:12px;min-height:22px;font-size:12px;color:#687078}',
			'.omr-log-table-wrap{overflow:auto;border:1px solid #d5d8dc;max-height:62vh}',
			'.omr-log-table{width:100%;border-collapse:collapse;font-size:12px}',
			'.omr-log-table th{position:sticky;top:0;z-index:1;background:#f4f5f6;text-align:left;padding:7px 8px;border-bottom:1px solid #c8ccd0}',
			'.omr-log-table td{padding:6px 8px;border-bottom:1px solid #e6e8ea;vertical-align:top}',
			'.omr-log-table .time{white-space:nowrap;width:145px}.omr-log-table .scope{width:55px}',
			'.omr-log-table .source{width:125px;word-break:break-word}',
			'.omr-log-table .severity{width:62px;font-weight:600;text-transform:uppercase}',
			'.omr-log-table .message{font-family:monospace;white-space:pre-wrap;word-break:break-word}',
			'.omr-log-table tr.error{border-left:3px solid #c0392b}.omr-log-table tr.warning{border-left:3px solid #d68910}',
			'.omr-log-table tr.notice{border-left:3px solid #2874a6}.omr-log-table tr.debug{border-left:3px solid #a6acaf;color:#687078}',
			'.omr-log-empty{padding:24px;text-align:center;color:#687078}',
			'@media(max-width:900px){.omr-log-summary{grid-template-columns:repeat(3,1fr)}.omr-log-actions{margin-left:0}}',
			'@media(max-width:560px){.omr-log-summary{grid-template-columns:repeat(2,1fr)}.omr-log-control{width:calc(50% - 4px);min-width:0}.omr-log-search{width:100%}.omr-log-actions{width:100%}}'
		].join(''));
		var summary = E('div', { class: 'omr-log-summary' });
		var fields = [ ['vpn', _('VPN')], ['tunnel', _('Tunnel')], ['wans', _('WANs online')],
			['cc', _('Congestion control')], ['errors', _('Errors')], ['warnings', _('Warnings')] ];
		fields.forEach(function(field) {
			summary.appendChild(E('div', {}, [ E('span', {}, field[1]), E('strong', { id: 'omr-log-' + field[0] }, '-') ]));
		});
		var scope = E('select', { id: 'omr-log-scope' }, [
			option('all', _('Router and VPS')), option('router', _('Router')), option('vps', _('VPS'))
		]);
		var severity = E('select', { id: 'omr-log-severity' }, [
			option('all', _('All')), option('error', _('Errors')), option('warning', _('Warnings')),
			option('notice', _('Notices')), option('info', _('Information')), option('debug', _('Debug'))
		]);
		var component = E('select', { id: 'omr-log-component' }, [ option('all', _('All')) ]);
		var search = E('input', { id: 'omr-log-search', type: 'search', autocomplete: 'off' });
		var auto = E('input', { id: 'omr-log-auto', type: 'checkbox', checked: true });
		var toolbar = E('div', { class: 'omr-log-toolbar' }, [
			E('div', { class: 'omr-log-control' }, [ E('label', { for: 'omr-log-scope' }, _('Origin')), scope ]),
			E('div', { class: 'omr-log-control' }, [ E('label', { for: 'omr-log-severity' }, _('Severity')), severity ]),
			E('div', { class: 'omr-log-control' }, [ E('label', { for: 'omr-log-component' }, _('Component')), component ]),
			E('div', { class: 'omr-log-control omr-log-search' }, [ E('label', { for: 'omr-log-search' }, _('Search')), search ]),
			E('div', { class: 'omr-log-actions' }, [
				E('label', {}, [ auto, ' ' + _('Auto refresh') ]),
				E('button', { class: 'cbi-button', type: 'button', id: 'omr-log-refresh' }, _('Refresh')),
				E('button', { class: 'cbi-button cbi-button-action', type: 'button', id: 'omr-log-download' }, _('Download support report'))
			])
		]);
		var table = E('table', { class: 'omr-log-table' }, [
			E('thead', {}, E('tr', {}, [
				E('th', {}, _('Time')), E('th', {}, _('Origin')), E('th', {}, _('Source')),
				E('th', {}, _('Severity')), E('th', {}, _('Message'))
			])),
			E('tbody', { id: 'omr-log-body' })
		]);
		var root = E('div', { class: 'cbi-map' }, [
			style, E('h2', {}, _('Diagnostic logs')), summary, toolbar,
			E('div', { class: 'omr-log-state' }, [
				E('span', { id: 'omr-log-status' }), E('span', { id: 'omr-log-updated' })
			]),
			E('div', { class: 'omr-log-table-wrap' }, [
				table, E('div', { id: 'omr-log-empty', class: 'omr-log-empty', hidden: true }, _('No matching log entries'))
			])
		]);
		this.scope = scope;
		this.severity = severity;
		this.component = component;
		this.search = search;
		this.auto = auto;
		this.body = root.querySelector('#omr-log-body');
		this.root = root;
		scope.addEventListener('change', L.bind(this.fetch, this));
		severity.addEventListener('change', L.bind(this.draw, this));
		component.addEventListener('change', L.bind(this.draw, this));
		search.addEventListener('input', L.bind(this.draw, this));
		root.querySelector('#omr-log-refresh').addEventListener('click', L.bind(this.fetch, this));
		root.querySelector('#omr-log-download').addEventListener('click', L.bind(this.download, this));
		this.rebuildComponents();
		this.draw();
		poll.add(L.bind(function() {
			return this.auto.checked ? this.fetch() : Promise.resolve();
		}, this), 15);
		return root;
	},

	fetch: function() {
		if (this.busy) return Promise.resolve();
		this.busy = true;
		this.root.querySelector('#omr-log-status').textContent = _('Loading');
		return callLogs(500, this.scope.value).then(L.bind(function(data) {
			data = data || {};
			this.entries = Array.isArray(data.entries) ? data.entries : [];
			this.snapshot = data.snapshot || {};
			this.generatedAt = data.generated_at;
			this.vpsError = data.vps_error || data.error || '';
			this.rebuildComponents();
			this.draw();
		}, this)).catch(L.bind(function() {
			this.root.querySelector('#omr-log-status').textContent = _('Unable to load logs');
		}, this)).then(L.bind(function() { this.busy = false; }, this));
	},

	rebuildComponents: function() {
		var selected = this.component.value;
		var found = {};
		this.entries.forEach(function(entry) { found[entry.component || 'system'] = true; });
		this.component.options.length = 1;
		Object.keys(found).sort().forEach(L.bind(function(name) {
			this.component.appendChild(option(name, componentLabels[name] || name));
		}, this));
		this.component.value = found[selected] ? selected : 'all';
	},

	draw: function() {
		var snapshot = this.snapshot;
		var query = this.search.value.toLowerCase();
		var shown = 0;
		this.body.replaceChildren();
		this.entries.forEach(L.bind(function(entry) {
			if (this.severity.value !== 'all' && entry.severity !== this.severity.value) return;
			if (this.component.value !== 'all' && entry.component !== this.component.value) return;
			var haystack = [entry.source, entry.component, entry.message].join(' ').toLowerCase();
			if (query && haystack.indexOf(query) < 0) return;
			var row = E('tr', { class: entry.severity || 'info' }, [
				E('td', { class: 'time' }, dateText(entry.timestamp)),
				E('td', { class: 'scope' }, entry.scope === 'vps' ? 'VPS' : 'Router'),
				E('td', { class: 'source' }, entry.source || ''),
				E('td', { class: 'severity' }, entry.severity || ''),
				E('td', { class: 'message' }, entry.message || '')
			]);
			this.body.appendChild(row);
			shown++;
		}, this));
		this.root.querySelector('#omr-log-empty').hidden = shown !== 0;
		this.root.querySelector('#omr-log-status').textContent = shown + ' / ' + this.entries.length + ' ' + _('entries');
		this.root.querySelector('#omr-log-updated').textContent =
			(this.vpsError ? this.vpsError + ' - ' : '') + dateText(this.generatedAt);
		this.root.querySelector('#omr-log-vpn').textContent = snapshot.vpn || '-';
		this.root.querySelector('#omr-log-tunnel').textContent =
			(snapshot.tunnel || '-') + (snapshot.tunnel_up ? ' up' : ' down');
		this.root.querySelector('#omr-log-wans').textContent =
			(snapshot.wan_up == null ? '-' : snapshot.wan_up) + ' / ' +
			(snapshot.wan_total == null ? '-' : snapshot.wan_total);
		this.root.querySelector('#omr-log-cc').textContent =
			(snapshot.congestion || '-') + (snapshot.aggressiveness ? ' (' + snapshot.aggressiveness + '%)' : '');
		this.root.querySelector('#omr-log-errors').textContent =
			this.entries.filter(function(e) { return e.severity === 'error'; }).length;
		this.root.querySelector('#omr-log-warnings').textContent =
			this.entries.filter(function(e) { return e.severity === 'warning'; }).length;
	},

	download: function() {
		var button = this.root.querySelector('#omr-log-download');
		button.disabled = true;
		return callReport().then(function(report) {
			if (!report || report.kind !== 'omr_support_report') throw new Error('Invalid support report');
			var blob = new Blob([JSON.stringify(report, null, 2) + '\n'], { type: 'application/json' });
			var url = URL.createObjectURL(blob);
			var link = E('a', { href: url, download: 'omr-support-' + Date.now() + '.json' });
			document.body.appendChild(link);
			link.click();
			link.remove();
			setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
		}).catch(L.bind(function() {
			this.root.querySelector('#omr-log-status').textContent = _('Unable to download support report');
		}, this)).then(function() { button.disabled = false; });
	}
});