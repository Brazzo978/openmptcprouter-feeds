-- The transport transaction stores only these non-secret UCI flags/addresses.
local M={}
M.fields={
  vpn={'openmptcprouter','settings','vpn'},
  proxy={'openmptcprouter','settings','proxy'},
  glory_enable={'glorytun','vpn','enable'},
  glory_mptcp={'glorytun','vpn','mptcp'},
  glory_proto={'glorytun','vpn','proto'},
  glory_localip={'glorytun','vpn','localip'},
  glory_remoteip={'glorytun','vpn','remoteip'},
  glory_device={'glorytun','vpn','dev'},
  mq_enable={'mqvpn','settings','enable'},
  mq_device={'mqvpn','interface','tun_name'},
  glory_udp_enable={'glorytun-udp','vpn','enable'},
  dsvpn_enable={'dsvpn','vpn','enable'},
  openvpn_enable={'openvpn','omr','enabled'},
  softether_enable={'softethervpn','openmptcprouter','enable'},
  ss_libev_disabled={'shadowsocks-libev','sss0','disabled'},
  ss_rules_disabled={'shadowsocks-rust','ss_rules','disabled'},
  v2ray_enabled={'v2ray','main','enabled'},
  xray_enabled={'xray','main','enabled'},
  v2ray_protocol={'v2ray','omrout','protocol'},
  xray_protocol={'xray','omrout','protocol'},
  net_proto={'network','omrvpn','proto'},
  net_device={'network','omrvpn','device'},
  six_localip={'network','omr6in4','ipaddr'},
  six_remoteip={'network','omr6in4','peeraddr'},
}
M.packages={'openmptcprouter','glorytun','glorytun-udp','dsvpn','openvpn','softethervpn','mqvpn','shadowsocks-libev','shadowsocks-rust','v2ray','xray','network'}
local proxies={none=true,shadowsocks=true,['shadowsocks-rust']=true,['shadowsocks-go']=true,
  v2ray=true,['v2ray-vmess']=true,['v2ray-trojan']=true,['v2ray-socks']=true,
  xray=true,['xray-vless-reality']=true,['xray-vmess']=true,['xray-trojan']=true,
  ['xray-socks']=true,['xray-shadowsocks']=true}
function M.proxy(value) return proxies[value]==true end
function M.vpn(value) return value=='mqvpn' or value=='glorytun_tcp' end
function M.spec(key)
  if M.fields[key] then return M.fields[key] end
  local section=type(key)=='string' and key:match('^ssserver:([A-Za-z0-9_]+)$')
  if section and #section<=64 then return {'shadowsocks-rust',section,'disabled'} end
end
function M.valid(key,value,raw)
  if not M.spec(key) then return false end
  if value==false then return raw==true end
  if type(value)~='string' or #value>64 or value:find('[%z\1-\31\127]') then return false end
  if raw then return true end
  if key=='vpn' then return M.vpn(value) end
  if key=='proxy' then return M.proxy(value) end
  if key=='glory_proto' then return value=='tcp' end
  if key=='v2ray_protocol' or key=='xray_protocol' then return value:match('^[A-Za-z0-9_-]+$')~=nil end
  if key=='net_proto' then return value=='none' end
  if key=='glory_device' or key=='mq_device' or key=='net_device' then
    return #value>0 and #value<=15 and value:match('^[A-Za-z0-9_.-]+$')~=nil and value~='.' and value~='..'
  end
  if key=='glory_localip' or key=='glory_remoteip' or key=='six_localip' or key=='six_remoteip' then
    return #value>0 and value:match('^[0-9a-fA-F:.]+$')~=nil
  end
  return value=='0' or value=='1'
end

function M.snapshot_valid(snapshot)
  if type(snapshot)~='table' or not M.vpn(snapshot.vpn) or not M.proxy(snapshot.proxy) then return false end
  for key,value in pairs(snapshot) do if not M.valid(key,value,true) then return false end end
  return true
end

local function copy(source)
  local out={} for k,v in pairs(source or {}) do out[k]=v end return out
end

