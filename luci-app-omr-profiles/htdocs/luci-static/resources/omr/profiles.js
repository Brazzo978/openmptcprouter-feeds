'use strict';
'require baseclass';
'require rpc';
'require poll';

var callStatus = rpc.declare({
	object: 'omr.profiles', method: 'status', expect: { '': {} }
});
var callApply = rpc.declare({
	object: 'omr.profiles', method: 'apply', params: [ 'id' ], expect: { '': {} }
});
var callSave = rpc.declare({
	object: 'omr.profiles', method: 'save', params: [ 'name' ], expect: { '': {} }
});
var callConfirm = rpc.declare({
	object: 'omr.profiles', method: 'confirm', params: [ 'transaction' ], expect: { '': {} }
});
var callRollback = rpc.declare({
	object: 'omr.profiles', method: 'rollback', params: [ 'transaction' ], expect: { '': {} }
});
var callDelete = rpc.declare({
	object: 'omr.profiles', method: 'delete', params: [ 'id' ], expect: { '': {} }
});
var callSetQuick = rpc.declare({
	object: 'omr.profiles', method: 'set_quick', params: [ 'a', 'b' ], expect: { '': {} }
});
var callAccess = rpc.declare({
	object: 'session', method: 'access', params: [ 'scope', 'object', 'function' ],
	expect: { access: false }
});

var fields = [
	[ 'tcp_scheduler', _('MPTCP scheduler') ],
	[ 'tcp_cc', _('TCP congestion control') ],
	[ 'transport', _('VPN transport') ],
	[ 'proxy', _('Proxy') ],
	[ 'tcp_nanbbr_aggressiveness', _('NanBBR aggressiveness') ],
	[ 'mq_scheduler', _('MQVPN scheduler') ],
	[ 'mq_cc', _('MQVPN congestion control') ],
	[ 'fec_enable', _('MQVPN FEC') ],
	[ 'fec_scheme', _('FEC scheme') ],
	[ 'reinjection_control', _('MQVPN reinjection') ],
	[ 'reinjection_mode', _('Reinjection mode') ],
	[ 'reorder_enabled', _('MQVPN reorder buffer') ],
	[ 'reorder_max_wait_ms', _('Reorder maximum wait') ],
	[ 'reorder_cap_packets', _('Reorder packet limit') ]
];

function textValue(key, value) {
	if (value == null || value === '') return _('Automatic');
	if (key === 'tcp_cc' && value === 'bbr') return 'BBRv3 (bbr)';
	if (key === 'fec_enable' || key === 'reinjection_control' || key === 'reorder_enabled') {
		if (String(value) === '1' || value === true) return _('Enabled');
		if (String(value) === '0' || value === false) return _('Disabled');
	}
	return String(value);
}

function settingsSummary(settings) {
	settings = settings || {};
	var rows = [];
	fields.forEach(function(field) {
		if (!Object.prototype.hasOwnProperty.call(settings, field[0])) return;
		rows.push(E('dt', {}, field[1]));
		rows.push(E('dd', {}, [ textValue(field[0], settings[field[0]]) ]));
	});
	return rows.length ? E('dl', { 'class': 'omr-profile-summary' }, rows) :
		E('p', { 'class': 'omr-profile-detail' }, _('Settings are unavailable.'));
}

function installStyle() {
	if (document.querySelector('link[data-omr-profiles-style]')) return;
	var link = document.createElement('link');
	link.rel = 'stylesheet';
	link.href = L.resource('omr/profiles.css');
	link.setAttribute('data-omr-profiles-style', '1');
	document.head.appendChild(link);
}

function reasonText(preset) {
	var reasons = preset.unavailable_reasons;
	if (Array.isArray(reasons) && reasons.length) return reasons.join('; ');
	if (typeof reasons === 'string' && reasons) return reasons;
	return _('This profile is not available with the current router or server.');
}

function button(label, disabled, handler, style) {
	var attrs = {
		'type': 'button',
		'class': 'btn ' + (style || 'cbi-button-action'),
		'click': handler
	};
	if (disabled) attrs.disabled = 'disabled';
	return E('button', attrs, label);
}

