'use strict';
'require rpc';
'require form';
'require fs';
'require tools.widgets as widgets';

/*
 * Copyright (C) 2024 Ycarus (Yannick Chabanois) <contact@openmptcprouter.com> for OpenMPTCProuter
 * This is free software, licensed under the GNU General Public License v3.
 * See /LICENSE for more information
 */

var callSystemBoard = rpc.declare({
    object: 'system',
    method: 'board'
});

var NanbbrAggressivenessValue = form.Value.extend({
	renderWidget: function(section_id, option_index, cfgvalue) {
		var cbid = this.cbid(section_id);
		var value = parseInt(cfgvalue != null ? cfgvalue : this.default, 10);
		var presets = [
			{ value: 25, label: _('Light') },
			{ value: 50, label: _('Default') },
			{ value: 80, label: _('Aggressive') }
		];
		var buttons = [];
		var range;
		var valueOutput;
		var widget;
		var controls;
		var presetTrack;

		if (isNaN(value) || value < 1 || value > 100)
			value = 50;

		range = E('input', {
			'id': 'widget.' + cbid,
			'name': cbid,
			'type': 'range',
			'class': 'cbi-input-range',
			'min': '1',
			'max': '100',
			'step': '1',
			'value': value,
			'aria-label': _('NanBBR aggressiveness'),
			'style': 'display:block;width:100%;height:1rem;margin:0',
			'input': function(ev) {
				setValue(ev.currentTarget.value, false);
			},
			'change': function(ev) {
				setValue(ev.currentTarget.value, true);
			}
		});
		valueOutput = E('output', {
			'for': 'widget.' + cbid,
			'aria-live': 'polite',
			'style': 'display:block;min-width:3.5rem;text-align:center;font-size:.85rem;font-weight:700;font-variant-numeric:tabular-nums;line-height:1'
		}, [
			'%d%%'.format(value)
		]);

		function updatePresetState(currentValue) {
			for (var i = 0; i < buttons.length; i++) {
				var active = parseInt(buttons[i].getAttribute('data-value'), 10) == currentValue;
				buttons[i].style.fontWeight = active ? '700' : '400';
				buttons[i].style.opacity = active ? '1' : '.62';
				buttons[i].style.textDecoration = active ? 'underline' : 'none';
				buttons[i].setAttribute('aria-pressed', active ? 'true' : 'false');
			}
		}

		function setValue(newValue, notify) {
			newValue = Math.max(1, Math.min(100, parseInt(newValue, 10) || 50));
			range.value = newValue;
			valueOutput.textContent = '%d%%'.format(newValue);
			updatePresetState(newValue);
			if (widget) {
				if (notify)
					widget.setAttribute('data-changed', 'true');
				widget.dispatchEvent(new CustomEvent(
					notify ? 'widget-change' : 'widget-update',
					{ bubbles: true }));
			}
		}

		presetTrack = E('div', {
			'class': 'nanbbr-aggressiveness-presets',
			'style': 'display:grid;grid-template-columns:repeat(3,minmax(0,1fr));align-items:center;width:100%'
		});
		for (var i = 0; i < presets.length; i++) {
			var preset = presets[i];
			var button = E('button', {
				'type': 'button',
				'data-value': preset.value,
				'aria-pressed': 'false',
				'title': _('Set NanBBR aggressiveness to %d%%').format(preset.value),
				'style': 'appearance:none;border:0;background:transparent;color:inherit;cursor:pointer;padding:.15rem .1rem;font-size:.68rem;line-height:1;white-space:nowrap',
				'click': function(ev) {
					setValue(ev.currentTarget.getAttribute('data-value'), true);
				}
			}, [ '%s %d%%'.format(preset.label, preset.value) ]);
			buttons.push(button);
			presetTrack.appendChild(button);
		}

		controls = E('div', {
			'class': 'nanbbr-aggressiveness-controls',
			'style': 'display:grid;grid-template-columns:auto minmax(8rem,1fr) auto;align-items:center;column-gap:.6rem;width:100%'
		}, [
			E('span', {
				'style': 'font-size:.66rem;font-weight:600;white-space:nowrap;opacity:.72'
			}, [ _('STABILITY') ]),
			E('div', {
				'style': 'display:flex;flex-direction:column;align-items:stretch;gap:.18rem;min-width:8rem'
			}, [
				valueOutput,
				range,
				presetTrack
			]),
			E('span', {
				'style': 'font-size:.66rem;font-weight:600;white-space:nowrap;opacity:.72'
			}, [ _('PERFORMANCE') ])
		]);
		widget = E('div', {
			'id': cbid,
			'class': 'nanbbr-aggressiveness-widget',
			'style': 'display:inline-block;width:min(100%,26rem);max-width:100%;padding:.15rem 0'
		}, [
			controls
		]);
		updatePresetState(value);
		return widget;
	},

	formvalue: function(section_id) {
		var widget = this.map.findElement('id', this.cbid(section_id));
		var range = widget ? widget.querySelector('input[type="range"]') : null;

		return range ? range.value : null;
	}
});