-- Compute only safe-to-write flags. Credentials, firewall rules, WireGuard
-- policy, forwarding configuration and physical WAN settings are absent.
function M.plan(before, vpn, proxy, baseline, custom)
  if not M.snapshot_valid(before) or not M.vpn(vpn) or not M.proxy(proxy) then return nil end
  if before.mq_enable==nil or before.glory_enable==nil or before.net_proto==nil or before.net_device==nil then return nil end
  if vpn=='mqvpn' and before.vpn=='glorytun_tcp' and not M.snapshot_valid(baseline) and
     not M.snapshot_valid(custom) and (before.six_localip~=nil or before.six_remoteip~=nil) then return nil end
  for _,key in ipairs({'glory_udp_enable','dsvpn_enable','openvpn_enable','softether_enable'}) do
    if before[key]=='1' then return nil end
  end
  if vpn=='glorytun_tcp' and
     (not M.valid('glory_device',before.glory_device,false) or
      not M.valid_ipv4(before.glory_localip) or
      not M.valid_ipv4(before.glory_remoteip)) then return nil end
  local target={vpn=vpn,proxy=proxy,mq_enable=vpn=='mqvpn' and '1' or '0',
    glory_enable=vpn=='glorytun_tcp' and '1' or '0',net_proto='none'}
  if vpn=='glorytun_tcp' then
    target.glory_mptcp='1';target.glory_proto='tcp'
    target.net_device=before.glory_device
    if before.six_localip~=nil then target.six_localip=before.glory_localip end
    if before.six_remoteip~=nil then target.six_remoteip=before.glory_remoteip end
  elseif (baseline and M.snapshot_valid(baseline) and baseline.vpn=='mqvpn') or
         (custom and M.snapshot_valid(custom) and custom.vpn=='mqvpn') then
    local saved=(custom and M.snapshot_valid(custom) and custom.vpn=='mqvpn') and custom or baseline
    if saved.six_localip~=nil then target.six_localip=saved.six_localip end
    if saved.six_remoteip~=nil then target.six_remoteip=saved.six_remoteip end
  end
  if vpn=='mqvpn' then
    local device=before.mq_device
    if device==nil or device==false or device=='' then device='mqvpn0' end
    if not M.valid('mq_device',device,false) then return nil end
    target.net_device=device
  end
  local use_custom=custom and M.snapshot_valid(custom) and custom.proxy==proxy and custom or nil
  local use_baseline=not use_custom and baseline and M.snapshot_valid(baseline) and baseline.proxy==proxy and baseline or nil
  local saved=use_custom or use_baseline
  local protocols={v2ray='vless',['v2ray-vmess']='vmess',['v2ray-trojan']='trojan',['v2ray-socks']='socks',
    xray='vless',['xray-vless-reality']='vless-reality',['xray-vmess']='vmess',['xray-trojan']='trojan',
    ['xray-socks']='socks',['xray-shadowsocks']='shadowsocks'}
  for _,key in ipairs({'v2ray_protocol','xray_protocol'}) do
    local service=key:match('^(.-)_protocol$')
    if before[key]~=nil and proxy:match('^'..service) then
      if saved and saved[key]~=nil then target[key]=saved[key] else target[key]=protocols[proxy] end
    end
  end
  for key,value in pairs(before) do
    if key=='ss_libev_disabled' or key=='ss_rules_disabled' or key=='v2ray_enabled' or key=='xray_enabled' or key:match('^ssserver:') then
      if saved and saved[key]~=nil then target[key]=saved[key]
      elseif key=='ss_libev_disabled' then target[key]=proxy=='shadowsocks' and '0' or '1'
      elseif key=='ss_rules_disabled' then target[key]=(proxy=='shadowsocks-rust' or proxy=='shadowsocks-go') and '0' or '1'
      elseif key=='v2ray_enabled' then target[key]=proxy:match('^v2ray') and '1' or '0'
      elseif key=='xray_enabled' then target[key]=proxy:match('^xray') and '1' or '0'
      elseif key=='ssserver:sss0' then target[key]=(proxy=='shadowsocks-rust' or proxy=='shadowsocks-go') and '0' or '1'
      else target[key]='1' end
    end
  end
  for key,value in pairs(target) do if not M.valid(key,value,true) then return nil end end
  return target
end
M.copy=copy

function M.valid_ipv4(value)
  if type(value)~='string' then return false end
  local a,b,c,d=value:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  if not a then return false end
  for _,n in ipairs({a,b,c,d}) do if #n>3 or tonumber(n)>255 then return false end end
  return true
end

function M.glory_process_mptcp(cmdline)
  if type(cmdline)~='string' then return false end
  local first=true;local binary_ok=false;local mptcp=false
  for token in cmdline:gmatch('[^%z]+') do
    if first then binary_ok=token=='/usr/sbin/glorytun' or token=='glorytun';first=false
    elseif token=='mptcp' then mptcp=true end
  end
  return binary_ok and mptcp
end

function M.glory_probe(instances,state,read_process,ping)
  if type(instances)~='table' or type(state)~='table' or
     not M.valid('net_device',state.net_device,false) or not M.valid_ipv4(state.glory_remoteip) or
     state.glory_mptcp~='1' then return false end
  for _,instance in pairs(instances) do
    local pid=type(instance)=='table' and tonumber(instance.pid)
    if pid and pid>1 and pid%1==0 and instance.running and M.glory_process_mptcp(read_process(pid)) and
       ping(state.net_device,state.glory_remoteip) then return true end
  end
  return false
end

-- Always bring the tracker back after attempting to stop it, even if any
-- VPN/proxy command fails or raises an exception. Heartbeat before each call.
function M.transition_services(run, heartbeat, pending, present, vpn, affected)
  local function invoke(service,action)
    heartbeat();return run(service,action)
  end
  local ok,result=pcall(function()
    if not invoke('omr-tracker','stop') then return false end
    for _,service in ipairs({'mqvpn','glorytun'}) do
      if present(service) and not invoke(service,'stop') then return false end
    end
    if not invoke(vpn,'start') then return false end
    for _,service in ipairs({'shadowsocks-libev','shadowsocks-rust','v2ray','xray'}) do
      if affected[service] and present(service) then
        if pending() or not invoke(service,'restart') then return false end
      end
    end
    return true
  end)
  local tracker_ok,tracker_result=pcall(function() return invoke('omr-tracker','start') end)
  return ok and result and tracker_ok and tracker_result or false
end
return M
