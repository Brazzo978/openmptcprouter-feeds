'use strict';
'require form';

return L.view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('mqvpn', _('MQVPN'), _('Multipath QUIC VPN over MASQUE CONNECT-IP. On OpenMPTCProuter, routing is normally managed by OMR, so internal mqvpn route management should stay disabled.'));

		s = m.section(form.NamedSection, 'vpn', 'mqvpn', _('Client'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('general', _('General Settings'));
		s.tab('advanced', _('Advanced Settings'));

		o = s.taboption('general', form.Flag, 'enable', _('Enabled'));
		o.default = o.disabled;

		o = s.taboption('general', form.Value, 'host', _('Server'));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'port', _('Port'));
		o.default = '65411';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'key', _('Authentication key'));
		o.password = true;
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'dev', _('Tunnel interface'));
		o.default = 'mqvpn0';
		o.placeholder = 'mqvpn0';
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'scheduler', _('Scheduler'));
		o.value('wlb', _('Weighted load balancing'));
		o.value('minrtt', _('Minimum RTT'));
		o.value('backup_fec', _('Backup FEC'));
		o.default = 'wlb';

		o = s.taboption('advanced', form.Flag, 'paths_auto', _('Use OMR WAN interfaces as mqvpn paths'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'insecure', _('Allow self-signed server certificate'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('advanced', form.Flag, 'manage_routes', _('Let mqvpn manage system routes'));
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
		o.default = '10.255.249.2';
		o.datatype = 'ip4addr';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'remoteip', _('Server tunnel IP'));
		o.default = '10.255.249.1';
		o.datatype = 'ip4addr';
		o.rmempty = false;

		return m.render();
	}
});
