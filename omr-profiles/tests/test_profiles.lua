-- Offline transaction tests. Run with Lua 5.1 and LUA_PATH=files/usr/lib/lua/?.lua;;
local lib=require 'omr.profiles'
local function clone(x)
  if type(x)~='table' then return x end
  local t={} for k,v in pairs(x) do t[k]=clone(v) end return t
end
local function fixture()
  local a={clock=1000,server='vps1',active='default',profiles={},journal=nil,
    cap={supported=true,version=2,current={
      mptcp={scheduler='default',congestion_control='bbr',nanbbr_aggressiveness=50},
      selection={vpn='mqvpn',proxy='shadowsocks-rust',global_vpn='mqvpn',global_proxy='shadowsocks-rust'},
      mqvpn={scheduler='minrtt',cc='bbr2',fec_enable=false,fec_scheme='xor',
        reinjection_control=false,reinjection_mode='default',
        reorder={enabled='auto',max_wait_ms=30,cap_packets=1024}}},
      availability={tcp_schedulers={'default','bpf_red'},tcp_cc={'bbr','nanbbr3_light'},
        mq_schedulers={'minrtt','wlb'},mq_cc={'bbr2'},fec_schemes={'xor','reed_solomon'},
        transports={'mqvpn','glorytun_tcp'},proxies={'none','shadowsocks-rust','xray'}}}}
  a.raw={tcp_scheduler='default',tcp_cc='bbr',tcp_nanbbr_aggressiveness='50',
    mq_scheduler='minrtt',mq_cc='bbr2',fec_enable='0',fec_scheme='reed_solomon',
    reinjection_control='0',reinjection_mode='default',reorder_enabled='1',
    reorder_max_wait_ms='30',reorder_cap_packets='1024'}
  a.route_ip_value='10.255.220.2'
  a.transport={vpn='mqvpn',proxy='shadowsocks-rust',mq_enable='1',glory_enable='0',
    glory_mptcp='1',glory_proto='tcp',glory_localip='10.255.255.2',glory_remoteip='10.255.255.1',
    glory_device='tun0',mq_device='tun0',net_device='tun0',net_proto='none',ss_rules_disabled='0',
    ['ssserver:sss0']='0',xray_enabled='0',six_localip='10.255.220.2',six_remoteip='10.255.220.1'}
  function a:locked(f) return f() end
  function a:read_raw() return clone(self.raw) end
  function a:current_effective(r) return lib.effective(r) end
  function a:local_ready() return true end
  function a:local_available() return true end
  function a:selected_server() return self.server end
  function a:cached_capabilities() if self.stale then return nil,'stale' end return clone(self.cap),nil,0 end
  function a:custom_list() return clone(self.profiles) end
  function a:save_custom(id,name,settings,remote,local_state)
    self.profiles[#self.profiles+1]={id=id,name=name,settings=clone(settings),remote_settings=clone(remote),transport_state=clone(local_state)};return true
  end
  function a:delete_custom(id,quick) for i,p in ipairs(self.profiles) do if p.id==id then table.remove(self.profiles,i);self.quick=clone(quick);return true end end end
  function a:get_quick() return clone(self.quick) end
  function a:set_quick(q) self.quick=clone(q);return true end
  function a:get_active() return self.active end
  function a:set_active(id,j) self.active=id;if j and j.before_transport.vpn=='mqvpn' and j.target_transport.vpn=='glorytun_tcp' then self.baseline=clone(j.before_transport) end;return true end
  function a:get_mq_baseline() return clone(self.baseline) end
  function a:read_transport() return clone(self.transport) end
  function a:write_transport(values) for k,v in pairs(values) do self.transport[k]=v end return true end
  function a:restore_transport(values) self.transport=clone(values);return true end
  function a:route_ip() return self.transport.vpn=='glorytun_tcp' and '10.255.255.2' or self.route_ip_value end
  function a:read_journal() return clone(self.journal) end
  function a:write_journal(j) self.journal=clone(j);return true end
  function a:clear_journal() self.journal=nil;return true end
  function a:write_last(v) self.last=clone(v);return true end
  function a:read_last() return clone(self.last) end
  function a:random_id() self.serial=(self.serial or 0)+1;return string.format('%032x',self.serial) end
  function a:boot_id() return 'boot1' end
  function a:monotonic() return self.clock end
  function a:wall_time() return self.clock+100000 end
  function a:heartbeat() end
  function a:write_effective(v) if self.fail_write then self.raw.tcp_cc='bbr';return false end for k,x in pairs(v) do if lib.fields[k] then self.raw[k]=x end end return true end
  function a:restore_raw(v) self.raw=clone(v);return true end
  function a:restart_and_verify() return not self.fail_restart end
  function a:remote(server,action,tx,payload)
    assert(server==self.server)
    if action=='capabilities' then if self.fail_cap then return nil end return clone(self.cap) end
    if action=='apply' then
      self.old_remote=clone(self.cap.current)
      for _,group in ipairs({'mptcp','mqvpn'}) do
        for k,v in pairs(payload[group] or {}) do self.cap.current[group][k]=clone(v) end
      end
      self.cap.current.selection={vpn=payload.transport,proxy=payload.proxy,global_vpn=payload.transport,global_proxy=payload.proxy}
      self.remote_state='pending'
      if self.lost_apply then return nil end
      return {result='done',transaction=tx}
    end
    if action=='route' then
      if self.route_fail then return nil end
      self.route_ready=true;return {result='done',transaction=tx,state='pending',route_ready=true}
    end
    if action=='rollback' then
      if self.remote_offline then return nil end
      self.cap.current=clone(self.old_remote);self.remote_state='rolled_back'
      return {result='done',state='rolled_back'}
    end
    if action=='confirm' then
      self.remote_state='confirmed'
      if self.lost_confirm then return nil end
      return {result='done',state='confirmed'}
    end
    if action=='status' then
      if self.remote_offline then return nil end
      return {result='done',state=self.remote_state,seconds_remaining=self.remaining or 200,route_ready=self.route_ready}
    end
  end
  return a,lib.new(a)
end
local function go(a,m,id)
  local r=m:apply(id); assert(r.ok,r.error);m:tick();return r.transaction
end
do
  local a,m=fixture();a.transport.glory_device='tun77';a.transport.mq_device='tun9';a.transport.net_device='tun9'
  local before=clone(a.transport)
  local tx=go(a,m,'performance_old')
  assert(a.journal.phase=='awaiting_confirm' and a.transport.net_device=='tun77')
  assert(m:rollback(tx).ok);m:tick()
  assert(a.transport.net_device=='tun9' and a.transport.mq_device==before.mq_device)
  tx=go(a,m,'performance_old');assert(m:confirm(tx).ok);m:tick()
  tx=go(a,m,'gaming');assert(a.transport.net_device=='tun9')
  assert(m:confirm(tx).ok);m:tick()
end
do
  local a,m=fixture();local s=m:status()
  assert(s.quick.a=='default' and s.quick.b=='gaming')
  assert(not m:set_quick('default','default').ok)
  assert(not m:set_quick('default','missing').ok)
  local custom=m:save('Quick profile');assert(custom.ok)
  assert(m:set_quick(custom.id,'default').ok and a.active=='default')
  assert(m:status().quick.a==custom.id and m:status().quick.b=='default')
  local tx=go(a,m,'gaming');assert(not m:set_quick('default','performance').ok)
  assert(m:rollback(tx).ok);m:tick()
  assert(m:delete(custom.id).ok)
  assert(a.quick.a=='gaming' and a.quick.b=='default')
  assert(m:status().quick.a=='gaming' and m:status().quick.b=='default')
  a.quick={a='missing',b='missing'}
  assert(m:status().quick.a=='default' and m:status().quick.b=='gaming')
end
do
  local a,m=fixture();local status=m:status();assert(status.ok)
  assert(status.current.reorder_enabled=='1' and status.remote_current.reorder_enabled=='auto')
  assert(status.presets[1].settings.reorder_enabled=='1' and status.presets[1].remote_settings.reorder_enabled=='0')
  assert(status.presets[1].settings.fec_scheme=='reed_solomon' and status.presets[1].remote_settings.fec_scheme=='xor')
  local saved=m:save('Asymmetric');assert(saved.ok,saved.error)
  assert(a.profiles[1].remote_settings.mqvpn.reorder.enabled=='auto')
  assert(a.profiles[1].settings.reorder_enabled=='1')
  local tx=go(a,m,'default');assert(a.journal.phase=='awaiting_confirm')
  assert(a.raw.reorder_enabled=='1' and a.cap.current.mqvpn.reorder.enabled=='off')
  assert(m:confirm(tx).ok);m:tick();assert(not a.journal and a.active=='default')
  local custom=go(a,m,saved.id);assert(a.journal.phase=='awaiting_confirm')
  assert(a.cap.current.mqvpn.reorder.enabled=='auto');assert(m:confirm(custom).ok);m:tick()
  assert(a.active==saved.id)
end
do
  local a,m=fixture();local tx=go(a,m,'performance');assert(a.journal.phase=='awaiting_confirm')
  assert(a.raw.tcp_cc=='nanbbr3_light' and a.cap.current.mqvpn.scheduler=='wlb')
  a.clock=a.clock+61;m:tick();m:tick();assert(not a.journal and a.active=='default')
  assert(a.raw.tcp_cc=='bbr' and a.cap.current.mqvpn.scheduler=='minrtt')
end
do
  local a,m=fixture();a.lost_apply=true;go(a,m,'gaming');assert(a.journal.phase=='rolling_back')
  m:tick();assert(not a.journal and a.cap.current.mqvpn.reorder.enabled=='auto')
end
do
  local a,m=fixture();a.fail_write=true;go(a,m,'gaming');assert(a.journal.phase=='rolling_back')
  m:tick();assert(not a.journal and a.raw.tcp_scheduler=='default')
end
do
  local a,m=fixture();a.remaining=69;go(a,m,'gaming');assert(a.journal.phase=='rolling_back')
  m:tick();assert(not a.journal)
end
do
  local a,m=fixture();local tx=go(a,m,'gaming');a.lost_confirm=true
  assert(m:confirm(tx).ok);m:recover();m:tick();assert(not a.journal and a.active=='gaming')
end
do
  local a,m=fixture();go(a,m,'gaming');a.remote_offline=true;a.clock=a.clock+61;m:tick();m:tick()
  assert(a.journal.phase=='rollback_failed');a.remote_offline=false
  assert(m:rollback(a.journal.transaction).ok);m:tick();assert(not a.journal)
end
do
  local a,m=fixture();a.fail_cap=true;assert(not m:save('no stale snapshot').ok)
  assert(not m:save('bad\nname').ok);a.fail_cap=false;a.stale=true
  assert(not m:apply('gaming').ok);assert(not m:delete('default').ok)
end
do
  local desired={mq_scheduler='minrtt',fec_enable='1'}
  local metrics={reachable=true,build_info={scheduler='minrtt',fec_enabled=1},
    stats={n_clients=1},status={clients={{}}},fec={clients={{enable_fec=0}}}}
  assert(not lib.metrics_ready(metrics,desired),'compiled FEC does not prove runtime activation')
  metrics.fec.clients[1].enable_fec=true;assert(lib.metrics_ready(metrics,desired))
  desired.fec_enable='0';assert(not lib.metrics_ready(metrics,desired))
  metrics.fec.clients[1].enable_fec=false;assert(lib.metrics_ready(metrics,desired))
  metrics.build_info.fec_enabled=0;metrics.fec=nil;assert(lib.metrics_ready(metrics,desired))
end
do
  local a,m=fixture();a.cap.availability.fec_schemes={}
  local saved=m:save('FEC active');assert(saved.ok)
  a.profiles[1].settings.fec_enable='1'
  a.profiles[1].remote_settings.mqvpn.fec_enable=true
  local status=m:status()
  assert(status.presets[1].available,'Default with FEC off must remain usable without known schemes')
  assert(not status.presets[6].available,'FEC on must require a proven scheme')
  assert(not m:apply(saved.id).ok)
  local tx=go(a,m,'default');assert(a.journal.phase=='awaiting_confirm');assert(m:confirm(tx).ok);m:tick()
end
do
  local a,m=fixture()
  a.transport.proxy='xray';a.transport.xray_enabled='1';a.transport.ss_rules_disabled='1';a.transport['ssserver:sss0']='1'
  a.cap.current.selection.proxy='xray';a.cap.current.selection.global_proxy='xray'
  local old=go(a,m,'stability_old')
  assert(a.journal.phase=='awaiting_confirm' and a.route_ready)
  assert(a.transport.vpn=='glorytun_tcp' and a.transport.glory_mptcp=='1' and a.transport.proxy=='none')
  assert(a.transport.xray_enabled=='0' and a.transport.six_localip=='10.255.255.2')
  assert(m:confirm(old).ok);m:tick();assert(a.baseline.proxy=='xray')
  local newer=go(a,m,'gaming')
  assert(a.journal.phase=='awaiting_confirm' and a.transport.vpn=='mqvpn')
  assert(a.transport.proxy=='xray' and a.transport.xray_enabled=='1')
  assert(a.transport.six_localip=='10.255.220.2')
  assert(m:rollback(newer).ok);m:tick()
  assert(a.transport.vpn=='glorytun_tcp' and a.transport.proxy=='none')
end
do
  local a,m=fixture();a.route_fail=true;go(a,m,'performance_old')
  assert(a.journal.phase=='rolling_back');a.route_fail=false;m:tick()
  assert(not a.journal and a.transport.vpn=='mqvpn')
end
do
  local a,m=fixture();a.cap.availability.transports={'mqvpn'}
  assert(not m:apply('performance_old').ok)
  local saved=m:save('Capture VPN and proxy');assert(saved.ok)
  assert(a.profiles[1].settings.transport=='mqvpn' and a.profiles[1].settings.proxy=='shadowsocks-rust')
  assert(a.profiles[1].transport_state.mq_enable=='1')
end
print('PASS: profiles defaults, asymmetric custom, timeout, partial failure, rollback, confirmation recovery, availability')
