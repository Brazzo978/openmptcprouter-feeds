local json = require 'luci.jsonc'
local fs = require 'nixio.fs'
local nixio = require 'nixio'
local sys = require 'luci.sys'
local uci = require 'luci.model.uci'
local model = require 'omr.profiles'
local transport = require 'omr.profile_transport'

local R = {}
R.__index = R
local persist='/etc/omr-profiles'
local runtime='/var/run/omr-profiles'
local journal=persist..'/pending.json'
local last=persist..'/last.json'
local store=persist..'/profiles.json'
local lease=runtime..'/lease.json'
local cache=runtime..'/capabilities.json'
local request=runtime..'/request.json'
local lock=runtime..'/state.lock'

local function read(path)
  local f=io.open(path,'rb'); if not f then return nil end
  local s=f:read('*a'); f:close(); return s
end

local function parse(s)
  if type(s)~='string' or #s>262144 then return nil end
  local ok,v=pcall(json.parse,s)
  if ok and type(v)=='table' then return v end
end

local function mkdirs()
  fs.mkdir(persist,'0700'); fs.chmod(persist,'0700')
  fs.mkdir(runtime,'0700'); fs.chmod(runtime,'0700')
  return fs.access(persist) and fs.access(runtime)
end

local function write_atomic(path,value)
  if not mkdirs() then return false end
  local ok,data=pcall(json.stringify,value)
  if not ok or type(data)~='string' then return false end
  local tmp=path..'.tmp.'..tostring(nixio.getpid())
  local f=io.open(tmp,'wb'); if not f then return false end
  fs.chmod(tmp,'0600')
  local written=f:write(data,'\n'); f:flush(); f:close()
  if not written then fs.unlink(tmp); return false end
  if not os.rename(tmp,path) then fs.unlink(tmp); return false end
  return true
end