function phaseReady(pending) {
	return pending && (pending.phase === 'awaiting_confirmation' ||
		pending.phase === 'awaiting_confirm' || pending.phase === 'ready');
}

/* A CSS-only illustration: no traffic or WAN health is sampled.  Its DOM is
 * deliberately outside the periodically redrawn status panel. */
function createPreview() {
	var selected = '', initialized = false, paused = false, presets = [], choicesSignature = '';
	var select = E('select', { 'aria-label': _('Preview profile') });
	function chart(label, protocol) {
		var explanation = E('p', { 'class': 'omr-preview-explanation' });
		var packets = [];
		function track(wan) {
			var dots = [0, 1, 2].map(function(i) {
				var dot = E('span', { 'class': 'omr-preview-packet packet-' + String.fromCharCode(97 + i) });
				packets.push(dot); return dot;
			});
			return E('div', { 'class': 'omr-preview-track wan' + wan }, [ E('span', { 'class': 'omr-preview-wan-label' }, _('WAN ') + wan) ].concat(dots));
		}
		var diagram = E('div', { 'class': 'omr-preview-diagram', 'aria-hidden': 'true', 'data-protocol': protocol }, [
			E('span', { 'class': 'omr-preview-endpoint' }, _('Router')),
			E('div', { 'class': 'omr-preview-wans' }, [ track(1), track(2) ]), E('span', { 'class': 'omr-preview-endpoint' }, _('VPS'))
		]);
		return { diagram: diagram, explanation: explanation, packets: packets, root: E('section', { 'class': 'omr-preview-chart' }, [ E('h5', {}, label), diagram, explanation ]) };
	}
	var icmp = chart(_('ICMP'), 'icmp');
	var tcp = chart(_('TCP'), 'tcp');
	var udp = chart(_('UDP'), 'udp');
	var pauseButton = button(_('Pause animation'), false, function() {
		paused = !paused;
		pauseButton.textContent = paused ? _('Resume animation') : _('Pause animation');
		render();
	}, 'cbi-button-neutral');
	var root = E('section', { 'class': 'omr-preview', 'aria-label': _('Packet path preview') }, [
		E('h4', {}, _('Packet path preview')),
		E('p', { 'class': 'omr-profile-detail' }, _('Illustration only — not live traffic, measured performance or WAN health. Preview selection does not apply a profile.')),
		E('div', { 'class': 'omr-preview-controls' }, [ select, pauseButton ]),
		E('p', { 'class': 'omr-profile-detail' }, _('Letters, colours and shapes distinguish packets; matching letters are copies. Packet density is illustrative, not measured speed. WAN-bound diagnostic pings and bypass traffic are not shown.')),
		icmp.root, tcp.root, udp.root
	]);
	function render() {
		var p = presets.filter(function(item) { return String(item.id) === selected; })[0];
		var settings = p && p.settings || {};
		var tcpPath = settings.tcp_scheduler === 'bpf_red' ? 'duplicate' : 'automatic';
		var mqPath = settings.mq_scheduler === 'wlb' ? 'balanced' :
			(settings.mq_scheduler === 'minrtt' ? 'minrtt' : 'automatic');
		var oldTransport = settings.transport === 'glorytun_tcp';
		var knownTransport = oldTransport || settings.transport === 'mqvpn';
		var dense = p && (p.id === 'performance' || p.id === 'performance_old');
		var descriptions = {
			duplicate: _('Illustration: redundant MPTCP sends a copy of the same packet on both eligible paths.'),
			balanced: _('Illustration: WLB distributes successive packets across two equally weighted paths.'),
			minrtt: _('Illustration: minrtt chooses the eligible path with the lowest available RTT; WAN 1 is an example.'),
			automatic: _('Automatic scheduling can use available paths according to congestion, window and latency; this sequence is one illustration.')
		};
		[ [icmp, oldTransport ? tcpPath : mqPath], [tcp, tcpPath], [udp, oldTransport ? tcpPath : mqPath] ].forEach(function(item) {
			var chartItem = item[0], path = knownTransport ? item[1] : 'unknown', viaTcp = oldTransport || chartItem === tcp;
			chartItem.diagram.setAttribute('class', 'omr-preview-diagram is-' + path + (dense && path === 'automatic' ? ' is-dense' : '') + (paused ? ' is-paused' : ''));
			chartItem.packets.forEach(function(dot, index) { dot.textContent = String.fromCharCode(65 + (path === 'duplicate' ? index % 3 : index)); });
			chartItem.explanation.textContent = !knownTransport ? _('Transport is not recorded in this profile; packet paths cannot be illustrated.') : (!viaTcp && path === 'automatic' ?
				_('MQVPN path selection depends on its scheduler and eligible paths; this sequence is one illustration.') : descriptions[path]) + ' ' +
				(oldTransport ? _('Illustration: IP traffic inside Glorytun TCP using MPTCP.') : (chartItem === tcp ? _('Illustration: TCP through the MPTCP proxy; TCP forced into the VPN is not shown.') : _('Illustration: IP traffic inside MQVPN.')));
		});
	}
	select.addEventListener('change', function(ev) { selected = ev.target.value; render(); });
	return { root: root, update: function(state) {
		presets = Array.isArray(state.presets) ? state.presets.filter(function(p) { return p && p.id; }) : [];
		if (!initialized) { selected = String((state.active || {}).id || ''); initialized = true; }
		var signature = JSON.stringify(presets.map(function(p) { return [p.id, p.name]; }));
		if (signature !== choicesSignature) {
			choicesSignature = signature;
			while (select.firstChild) select.removeChild(select.firstChild);
			presets.forEach(function(p) { select.appendChild(E('option', { value: String(p.id) }, [ String(p.name || p.id) ])); });
			if (!presets.some(function(p) { return String(p.id) === selected; })) selected = presets.length ? String(presets[0].id) : '';
			select.value = selected;
		}
		render();
	} };
}