return L.view.extend({
	    load: function() {
		return Promise.all([
		    L.resolveDefault(callSystemBoard(), {})
		]);
	    },

    render: function(res) {
	var m, s, o, nanbbrAggressiveness;
	var boardinfo = res[0];

	m = new form.Map('network', _('MPTCP'),_('Networks MPTCP settings.'));

	s = m.section(form.TypedSection, 'globals');

	o = s.option(form.ListValue, 'multipath', _('Multipath TCP'));
	o.value("enable", _("enable"));
	o.value("disable", _("disable"));
	o.readonly = true;

	o = s.option(form.ListValue, "mptcp_checksum", _("Multipath TCP checksum"));
	o.value(1, _("enable"));
	o.value(0, _("disable"));

	if (boardinfo.kernel.substring(0,4) != "5.15" && boardinfo.kernel.substring(0,1) != "6") {
		o = s.option(form.ListValue, "mptcp_debug", _("Multipath Debug"));
		o.value(1, _("enable"));
		o.value(0, _("disable"));
	}

	o = s.option(form.ListValue, "mptcp_path_manager", _("Multipath TCP path-manager"), _("Default is fullmesh"));
	o.value("default", _("default"));
	o.value("fullmesh", "fullmesh");

	if (parseFloat(boardinfo.kernel.substring(0,4)) < 6) {
		o.value("ndiffports", "ndiffports");
		o.value("binder", "binder");
		o.value("netlink", _("Netlink"));
	}

	o = s.option(form.ListValue, "mptcp_scheduler", _("Multipath TCP scheduler"), _('BPF schedulers (not available on all platforms):') + '<br />' +
		_('bpf_burst => same as the default scheduler') + '<br />' +
		_('bpf_red => sends all packets redundantly on all available subflows') + '<br />' +
		_('bpf_first => always picks the first subflow to send data')  + '<br />' +
		_('bpf_rr => always picks the next available subflow to send data (round-robin)')

	);
	o.value("default", _("default"));
	if (parseFloat(boardinfo.kernel.substring(0,4)) < 6) {
		o.value("roundrobin", "round-robin");
		o.value("redundant", "redundant");
		o.value("blest", "BLEST");
		o.value("ecf", "ECF");
	}

	if (parseFloat(boardinfo.kernel.substring(0,3)) > 6) {
	    o.load = function(section_id) {
		    return L.resolveDefault(fs.list('/usr/share/bpf/scheduler'), []).then(L.bind(function(entries) {
			    for (var i = 0; i < entries.length; i++)
				    if (entries[i].type == 'file' && entries[i].name.match(/\.o$/))
					this.value(entries[i].name.replace(/^mptcp_/, "").replace(/\.o$/, ""));
			    return this.super('load', [section_id]);
		    }, this));
	    };
	    // bpf_burst => same as the default scheduler
	    // bpf_red => sends all packets redundantly on all available subflows
	    // bpf_first => always picks the first subflow to send data
	    // bpf_rr => always picks the next available subflow to send data (round-robin)
	}

	if (parseFloat(boardinfo.kernel.substring(0,4)) < 6) {
		o = s.option(form.Value, "mptcp_syn_retries", _("Multipath TCP SYN retries"));
		o.datatype = "uinteger";
		o.rmempty = false;
	}

	if (parseFloat(boardinfo.kernel.substring(0,4)) < 6) {
		o = s.option(form.ListValue, "mptcp_version", _("Multipath TCP version"));
		o.value(0, _("0"));
		o.value(1, _("1"));
		o.default = 0;
	}

	o = s.option(form.ListValue, "congestion", _("Congestion control"),_("Selects the TCP congestion control used by MPTCP subflows. Default is bbr."));
	o.load = function(section_id) {
		return fs.exec_direct('/sbin/sysctl', ['-n', 'net.ipv4.tcp_available_congestion_control']).then(L.bind(function(entries) {
			var congestioncontrol = entries.toString().trim().split(/\s+/);
			var has_bbr1 = congestioncontrol.indexOf('bbr1') >= 0;
			for (var d in congestioncontrol) {
				var cc = congestioncontrol[d];
				if (cc)
					this.value(cc, cc == 'bbr' && has_bbr1 ? 'bbr3' : cc);
			};
			return this.super('load', [section_id]);
		}, this));
	};

	nanbbrAggressiveness = s.option(NanbbrAggressivenessValue, "nanbbr_aggressiveness", _("NanBBR aggressiveness"), _("Applied to new TCP connections and MPTCP subflows; active connections keep their current profile."));
	nanbbrAggressiveness.datatype = "range(1,100)";
	nanbbrAggressiveness.default = "50";
	nanbbrAggressiveness.rmempty = false;
	nanbbrAggressiveness.depends("congestion", "nanbbr1_var");
	nanbbrAggressiveness.depends("congestion", "nanbbr2_var");
	nanbbrAggressiveness.depends("congestion", "nanbbr3_var");

	if (parseFloat(boardinfo.kernel.substring(0,4)) >= 6) {
		if (boardinfo.kernel.substring(0,1) == "6") {
			// Only available since 5.19
			o = s.option(form.ListValue, "mptcp_pm_type", _("Path manager mode"), _("Choose whether endpoints and additional subflows are managed by the kernel or by mptcpd in userspace."));
			o.value(0, _("In-kernel path manager"));
			o.value(1, _("Userspace path manager"));
			o.default = 0;
		}

		o = s.option(form.ListValue, "mptcp_disable_initial_config", _("Initial endpoint setup"), _("Keep the initial addresses advertised automatically when a connection starts."));
		o.value("0", _("enable"));
		o.value("1", _("disable"));
		o.default = "0";

		o = s.option(form.ListValue, "mptcp_force_multipath", _("Force multipath mode"), _("Keep creating extra subflows whenever possible instead of staying on a single path."));
		o.value("1", _("enable"));
		o.value("0", _("disable"));
		o.default = "1";

		o = s.option(form.ListValue, "mptcp_allow_join_initial_addr_port", _("Allow joins on initial address"), _("Allow extra subflows to join using the initial address and port pair advertised by the first subflow."));
		o.value("1", _("enable"));
		o.value("0", _("disable"));
		o.default = "1";

		o = s.option(form.ListValue, "mptcpd_enable", _("Enable MPTCPd"));
		o.depends("mptcp_pm_type","1");
		o.value("enable", _("enable"));
		o.value("disable", _("disable"));
		o.default = "disable";

		o = s.option(form.DynamicList, "mptcpd_path_manager", _("MPTCPd path managers"));
		o.load = function(section_id) {
			return L.resolveDefault(fs.list('/usr/lib/mptcpd'), []).then(L.bind(function(entries) {
				for (var i = 0; i < entries.length; i++)
					if (entries[i].type == 'file' && entries[i].name.match(/\.so$/))
						this.value(entries[i].name);
				return this.super('load', [section_id]);
			}, this));
		};
		o.depends("mptcp_pm_type","1");

		o = s.option(form.DynamicList, "mptcpd_plugins", _("MPTCPd plugins"));
		o.load = function(section_id) {
			return L.resolveDefault(fs.list('/usr/lib/mptcpd'), []).then(L.bind(function(entries) {
				for (var i = 0; i < entries.length; i++)
					if (entries[i].type == 'file' && entries[i].name.match(/\.so$/))
						this.value(entries[i].name);
				return this.super('load', [section_id]);
			}, this));
		};
		o.depends("mptcp_pm_type","1");

		o = s.option(form.DynamicList, "mptcpd_addr_flags", _("MPTCPd address flags"), _("Flags applied to announced endpoints. Use fullmesh+subflow to aggressively open additional paths."));
		o.value("subflow","subflow");
		o.value("signal","signal");
		o.value("backup","backup");
		o.value("fullmesh","fullmesh");
		o.depends("mptcp_pm_type","1");

		o = s.option(form.DynamicList, "mptcpd_notify_flags", _("MPTCPd Address notification flags"));
		o.value("existing","existing");
		o.value("skip_link_local","skip_link_local");
		o.value("skip_loopback","skip_loopback");
		o.depends("mptcp_pm_type","1");

		o = s.option(form.Value, "mptcp_subflows", _("Max additional subflows"),_("Maximum number of extra subflows allowed for each MPTCP connection. Raise this when a single flow is rate-limited."));
		o.datatype = "uinteger";
		o.rmempty = false;
		o.default = 8;

		o = s.option(form.Value, "mptcp_stale_loss_cnt", _("Retranmission intervals"),_("The number of MPTCP-level retransmission intervals with no traffic and pending outstanding data on a given subflow required to declare it stale. A low stale_loss_cnt value allows for fast active-backup switch-over, an high value maximize links utilization on edge scenarios e.g. lossy link with high BER or peer pausing the data processing."));
		o.datatype = "uinteger";
		o.rmempty = false;
		o.default = 4;

		o = s.option(form.Value, "mptcp_add_addr_accepted", _("Max accepted peer addresses"),_("Maximum number of peer ADD_ADDR announcements accepted for each MPTCP connection."));
		o.datatype = "uinteger";
		o.rmempty = false;
		o.default = 8;

		o = s.option(form.Value, "mptcp_add_addr_timeout", _("ADD_ADDR retry timeout"),_("Seconds to wait before resending an ADD_ADDR control message that was not acknowledged by the peer."));
		o.datatype = "uinteger";
		o.rmempty = false;
		o.default = 120;
	} else {
		o = s.option(form.Value, "mptcp_fullmesh_num_subflows", _("Fullmesh subflows for each pair of IP addresses"));
		o.datatype = "uinteger";
		o.rmempty = false;
		o.default = 1;
		//o.depends("mptcp_path_manager","fullmesh")

		o = s.option(form.ListValue, "mptcp_fullmesh_create_on_err", _("Re-create fullmesh subflows after a timeout"));
		o.value(1, _("enable"));
		o.value(0, _("disable"));
		//o.depends("mptcp_path_manager","fullmesh");

		o = s.option(form.Value, "mptcp_ndiffports_num_subflows", _("ndiffports subflows number"));
		o.datatype = "uinteger";
		o.rmempty = false;
		o.default = 1;
		//o.depends("mptcp_path_manager","ndiffports")

		o = s.option(form.ListValue, "mptcp_rr_cwnd_limited", _("Fill the congestion window on all subflows for round robin"));
		o.value("Y", _("enable"));
		o.value("N", _("disable"));
		o.default = "Y";
		//o.depends("mptcp_scheduler","roundrobin")

		o = s.option(form.Value, "mptcp_rr_num_segments", _("Consecutive segments that should be sent for round robin"));
		o.datatype = "uinteger";
		o.rmempty = false;
		o.default = 1;
		//o.depends("mptcp_scheduler","roundrobin")
	}

	s = m.section(form.TypedSection, "interface", _("Interfaces Settings"));
	s.filter = function(section) {
	    return (!section.match("^oip.*") && !section.match("^lo.*") && section != "omrvpn" && section != "omr6in4");
	}

	o = s.option(form.ListValue, "multipath", _("Multipath TCP"), _("One interface must be set as master"));
	o.value("on", _("enabled"));
	o.value("off", _("disabled"));
	o.value("master", _("master"));
	o.value("backup", _("backup"));
	//o.value("handover", _("handover"));
	o.default = "off";

	return m.render();
	    }
});
