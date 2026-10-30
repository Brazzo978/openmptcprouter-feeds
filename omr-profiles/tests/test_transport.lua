-- Fault and tunnel-readiness tests with deterministic process/service fixtures.
local t=require 'omr.profile_transport'
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
print('PASS: tracker failure recovery, MPTCP command line and interface-bound peer probe')
