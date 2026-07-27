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
		o.value('backup', _('Backup path'));
		o.value('backup_fec', _('Backup FEC'));
		o.value('rap', _('RAP'));
		o.default = 'wlb';

			o = s.taboption('general', form.ListValue, 'cc', _('Congestion control'));
			o.value('bbr2', _('BBR2 (experimental)'));
			o.value('bbr', _('BBR'));
			o.value('cubic', _('CUBIC'));
			o.value('new_reno', _('New Reno'));
			o.value('copa', _('COPA'));
			o.value('unlimited', _('Unlimited'));
			o.default = 'cubic';

			o = s.taboption('general', form.ListValue, 'mtu_profile', _('MTU profile'));
			o.value('safe', _('Safe - 1320, PMTUD off'));
			o.value('default', _('Default - 1400, PMTUD off'));
			o.value('performance', _('Performance - 1380, PMTUD cap 1420'));
			o.value('extreme', _('Extreme - 1400, PMTUD cap 1472'));
			o.value('manual', _('Manual override'));
			o.default = 'default';
			o.description = _('Controls MQVPN QUIC packet sizing. 1472 is the maximum UDP payload for a 1500-byte IPv4 path MTU.');

			o = s.taboption('advanced', form.Value, 'mtu', _('Tunnel MTU'));
			o.default = '0';
			o.placeholder = '0';
			o.datatype = 'uinteger';
			o.description = _('0 = automatic. Use 1280-1402 only when pinning the mqvpn tunnel MTU.');

			o = s.taboption('advanced', form.Value, 'outer_packet_size', _('Outer packet size'));
			o.default = '1400';
			o.placeholder = '1400';
			o.datatype = 'uinteger';
			o.depends('mtu_profile', 'manual');
			o.description = _('Manual mode only. QUIC/UDP payload size before IP/UDP overhead. Use 1298-1472.');

			o = s.taboption('advanced', form.Flag, 'pmtud', _('Enable PMTUD probing'));
			o.default = o.disabled;
			o.rmempty = false;
			o.depends('mtu_profile', 'manual');
			o.description = _('Manual mode only. Lets xquic probe upward from the base packet size; keep disabled on unstable mobile links unless testing.');

			o = s.taboption('advanced', form.Value, 'pmtud_probe_size', _('PMTUD probe limit'));
			o.default = '1420';
			o.placeholder = '1420';
			o.datatype = 'uinteger';
			o.depends({ mtu_profile: 'manual', pmtud: '1' });

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