local function cursor() return uci.cursor() end
local function strip(s) return type(s)=='string' and s:match('^%s*(.-)%s*$') or nil end
local function safe_server(s) return type(s)=='string' and #s>0 and #s<=64 and s:match('^[a-zA-Z0-9_-]+$')~=nil end
local function safe_tx(s) return type(s)=='string' and #s==32 and s:match('^[a-f0-9]+$')~=nil end
local function file_present(path) return fs.access(path) and true or false end
local function has_pending_changes()
  local packages={'firewall'}
  for _,pkg in ipairs(transport.packages) do packages[#packages+1]=pkg end
  for _,pkg in ipairs(packages) do
    local staged=read('/tmp/.uci/'..pkg)
    if staged and staged:match('%S') then return true end
  end
  return false
end

function R.new() mkdirs(); return setmetatable({},R) end

function R:boot_id()
  return strip(read('/proc/sys/kernel/random/boot_id')) or 'unknown'
end
function R:monotonic()
  return tonumber((read('/proc/uptime') or ''):match('^(%d+%.?%d*)')) or 0
end
function R:wall_time() return os.time() end
function R:heartbeat()
  return write_atomic(lease,{boot_id=self:boot_id(),monotonic=self:monotonic()})
end
function R:lease_valid()
  local l=parse(read(lease)); local now=self:monotonic()
  return l and l.boot_id==self:boot_id() and type(l.monotonic)=='number' and
         l.monotonic<=now and now-l.monotonic<=100
end

-- Process-owned kernel lock, automatically released on death. Never steal a
-- lock based on age: a suspended or slow process can still own it.
function R:locked(fn)
  mkdirs()
  local fd=nixio.open(lock,nixio.open_flags('creat','rdwr'),'0600')
  if not fd then return nil end
  if not fd:lock('tlock') then fd:close();return nil end
  local ok,result=pcall(fn)
  fd:lock('ulock');fd:close()
  if not ok then return nil end
  return result
end

function R:read_journal()
  local raw=read(journal)
  if not raw then return nil end
  local j=parse(raw)
  if not j or not safe_tx(j.transaction) or not safe_server(j.server) or type(j.phase)~='string' then
    return nil,'invalid journal'
  end
  return j
end
function R:write_journal(j) return write_atomic(journal,j) end
function R:clear_journal() fs.unlink(journal); return not file_present(journal) end
function R:read_last() return parse(read(last)) end
function R:write_last(result) return write_atomic(last,result) end

function R:random_id()
  local f=io.open('/dev/urandom','rb'); if not f then return nil end
  local bytes=f:read(16); f:close()
  if not bytes or #bytes~=16 then return nil end
  return (bytes:gsub('.',function(c) return string.format('%02x',string.byte(c)) end))
end

function R:read_raw()
  local raw={}
  for _,pkg in ipairs({'network','mqvpn'}) do
    local cmd='/usr/bin/timeout 4 /usr/bin/flock -s -w 2 /etc/config/'..pkg..
      ' /usr/bin/lua /usr/libexec/omr-profiles/uci-isolated '..pkg..' read 2>/dev/null'
    local values=parse(sys.exec(cmd))
    if not values then return nil end
    for key,value in pairs(values) do if model.fields[key] and model.fields[key][1]==pkg then raw[key]=value end end
  end
  return raw
end

-- Full secret-free selection snapshot, including each existing SS server's
-- disabled flag. Never load or retain host addresses, passwords or keys.
function R:read_transport()
  local result={}
  for _,pkg in ipairs(transport.packages) do
    if fs.stat('/etc/config/'..pkg) then
      local cmd='/usr/bin/timeout 4 /usr/bin/flock -s -w 2 /etc/config/'..pkg..
        ' /usr/bin/lua /usr/libexec/omr-profiles/uci-isolated '..pkg..' transport-read 2>/dev/null'
      local values=parse(sys.exec(cmd))
      if not values then return nil end
      for key,value in pairs(values) do
        if not transport.valid(key,value,true) then return nil end
        result[key]=value
      end
    end
  end
  return result
end

local function write_transport(values,raw)
  if has_pending_changes() then return false end
  local payload_path=runtime..'/uci-request.json'
  if not write_atomic(payload_path,{values=values,raw=raw}) then return false end
  for _,pkg in ipairs(transport.packages) do
    local needed=false
    for key in pairs(values) do local spec=transport.spec(key);if spec and spec[1]==pkg then needed=true;break end end
    if needed then
      local cmd='/usr/bin/timeout 20 /usr/bin/flock -x -w 10 /etc/config/'..pkg..
        ' /usr/bin/lua /usr/libexec/omr-profiles/uci-isolated '..pkg..' transport-write >/dev/null 2>&1'
      if os.execute(cmd)~=0 then fs.unlink(payload_path);return false end
    end
  end
  fs.unlink(payload_path);return true
end
function R:write_transport(values) return write_transport(values,true) end
function R:restore_transport(values) return write_transport(values,true) end

function R:current_effective(raw)
  if not raw then return nil end
  local result=model.effective(raw)
  -- An absent UCI option means the live kernel value is authoritative.
  if raw.tcp_scheduler==false or raw.tcp_scheduler=='' then
    result.tcp_scheduler=strip(read('/proc/sys/net/mptcp/scheduler'))
  end
  if raw.tcp_cc==false or raw.tcp_cc=='' then
    result.tcp_cc=strip(read('/proc/sys/net/ipv4/tcp_congestion_control'))
  end
  if not result.tcp_scheduler or not result.tcp_cc then return nil end
  return result
end

local function write_options(values, raw)
  if has_pending_changes() then return false end
  local payload_path=runtime..'/uci-request.json'
  if not write_atomic(payload_path,{values=values,raw=raw}) then return false end
  for _,pkg in ipairs({'network','mqvpn'}) do
    local needed=false
    for key in pairs(values) do if model.fields[key] and model.fields[key][1]==pkg then needed=true;break end end
    if needed then
      local cmd='/usr/bin/timeout 20 /usr/bin/flock -x -w 10 /etc/config/'..pkg..
        ' /usr/bin/lua /usr/libexec/omr-profiles/uci-isolated '..pkg..' write >/dev/null 2>&1'
      if os.execute(cmd)~=0 then fs.unlink(payload_path);return false end
    end
  end
  fs.unlink(payload_path)
  return true
end
function R:write_effective(values)
  local tuning={}
  for key,value in pairs(values) do if model.fields[key] then tuning[key]=value end end
  return not next(tuning) or write_options(tuning,false)
end
function R:restore_raw(values) return write_options(values,true) end

-- The generated configuration contains credentials. Inspect only these
-- allowlisted tuning values in memory; never return or persist the text.
local function generated_tuning()
  local text=read('/var/run/mqvpn.conf')
  if not text then return nil end
  local wanted={Multipath={Scheduler='mq_scheduler',CC='mq_cc',FecEnable='fec_enable',
    FecScheme='fec_scheme',ReinjectionControl='reinjection_control',ReinjectionMode='reinjection_mode'},
    Reorder={Enabled='reorder_enabled',MaxWaitMs='reorder_max_wait_ms',CapPackets='reorder_cap_packets'}}
  local values={mq_cc='bbr2',fec_enable='0',fec_scheme='reed_solomon',
    reinjection_control='0',reinjection_mode='default',reorder_enabled='0',
    reorder_max_wait_ms='30',reorder_cap_packets='1024'}
  local seen,section={},nil
  for line in text:gmatch('[^\r\n]+') do
    local heading=line:match('^%s*%[([^%]]+)%]%s*$')
    if heading then section=heading else
      local key,value=line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
      local field=key and wanted[section] and wanted[section][key]
      if field then
        if seen[field] then return nil end
        seen[field]=true
        if field=='fec_enable' or field=='reinjection_control' then
          value=({['true']='1',['false']='0',['1']='1',['0']='0'})[value]
        elseif field=='reorder_enabled' then value=({on='1',off='0'})[value] end
        if not value then return nil end
        values[field]=value
      end
    end
  end
  return values
end

function R:get_active()
  local value=parse(read(store))
  return value and value.active_id or 'default'
end
function R:set_active(id,journal_state)
  local value=parse(read(store))
  if not value or value.version~=1 or type(value.profiles)~='table' then return false end
  value.active_id=id
  if journal_state and journal_state.before_transport and journal_state.target_transport and
     journal_state.before_transport.vpn=='mqvpn' and journal_state.target_transport.vpn=='glorytun_tcp' then
    value.mq_baseline=journal_state.before_transport
  end
  return write_atomic(store,value)
end
function R:get_mq_baseline()
  local value=parse(read(store))
  return value and transport.snapshot_valid(value.mq_baseline) and value.mq_baseline or nil
end
function R:get_quick()
  local value=parse(read(store))
  return value and type(value.quick)=='table' and value.quick or nil
end
function R:set_quick(pair)
  local value=parse(read(store))
  if not value or value.version~=1 or type(value.profiles)~='table' then return false end
  value.quick={a=pair.a,b=pair.b}
  return write_atomic(store,value)
end
function R:custom_list()
  local value=parse(read(store))
  if not value or value.version~=1 or type(value.profiles)~='table' then return {} end
  return value.profiles
end
function R:save_custom(id,name,settings,remote,transport_state)
  local value=parse(read(store))
  if not value or value.version~=1 or type(value.profiles)~='table' then return false end
  for _,p in ipairs(value.profiles) do if p.id==id then return false end end
  value.profiles[#value.profiles+1]={id=id,name=name,settings=settings,remote_settings=remote,transport_state=transport_state}
  return write_atomic(store,value)
end
function R:delete_custom(id,quick)
  local value=parse(read(store))
  if not value or value.version~=1 or type(value.profiles)~='table' then return false end
  local result={};local found=false
  for _,p in ipairs(value.profiles) do
    if p.id==id then found=true else result[#result+1]=p end
  end
  if not found then return false end
  value.profiles=result
  value.quick={a=quick.a,b=quick.b}
  if value.active_id==id then value.active_id='default' end
  return write_atomic(store,value)
end

function R:selected_server()
  local c=cursor(); local best=0; local chosen=nil; local ties=0
  c:foreach('openmptcprouter','server',function(s)
    local name=s['.name']
    if safe_server(name) and s.disabled~='1' and s.username and s.username~='' and
       s.password and s.password~='' and s.port and s.port~='' and s.ip and s.ip~='' then
      local priority=(s.current=='1' and 3) or (s.master=='1' and 2) or (s.backup~='1' and 1) or 0
      if priority>best then best=priority;chosen=name;ties=1
      elseif priority>0 and priority==best then ties=ties+1 end
    end
  end)
  return (best>0 and ties==1) and chosen or nil
end

function R:local_ready(state)
  if has_pending_changes() then return false,'Save or discard pending network, proxy and firewall settings before changing profiles.' end
  state=state or self:read_transport()
  if not transport.snapshot_valid(state) or
     (state.vpn=='mqvpn' and state.mq_enable~='1') or
     (state.vpn=='glorytun_tcp' and state.glory_enable~='1') then
    return false,'The active VPN/proxy configuration is unsupported or inconsistent.'
  end
  if not self:selected_server() then return false,'A single configured active VPS is required.' end
  if not self:lease_valid() then return false,'The profiles service is starting or unavailable.' end
  return true
end

local function word_in_file(path,word)
  local s=read(path) or ''
  for item in s:gmatch('%S+') do if item==word then return true end end
  return false
end

local function module_present(name)
  -- OpenWrt installs kmods in the running kernel's directory. Search by a
  -- constant pattern and compare names; never interpolate request data.
  for path in fs.glob('/lib/modules/*/tcp_*.ko*') do
    local base=path:match('/([^/]+)%.ko')
    if base=='tcp_'..name then return true end
  end
  return false
end

function R:local_available(settings)
  if settings.tcp_scheduler and settings.tcp_scheduler~='default' and
     not word_in_file('/proc/sys/net/mptcp/available_schedulers',settings.tcp_scheduler) then
    local expected='mptcp_'..settings.tcp_scheduler..'.o'; local found=false
    for path in fs.glob('/usr/share/bpf/scheduler/*.o') do
      if path:match('/([^/]+)$')==expected then found=true;break end
    end
    if not found then return false,'MPTCP scheduler unavailable on this router: '..settings.tcp_scheduler end
  end
  if settings.tcp_cc and not word_in_file('/proc/sys/net/ipv4/tcp_available_congestion_control',settings.tcp_cc) and
     not module_present(settings.tcp_cc) then
    return false,'TCP congestion control unavailable on this router: '..settings.tcp_cc
  end
  if settings.transport=='glorytun_tcp' then
    if not file_present('/usr/sbin/glorytun') or not file_present('/etc/init.d/glorytun') then
      return false,'Glorytun TCP is not installed.'
    end
    local c=cursor()
    local key=c:get('glorytun','vpn','key');local host=c:get('glorytun','vpn','host');local port=c:get('glorytun','vpn','port')
    if not key or key=='' or key=='secretkey' or not host or host=='' or host=='127.0.0.1' or not port or port=='' then
      return false,'Glorytun TCP is not provisioned on this router.'
    end
  elseif settings.transport=='mqvpn' and not file_present('/usr/sbin/mqvpn') then
    return false,'MQVPN is not installed.'
  end
  local proxy=settings.proxy
  local proxy_service
  if proxy=='shadowsocks' then proxy_service='shadowsocks-libev'
  elseif proxy=='shadowsocks-rust' or proxy=='shadowsocks-go' then proxy_service='shadowsocks-rust'
  elseif proxy and proxy:match('^v2ray') then proxy_service='v2ray'
  elseif proxy and proxy:match('^xray') then proxy_service='xray' end
  if proxy_service and not file_present('/etc/init.d/'..proxy_service) then
    return false,'The selected proxy service is not installed.'
  end
  return true
end

function R:cached_capabilities()
  local item=parse(read(cache)); local now=self:monotonic()
  local server=self:selected_server()
  if not item or item.server~=server or item.boot_id~=self:boot_id() or
     type(item.monotonic)~='number' or item.monotonic>now or now-item.monotonic>15 then
    return nil,'Waiting for current VPS capabilities.'
  end
  if not item.data or item.data.supported~=true then
    return nil,'VPS profile API unavailable; update the VPS before switching profiles.',math.floor(now-item.monotonic)
  end
  return item.data,nil,math.floor(now-item.monotonic)
end

function R:remote(server, action, tx, payload, short_timeout)
  if not safe_server(server) or not safe_tx(tx) then return nil end
  if action~='capabilities' and action~='apply' and action~='route' and action~='status' and action~='confirm' and action~='rollback' then return nil end
  if action=='apply' or action=='route' then
    if type(payload)~='table' then return nil end
    local body=action=='apply' and {transaction=tx,mptcp=payload.mptcp,mqvpn=payload.mqvpn,
      transport=payload.transport,proxy=payload.proxy} or {transaction=tx,vpnremoteip=payload.vpnremoteip}
    if not write_atomic(request,body) then return nil end
  end
  self:heartbeat()
  -- Inputs used in this fixed command have strict alphabet/length checks.
  -- timeout bounds a dead VPS and keeps the service heartbeat from lingering.
  local limit=short_timeout==8 and '8' or '45'
  local command='/usr/bin/timeout '..limit..' /usr/libexec/omr-profiles/vps-bridge '..action..' '..server..' '..tx..' 2>/dev/null'
  local response=parse(sys.exec(command))
  if action=='apply' or action=='route' then fs.unlink(request) end
  return response
end

function R:refresh_capabilities()
  local server=self:selected_server()
  if not server then fs.unlink(cache); return end
  local tx='00000000000000000000000000000000'
  local data=self:remote(server,'capabilities',tx)
  -- Store only the documented tuning and availability fields. Never cache a
  -- full VPS /config response, credentials, addresses, profiles or logs.
  local current=data and model.sanitize_remote(data.current)
  if not data or data.supported~=true or tonumber(data.version)~=2 or not current or type(data.availability)~='table' then
    fs.unlink(cache); return
  end
  local a=data.availability; local lists={}
  for _,name in ipairs({'tcp_schedulers','tcp_cc','mq_schedulers','mq_cc','fec_schemes','transports','proxies'}) do
    if type(a[name])~='table' then fs.unlink(cache); return end
    local items={}
    for _,v in ipairs(a[name]) do
      if type(v)=='string' and #v<=32 and v:match('^[A-Za-z0-9_-]+$') then items[#items+1]=v end
    end
    lists[name]=items
  end
  write_atomic(cache,{server=server,boot_id=self:boot_id(),monotonic=self:monotonic(),
    data={supported=true,version=2,current=current,availability=lists}})
end

local function glorytun_connected(state)
  if not state or not transport.valid('net_device',state.net_device,false) or
     not transport.valid_ipv4(state.glory_remoteip) or state.glory_mptcp~='1' then return false end
  local info=parse(sys.exec('/usr/bin/timeout 4 /sbin/ubus call service list \'{"name":"glorytun"}\' 2>/dev/null'))
  local instances=info and info.glorytun and info.glorytun.instances
  return transport.glory_probe(instances,state,
    function(pid) return read('/proc/'..pid..'/cmdline') end,
    function(device,remote)
      -- MPTCP meta-sockets are not reliably listed in /proc/net/tcp. Probe
      -- the configured tunnel peer through its own interface instead.
      local cmd="/usr/bin/timeout 3 /bin/ping -c 1 -W 1 -I '"..device.."' '"..remote.."' >/dev/null 2>&1"
      return os.execute(cmd)==0
    end)
end

function R:route_ip(expected)
  local state=self:read_transport()
  if not state or not transport.valid('net_device',state.net_device,false) then return nil end
  local records=parse(sys.exec("/usr/bin/timeout 4 /sbin/ip -j -4 address show dev '"..state.net_device.."' 2>/dev/null"))
  local found={}
  for _,dev in ipairs(records or {}) do
    for _,item in ipairs(dev.addr_info or {}) do
      if item.family=='inet' and item.scope=='global' and type(item['local'])=='string' and
         item['local']:match('^%d+%.%d+%.%d+%.%d+$') then found[item['local']]=true end
    end
  end
  local ip,count=nil,0
  for value in pairs(found) do ip=value;count=count+1 end
  if count~=1 or (expected.transport=='glorytun_tcp' and ip~=state.glory_localip) then return nil end
  return ip
end

function R:restart_and_verify(expected, raw_after_restore, expected_flags, from_state, repair)
  if has_pending_changes() then return false end
  -- If an original TCP UCI option was absent, re-apply its previous *live*
  -- value for the restart, then remove it again to preserve the exact UCI
  -- representation. This also re-registers an earlier BPF scheduler.
  local temporary={}
  if raw_after_restore then
    for _,key in ipairs({'tcp_scheduler','tcp_cc'}) do
      if raw_after_restore[key]==false or raw_after_restore[key]=='' then temporary[key]=expected[key] end
    end
  end
  if next(temporary) and not write_options(temporary,false) then return false end
  self:heartbeat()
  local tcp_ok=os.execute('/usr/bin/timeout 35 /etc/init.d/mptcp restart >/dev/null 2>&1')==0
  if next(temporary) and not self:restore_raw(raw_after_restore) then return false end
  if not tcp_ok then return false end
  local selected=expected.transport=='glorytun_tcp' and 'glorytun' or 'mqvpn'
  local affected={}
  local function mark_proxy(proxy)
    if proxy=='shadowsocks' then affected['shadowsocks-libev']=true
    elseif proxy=='shadowsocks-rust' or proxy=='shadowsocks-go' then affected['shadowsocks-rust']=true
    elseif type(proxy)=='string' and proxy:match('^v2ray') then affected.v2ray=true
    elseif type(proxy)=='string' and proxy:match('^xray') then affected.xray=true end
  end
  if repair or not from_state or from_state.proxy~=expected.proxy then
    mark_proxy(expected.proxy);if from_state then mark_proxy(from_state.proxy) end
  end
  for key,value in pairs(expected_flags or {}) do
    if from_state and from_state[key]~=value then
      if key=='ss_libev_disabled' then affected['shadowsocks-libev']=true
      elseif key=='ss_rules_disabled' or key:match('^ssserver:') then affected['shadowsocks-rust']=true
      elseif key:match('^v2ray_') then affected.v2ray=true
      elseif key:match('^xray_') then affected.xray=true end
    end
  end
  -- Restarting xray with main disabled preserves its independent RPF instance.
  local function service_run(service,action)
    local limit=action=='start' and service~='omr-tracker' and 35 or 25
    return os.execute('/usr/bin/timeout '..limit..' /etc/init.d/'..service..' '..action..' >/dev/null 2>&1')==0
  end
  if not transport.transition_services(service_run,function() self:heartbeat() end,has_pending_changes,
      function(name) return file_present('/etc/init.d/'..name) end,selected,affected) then return false end
  if strip(read('/proc/sys/net/mptcp/scheduler'))~=expected.tcp_scheduler then return false end
  if strip(read('/proc/sys/net/ipv4/tcp_congestion_control'))~=expected.tcp_cc then return false end
  if expected.tcp_cc:match('^nanbbr[123]_var$') and
     strip(read('/sys/module/tcp_'..expected.tcp_cc..'/parameters/aggressiveness'))~=expected.tcp_nanbbr_aggressiveness then return false end
  local raw=self:read_raw()
  if not raw then return false end
  local now=self:current_effective(raw)
  if not now then return false end
  for key,value in pairs(expected) do if model.fields[key] and now[key]~=value then return false end end
  local state=self:read_transport()
  if not state or state.vpn~=expected.transport or state.proxy~=expected.proxy then return false end
  for key,value in pairs(expected_flags or {}) do if state[key]~=value then return false end end
  if expected.transport=='glorytun_tcp' then
    for _=1,30 do
      self:heartbeat()
      if glorytun_connected(state) and self:route_ip(expected) then return true end
      nixio.nanosleep(1)
    end
    return false
  end
  local generated=generated_tuning()
  if not generated then return false end
  for key,value in pairs(generated) do
    -- The init script emits the reorder section only when enabled. Preserve
    -- configured limits while off but do not pretend they are running.
    local inactive_limit=expected.reorder_enabled=='0' and
      (key=='reorder_max_wait_ms' or key=='reorder_cap_packets')
    if not inactive_limit and expected[key]~=value then return false end
  end
  if generated.mq_scheduler~=expected.mq_scheduler then return false end
  -- Process/handshake and actual scheduler, not merely a saved UCI value.
  for _=1,15 do
    self:heartbeat()
    local metrics=parse(sys.exec('/usr/bin/timeout 5 /usr/libexec/rpcd/mqvpn call metrics </dev/null 2>/dev/null'))
    if model.metrics_ready(metrics,expected) then return true end
    nixio.nanosleep(1)
  end
  return false
end

function R:sleep(seconds) nixio.nanosleep(seconds) end

function R:guard_active()
  local j,err=self:read_journal()
  if not j and not err then return false end
  if not self:lease_valid() then return false end
  -- An unresolved remote transaction should not suppress normal OMR
  -- synchronization forever if the VPS remains inaccessible for days.
  if j and j.boot_id==self:boot_id() and type(j.guard_release_mono)=='number' and
     self:monotonic()>=j.guard_release_mono then return false end
  return true
end

return R
