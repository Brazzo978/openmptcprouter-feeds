'use strict';
'require form';

return L.view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('mqvpn2', _('MQVPN2 (experimental)'));

		s = m.section(form.NamedSection, 'vpn', 'mqvpn2', _('UDP/ICMP client'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('general', _('General Settings'));
		s.tab('advanced', _('Advanced Settings'));

		o = s.taboption('general', form.Value, 'host', _('Server'));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'port', _('Port'));
		o.default = '65412';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'key', _('Authentication key'));
		o.password = true;
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'scheduler', _('Scheduler'));
		o.value('wlb', _('Weighted load balancing'));
		o.value('wlb_udp_pin', _('UDP flow pinning'));
		o.value('minrtt', _('Minimum RTT'));
		o.value('backup_fec', _('Backup FEC'));
		o.default = 'wlb';

		o = s.taboption('general', form.ListValue, 'cc', _('Congestion control'));
		o.value('cubic', _('CUBIC'));
		o.value('bbr', _('BBR'));
		o.value('bbr2', _('BBR2 (experimental)'));
		o.default = 'cubic';

		o = s.taboption('general', form.Flag, 'reorder', _('UDP reorder buffer'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'dev', _('Tunnel interface'));
		o.default = 'mqvpn2';
		o.placeholder = 'mqvpn2';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'mtu', _('Tunnel MTU'));
		o.default = '0';
		o.placeholder = '0';
		o.datatype = 'uinteger';

		o = s.taboption('advanced', form.Value, 'init_max_path_id', _('Path ID budget'));
		o.default = '128';
		o.placeholder = '128';
		o.datatype = 'range(1,128)';
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'paths_auto', _('Use OMR WAN interfaces'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'insecure', _('Allow self-signed certificate'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'manage_routes', _('Let MQVPN2 manage routes'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'reconnect', _('Reconnect automatically'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'reconnect_interval', _('Reconnect interval'));
		o.default = '5';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.taboption('advanced', form.ListValue, 'log_level', _('Log level'));
		o.value('error', _('Error'));
		o.value('warn', _('Warning'));
		o.value('info', _('Info'));
		o.value('debug', _('Debug'));
		o.default = 'info';

		o = s.taboption('advanced', form.Value, 'localip', _('Client tunnel IP'));
		o.default = '10.255.248.2';
		o.datatype = 'ip4addr';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'remoteip', _('Server tunnel IP'));
		o.default = '10.255.248.1';
		o.datatype = 'ip4addr';
		o.rmempty = false;

		return m.render();
	}
});
