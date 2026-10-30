"""Exercise the real Lua master/proxy checks with isolated service fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

package = Path(__file__).resolve().parents[1]
env = os.environ.copy()
env['LUA_PATH'] = str(package / 'files/usr/lib/lua/?.lua') + ';' + env['PROFILE_NIXIO_LUAPATH'] + '/?.lua;;'
env['LUA_CPATH'] = env['PROFILE_NIXIO_CPATH'] + '/?.so;' + env['PROFILE_JSON_CPATH'] + '/?.so;;'
with tempfile.TemporaryDirectory(prefix='omr-no-tunnel-') as directory:
    root = Path(directory)
    generated = root / 'generated'
    generated.mkdir()
    for name in ('ss_redir.hi1', 'ss_local.tracker_sss0'):
        (generated / (name + '.json')).write_text(json.dumps({'mptcp': True, 'password': 'private-fixture'}))
    runtime = (package / 'files/usr/lib/lua/omr/profiles_runtime.lua').read_text()
    runtime = runtime.replace("local persist='/etc/omr-profiles'", "local persist='" + str(root / 'persist') + "'")
    runtime = runtime.replace("local runtime='/var/run/omr-profiles'", "local runtime='" + str(root / 'run') + "'")
    runtime = runtime.replace("'/var/etc/shadowsocks-rust/", "'" + str(generated) + "/")
    (root / 'runtime.lua').write_text(runtime)
    script = root / 'runtime_test.lua'
    script.write_text(r'''
local json=require 'cjson'
package.preload['luci.jsonc']=function() return {parse=json.decode,stringify=json.encode} end
local cfg={
 ['openmptcprouter.settings.master']='failover',
 ['shadowsocks-rust.ss_rules.disabled']='0',['shadowsocks-rust.ss_rules.redir_tcp']='all',
 ['shadowsocks-rust.ss_rules.src_default']='forward',['shadowsocks-rust.ss_rules.dst_default']='forward',
 ['shadowsocks-rust.sss0.server']='198.51.100.5',['shadowsocks-rust.sss0.password']='private-fixture',
 ['shadowsocks-rust.sss0.disabled']='0',['shadowsocks-rust.tracker_sss0.server']='sss0',
 ['shadowsocks-rust.tracker_sss0.local_address']='127.0.0.1',
 ['shadowsocks-rust.tracker_sss0.local_port']='1111',['shadowsocks-rust.tracker_sss0.mptcp']='1'
}
local sections={network={{['.name']='wan',multipath='master'},{['.name']='lan',multipath='off'}},
 ['shadowsocks-rust']={{['.name']='hi1',server='sss0',mode='tcp_and_udp',mptcp='1'}}}
local cursor={}
function cursor:get(pkg,section,option) return cfg[pkg..'.'..section..'.'..option] end
function cursor:foreach(pkg,kind,fn) for _,s in ipairs(sections[pkg] or {}) do fn(s) end end
package.preload['luci.model.uci']=function() return {cursor=function() return cursor end} end
local route_dev='eth0';local seen={};local tcp_chain=true;local udp_chain=false;local proxy_exchange=true
package.preload['luci.sys']=function() return {exec=function(command)
  seen[#seen+1]=command
  if command:find('network.interface.wan',1,true) then return json.encode({up=true,l3_device='eth0'}) end
  if command:find('network.interface.lan',1,true) then return json.encode({up=true,l3_device='br-lan',['ipv4-address']={{address='192.168.4.1',mask=24}}}) end
  if command:find('route show default',1,true) then return json.encode({{dev=route_dev,metric=1}}) end
  if command:find('route get',1,true) then return json.encode({{dev=route_dev}}) end
  if command:find('shadowsocks-rust',1,true) then
    return json.encode({['shadowsocks-rust']={instances={['ss_redir.hi1']={running=true},['ss_local.tracker_sss0']={running=true}}}})
  end
  if command:find('ss_rules_forward_tcp',1,true) then return tcp_chain and 'redirect to :1100' or '' end
  return ''
end} end
os.execute=function(command)
  seen[#seen+1]=command
  if command:find('ss_rules_forward_udp',1,true) then return udp_chain and 0 or 1 end
  if command:find('/usr/bin/curl',1,true) then return proxy_exchange and 0 or 1 end
  return 0
end
local R=dofile(arg[1]);local r=R.new();function r:heartbeat() end
assert(r:master_route_ready());assert(r:tcp_proxy_ready())
local udp,icmp=false,false
for _,command in ipairs(seen) do
  if command:find('ipproto udp',1,true) then udp=true end
  if command:find('ipproto icmp',1,true) then icmp=true end
  assert(not command:find('private-fixture',1,true),'credentials must not enter command text')
end
assert(udp and icmp)
route_dev='eth1';assert(not r:master_route_ready());route_dev='eth0'
cfg['openmptcprouter.settings.master']='balancing';assert(not r:master_wan())
cfg['openmptcprouter.settings.master']='failover'
udp_chain=true;assert(not r:tcp_proxy_ready());udp_chain=false
proxy_exchange=false;assert(not r:tcp_proxy_ready());proxy_exchange=true
sections['shadowsocks-rust'][1].mptcp='0';assert(not r:tcp_proxy_ready())
print('PASS: live-check adapter rejects wrong WAN, ECMP mode, UDP interception, broken TCP proxy and non-MPTCP redirect')
''')
    result = subprocess.run([env['PROFILE_LUA'], str(script), str(root / 'runtime.lua')], env=env,
                            capture_output=True, text=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    print(result.stdout.strip())