return baseclass.extend({
	create: function(options) {
		installStyle();
		options = options || {};
		var full = !!options.full;
		var root = E('section', {
			'class': 'cbi-section omr-profile-panel ' + (full ? 'omr-profile-panel-full' : 'omr-profile-panel-quick'),
			'aria-live': 'polite'
		});
		var content = E('div', {});
		var nameInput = E('input', {
			'type': 'text', 'maxlength': '48', 'placeholder': _('Profile name'),
			'aria-label': _('Profile name'), 'autocomplete': 'off'
		});
		var state = null, access = {}, accessLoaded = false, busy = false, loading = null;
		var lastSignature = '', message = '', messageIsError = false, statusFailure = '';
		var methods = [ 'apply', 'save', 'delete', 'confirm', 'rollback', 'set_quick' ];
		var quickA = '', quickB = '', quickInitialized = false;
		var preview = full ? createPreview() : null;

		if (preview) root.appendChild(preview.root);
		root.appendChild(content);

		function showMessage(text, isError) {
			message = text || '';
			messageIsError = !!isError;
			lastSignature = '';
			draw();
		}

		function refresh() {
			if (loading) return loading;
			var request = callStatus().then(function(result) {
				if (!result || result.ok !== true) {
					state = null;
					statusFailure = result && result.error || _('Connection profiles are unavailable.');
					lastSignature = '';
					draw();
					return;
				}
				statusFailure = '';
				state = result;
				draw();
			}, function() {
				state = null;
				statusFailure = _('Unable to contact the profile service.');
				lastSignature = '';
				draw();
			});
			loading = request.then(function() { loading = null; }, function() { loading = null; });
			return loading;
		}

		function run(call, args) {
			if (busy) return;
			busy = true;
			message = '';
			lastSignature = '';
			draw();
			return call.apply(null, args).then(function(result) {
				if (!result || result.ok !== true)
					showMessage(result && result.error || _('The operation could not be completed.'), true);
				else if (call === callSave) {
					nameInput.value = '';
					showMessage(_('Profile saved.'), false);
				} else if (call === callSetQuick) {
					quickInitialized = false;
					message = _('Quick profiles saved.'); messageIsError = false; lastSignature = '';
				} else {
					lastSignature = '';
				}
				// An older poll may have started before the mutation. Wait for it
				// and fetch again before re-enabling buttons.
				return refresh().then(function() {
					if (call === callSetQuick && result && result.ok === true) quickInitialized = false;
					return refresh();
				}).then(function() {
					busy = false; lastSignature = ''; draw();
				});
			}, function() {
				showMessage(_('The profile service did not respond. Check the current state before retrying.'), true);
				return refresh().then(refresh).then(function() {
					busy = false; lastSignature = ''; draw();
				});
			});
		}

		function applyProfile(preset) {
			if (!access.apply || busy || !preset || preset.available === false || (state && state.pending)) return;
			return run(callApply, [ String(preset.id) ]);
		}

		function profileCard(preset, active, pending) {
			var current = active && active.id === preset.id && !active.modified && active.server_match === true;
			var isDefault = preset.id === 'default' && preset.builtin;
			var descriptions = {
				'default': _('Restore the 3K baseline tuning.'),
				'performance': _('Throughput-oriented tuning.'),
				'gaming': _('Latency-oriented tuning.')
			};
			var unavailable = preset.available === false;
			var unavailableText = unavailable ? reasonText(preset) : '';
			var actions = [
				button(isDefault ? _('Restore default') : (current ? _('Active') : _('Use profile')),
					(current && !isDefault) || unavailable || busy || !!pending || !access.apply,
					function() { applyProfile(preset); }, current ? 'cbi-button-neutral' : 'cbi-button-action')
			];
			if (full && !preset.builtin) {
				actions.push(button(_('Delete'), busy || !!pending || !access.delete,
					function() {
						if (window.confirm(_('Delete this saved profile?')))
							run(callDelete, [ String(preset.id) ]);
					}, 'cbi-button-negative'));
			}
			var children = [ E('div', { 'class': 'omr-profile-name' }, [ String(preset.name || preset.id || '') ]),
				E('div', { 'class': 'omr-profile-detail' }, preset.builtin ? _('Built-in') : _('Custom')) ];
			if (preset.builtin && descriptions[preset.id])
				children.push(E('div', { 'class': 'omr-profile-detail' }, [ descriptions[preset.id] ]));
			if (full) {
				children.push(E('strong', {}, _('Router settings')));
				children.push(settingsSummary(preset.settings));
				if (preset.remote_settings && Object.keys(preset.remote_settings).length) {
					children.push(E('strong', {}, _('VPS settings')));
					children.push(settingsSummary(preset.remote_settings));
				}
			}
			if (unavailable) children.push(E('p', { 'class': 'omr-profile-detail' }, [ unavailableText ]));
			children.push(E('div', { 'class': 'omr-profile-actions' }, actions));
			return E('div', { 'class': 'omr-profile-card' + (current ? ' is-active' : '') }, children);
		}

		function quickControls(all, active, pending) {
			var quick = state.quick || { a: 'default', b: 'gaming' };
			if (!quickInitialized) { quickA = String(quick.a || 'default'); quickB = String(quick.b || 'gaming'); quickInitialized = true; }
			var confirmed = active && !active.modified ? String(active.id || '') : '';
			function preset(id) { return all.filter(function(p) { return String(p.id) === id; })[0]; }
			function choose(side, id) {
				var p = preset(id), isActive = confirmed === id;
				var attrs = { type: 'button', 'class': 'omr-quick-choice' + (isActive ? ' is-active' : ''),
					'aria-pressed': isActive ? 'true' : 'false', click: function() { applyProfile(p); } };
				if (busy || pending || !access.apply || !p || p.available === false || isActive) attrs.disabled = 'disabled';
				return E('button', attrs, [ side + ': ' + (p ? String(p.name || p.id) : _('Unavailable')) ]);
			}
			function selector(side, value) {
				var opts = all.map(function(p) { return E('option', { value: String(p.id) }, [ String(p.name || p.id) ]); });
				var el = E('select', { 'aria-label': _('Quick profile ') + side }, opts);
				el.value = value; el.disabled = busy || !!pending || !access.set_quick;
				el.addEventListener('change', function(ev) { if (side === 'A') quickA = ev.target.value; else quickB = ev.target.value; });
				return el;
			}
			var activeA = String(quick.a || 'default'), activeB = String(quick.b || 'gaming');
			var inPair = confirmed === activeA || confirmed === activeB;
			var target = confirmed === activeA ? preset(activeB) : preset(activeA);
			var toggleAttrs = { type: 'checkbox', role: 'switch', 'class': 'omr-quick-toggle',
				'aria-label': _('Switch between quick profiles A and B'), 'aria-describedby': 'omr-quick-status' };
			if (confirmed === activeB) toggleAttrs.checked = 'checked';
			if (!inPair || busy || pending || !access.apply || !target || target.available === false) toggleAttrs.disabled = 'disabled';
			var toggle = E('input', toggleAttrs);
			toggle.addEventListener('change', function() { applyProfile(target); });
			var text = confirmed === activeA || confirmed === activeB ? _('Confirmed profile is selected.') : _('Current configuration is outside this pair; choose A or B.');
			if (pending) text = _('A profile change is pending. The last confirmed profile remains unchanged.');
			var notes = [activeA, activeB].map(function(id) { return preset(id); }).filter(function(p) { return p && p.available === false; }).map(function(p) {
				return E('p', { 'class': 'omr-profile-detail' }, [ String(p.name || p.id) + ': ' + reasonText(p) ]);
			});
			return E('div', { 'class': 'omr-quick' }, [
				E('div', { 'class': 'omr-quick-switch' }, [ choose('A', activeA), toggle, choose('B', activeB) ]),
				E('p', { 'class': 'omr-profile-detail', id: 'omr-quick-status' }, text),
			].concat(notes, [ E('div', { 'class': 'omr-quick-config' }, [ E('span', {}, _('Configure A:')), selector('A', quickA), E('span', {}, _('B:')), selector('B', quickB),
					button(_('Save quick profiles'), busy || !!pending || !access.set_quick, function() {
						if (!quickA || !quickB || quickA === quickB) return showMessage(_('Choose two different profiles.'), true);
						return run(callSetQuick, [quickA, quickB]);
					}, 'cbi-button-neutral') ])
			]));
		}

		function draw() {
			var signature = JSON.stringify([ state, access, accessLoaded, busy, message, messageIsError, statusFailure ]);
			if (signature === lastSignature) return;
			lastSignature = signature;
			while (content.firstChild) content.removeChild(content.firstChild);
			root.setAttribute('aria-busy', busy ? 'true' : 'false');
			var header = [ E('h3', {}, _('Connection profiles')) ];
			if (!full) header.push(E('a', { 'href': L.url('admin/system/openmptcprouter/profiles') }, _('Manage profiles')));
			content.appendChild(E('div', { 'class': 'omr-profile-header' }, header));
			if (message) content.appendChild(E('div', {
				'class': 'omr-profile-message' + (messageIsError ? ' omr-profile-error' : ''),
				'role': messageIsError ? 'alert' : 'status'
			}, [ String(message) ]));
			if (!state) {
				if (statusFailure) content.appendChild(E('div', { 'class': 'omr-profile-message omr-profile-error', 'role': 'alert' }, [ String(statusFailure) ]));
				else if (!message) content.appendChild(E('p', {}, _('Loading profiles…')));
				return;
			}
			var active = state.active || {};
			if (preview) preview.update(state);
			var pending = state.pending || null;
			var activeName = active.name || _('Current configuration');
			content.appendChild(E('div', { 'class': 'omr-profile-current' }, [
				E('strong', {}, _('Current: ')),
				String(activeName),
				active.modified ? ' — ' + _('modified outside this profile') : ''
			]));
			var matchText = active.server_match === true ? _('VPS settings match this profile.') :
				(active.server_match === false ? _('VPS settings differ from this profile.') : _('VPS settings have not been verified.'));
			var age = state.capabilities && state.capabilities.age_seconds;
			if (active.server_match != null && age != null && isFinite(Number(age)) && Number(age) >= 0)
				matchText += ' ' + _('Last checked %s seconds ago.').format(String(Math.floor(Number(age))));
			content.appendChild(E('div', { 'class': 'omr-profile-detail' }, [ matchText ]));
			if (pending) {
				var pendingMessage = pending.error ? String(pending.error) :
					(phaseReady(pending) ? _('Confirm the profile to keep it, or revert to the previous settings.') :
					(pending.phase === 'rollback_failed' ? _('The previous settings could not be restored automatically. Retry the restore.') :
					(pending.phase === 'confirming' ? _('Confirming the profile. Please wait.') :
					_('Applying or restoring the profile. Please wait.'))));
				var pendingNodes = [ E('strong', {}, [ String(pending.name || pending.id || _('Profile')) ]), E('p', {}, [ pendingMessage ]) ];
				if (phaseReady(pending) && pending.seconds_remaining != null)
					pendingNodes.push(E('p', {}, _('Automatic restore in %s seconds.').format(String(Math.max(0, Number(pending.seconds_remaining) || 0)))));
				if ((phaseReady(pending) || pending.phase === 'rollback_failed') && pending.transaction) {
					var pendingActions = [];
					if (phaseReady(pending)) pendingActions.push(button(_('Keep profile'), busy || !access.confirm, function() {
						run(callConfirm, [ String(pending.transaction) ]);
					}, 'cbi-button-positive'));
					pendingActions.push(button(pending.phase === 'rollback_failed' ? _('Retry restore') : _('Revert'), busy || !access.rollback, function() {
						run(callRollback, [ String(pending.transaction) ]);
					}, 'cbi-button-negative'));
					pendingNodes.push(E('div', { 'class': 'omr-profile-actions' }, pendingActions));
				}
				content.appendChild(E('div', { 'class': 'omr-profile-message ' + (pending.error ? 'omr-profile-error' : 'omr-profile-warning'), 'role': 'status' }, pendingNodes));
			}
			else if (!message && state.last_result && state.last_result.message) {
				content.appendChild(E('div', {
					'class': 'omr-profile-message' + (state.last_result.ok === false ? ' omr-profile-error' : ''),
					'role': state.last_result.ok === false ? 'alert' : 'status'
				}, [ String(state.last_result.message) ]));
			}
			content.appendChild(E('p', { 'class': 'omr-profile-help' }, _('Applying a profile can restart router and VPS services, temporarily interrupting the tunnel and existing connections. Performance depends on your links.')));
			if (accessLoaded && !access.apply)
				content.appendChild(E('p', { 'class': 'omr-profile-detail' }, _('Your account can view profiles but cannot apply them.')));
			var all = Array.isArray(state.presets) ? state.presets : [];
			var builtin = all.filter(function(p) { return p && p.builtin; });
			var custom = all.filter(function(p) { return p && !p.builtin; });
			if (!full) content.appendChild(quickControls(all, active, pending));
			else content.appendChild(E('div', { 'class': 'omr-profile-grid' }, all.map(function(p) {
				return profileCard(p, active, pending);
			})));
			if (full) {
				content.appendChild(E('h4', {}, _('Current settings on router')));
				content.appendChild(settingsSummary(state.current));
				if (state.remote_current && Object.keys(state.remote_current).length) {
					content.appendChild(E('h4', {}, _('Current settings on VPS')));
					content.appendChild(settingsSummary(state.remote_current));
				}
				content.appendChild(E('p', { 'class': 'omr-profile-help' }, _('Save the current supported tuning settings as a custom profile. Network addresses, credentials and forwarding rules are not included.')));
				nameInput.disabled = busy || !!pending || !access.save;
				content.appendChild(E('div', { 'class': 'omr-profile-save' }, [
					nameInput,
					button(_('Save current settings'), busy || !!pending || !access.save, function() {
						var name = nameInput.value.trim();
						if (!name) return showMessage(_('Enter a profile name.'), true);
						if (name.length > 48) return showMessage(_('Profile names must be at most 48 characters.'), true);
						run(callSave, [ name ]);
					}, 'cbi-button-positive')
				]));
			}
		}

		draw();
		Promise.all(methods.map(function(method) {
			return callAccess('ubus', 'omr.profiles', method).then(function(allowed) {
				access[method] = allowed === true;
			}, function() { access[method] = false; });
		})).then(function() {
			accessLoaded = true;
			lastSignature = '';
			draw();
		});
		refresh();
		poll.add(refresh, 2);
		return root;
	}
});
