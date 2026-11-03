-- Fault and tunnel-readiness tests with deterministic process/service fixtures.
local t=require 'omr.profile_transport'
local function is_server(name) return name=='vps' or name=='vps2' end
local token='openmptcprouter.vps.token=eyJhbGci.eyJzdWI.signature'
assert(t.token_only_delta('openmptcprouter',token,is_server))
assert(t.token_only_delta('openmptcprouter',token.."\nopenmptcprouter.vps2.token='abc.def.ghi'\n",is_server))
for _,delta in ipairs({
  token..'\nopenmptcprouter.settings.vpn=mqvpn',
  token..'\nopenmptcprouter.settings.proxy=xray',
  token..'\n-openmptcprouter.vps.token',
  'openmptcprouter.settings.token=abc.def.ghi',
  'openmptcprouter.missing.token=abc.def.ghi',
  'openmptcprouter.vps.token=',
  'openmptcprouter.vps.token=not-a-jwt',
  'openmptcprouter.vps.token=abc.def.ghi\ncorrupt',
  'openmptcprouter.vps.token=abc.def.ghi\0bad',
}) do assert(not t.token_only_delta('openmptcprouter',delta,is_server)) end
assert(not t.token_only_delta('network',token,is_server))
assert(not t.token_only_delta('openmptcprouter',token,function() error('uci failure') end))
local services={'omr-tracker:stop','mqvpn:stop','glorytun:stop','glorytun:start','xray:restart','omr-tracker:start'}
local function exercise(fail,throws,pending_failure)
  local calls={};local beats=0
  local function run(service,action)
    local name=service..':'..action;calls[#calls+1]=name
    if name==throws then error('injected failure') end
    return name~=fail
  end
  local ok=t.transition_services(run,function() beats=beats+1 end,
    function() return pending_failure end,function() return true end,'glorytun',{xray=true})
  assert(calls[#calls]=='omr-tracker:start','tracker must restart on every path')
  assert(beats==#calls,'every bounded service operation requires a heartbeat')
  return ok,calls
end
local success,calls=exercise();assert(success and #calls==#services)
for _,fail in ipairs({'omr-tracker:stop','mqvpn:stop','glorytun:stop','glorytun:start','xray:restart','omr-tracker:start'}) do
  assert(not exercise(fail),fail..' must reject')
end
assert(not exercise(nil,'glorytun:start'))
assert(not exercise(nil,nil,true))

for _,failure in ipairs({'return_false','throw'}) do
  local last
  local ok=t.transition_services(function(service,action) last=service..':'..action;return true end,
    function() end,function() return false end,function() return true end,'none',{},function(vpn)
      assert(vpn=='none')
      if failure=='throw' then error('network fixture failure') end
      return false
    end)
  assert(not ok and last=='omr-tracker:start','Network handover failures must restore the tracker and reject the profile')
end

local state={net_device='tun7',glory_remoteip='10.255.255.1',glory_mptcp='1'}
local proc={first={running=true,pid=42}}
local command='/usr/sbin/glorytun\0keyfile\0/run/key\0mptcp\0host\0example\0'
local probes=0
local function read(pid) assert(pid==42);return command end
local function ping(device,remote)
  probes=probes+1;assert(device=='tun7' and remote=='10.255.255.1');return true
end
assert(t.glory_probe(proc,state,read,ping) and probes==1)
assert(not t.glory_probe(proc,state,read,function() return false end),'ICMP failure must reject readiness')
command='/usr/sbin/glorytun\0host\0example\0'
assert(not t.glory_probe(proc,state,read,ping),'missing MPTCP process flag must reject')
command='/usr/sbin/glorytun\0mptcp\0';state.glory_remoteip='1.2.3.4;touch /tmp/x'
assert(not t.glory_probe(proc,state,read,ping),'shell metacharacters must reject')
state.glory_remoteip='1.2.3.999'
assert(not t.glory_probe(proc,state,read,ping),'invalid IPv4 must reject')
state.glory_remoteip='10.255.255.1';state.net_device='tun0;false'
assert(not t.glory_probe(proc,state,read,ping),'invalid interface must reject')
local wan={{name='wan1',mode='master'},{name='wan2',mode='on'},{name='lan',mode='master'}}
assert(t.unique_master({},wan)=='wan1')
assert(not t.unique_master({master='balancing'},wan))
assert(not t.unique_master({defaultgw='0'},wan))
assert(not t.unique_master({},{{name='wan1',mode='master'},{name='wan2',mode='master'}}))
assert(t.master_default({{dev='other',metric=20},{dev='eth0',metric=1}},'eth0'))
assert(not t.master_default({{dev='eth0',metric=1,nexthops={{dev='eth1'}}}},'eth0'))
assert(not t.master_default({{dev='eth0',metric=1},{dev='eth1',metric=1}},'eth0'))
assert(not t.master_default({{dev='eth1',metric=1}},'eth0'))
print('PASS: tracker failure recovery, Glorytun peer probe, unique master and ECMP rejection')
