"""Real Lua router model <-> real Python VPS manager over localhost HTTP.

Kernel/UCI/service adapters are fixtures. This verifies the cross-language
transaction contract, not a complete OpenWrt/VPS deployment. Requires both
source repositories, Lua 5.1, lua-cjson and curl. All listeners use loopback.
"""
import copy,http.server,json,os,subprocess,sys,tempfile,threading,unittest
from pathlib import Path
from urllib.parse import urlparse,parse_qs

PACKAGE=Path(__file__).resolve().parents[1]
VPS=Path(os.environ.get('OMR_PROFILES_VPS_SOURCE',str(PACKAGE.parents[1]/'vps-repo')))
sys.path[:0]=[str(VPS/'admin'),str(VPS/'admin/test')]
import omr_profiles
from test_profiles_transactions import FakeRuntime

DRIVER=r'''
local json=require 'cjson'
local base=os.getenv('PROFILE_CONTRACT_URL')
local function luci_null(value)
  if value==json.null then return nil end
  if type(value)=='table' then for key,item in pairs(value) do value[key]=luci_null(item) end end
  return value
end
local function quote(s) return "'"..s:gsub("'", "'\\''").."'" end
local serial=1000
local function paired()
  local a,m=fixture();a.serial=serial;serial=serial+1000
  function a:remote(server,action,tx,payload)
    assert(server=='vps1')
    local route=action;local method='GET';local body
    if action=='status' then route='status?transaction='..tx
    elseif action=='capabilities' then route='capabilities?version=2'
    elseif action~='capabilities' then
      method='POST';body=clone(payload or {});body.transaction=tx
    end
    local filename
    local cmd='curl -s --max-time 3 -X '..method
    if body then
      filename=os.tmpname();local f=assert(io.open(filename,'wb'));f:write(json.encode(body));f:close()
      cmd=cmd..' -H '..quote('Content-Type: application/json')..' -d @'..quote(filename)
    end
    local proc=assert(io.popen(cmd..' '..quote(base..'/profiles/'..route)))
    local text=proc:read('*a');proc:close();if filename then os.remove(filename) end
    local ok,value=pcall(json.decode,text);return ok and luci_null(value) or nil
  end
  function a:cached_capabilities() return self:remote('vps1','capabilities',string.rep('0',32)),nil,0 end
  return a,m
end
local function check(v,message) assert(v,message or 'Contract assertion failed') end
local function fixture_action(name)
  local p=assert(io.popen('curl -s --max-time 3 -X POST '..quote(base..'/fixtures/'..name)))
  local response=p:read('*a');p:close();check(response=='ok')
end
local function apply(a,m,id)
  local r=m:apply(id);check(r and r.ok,r and r.error);m:tick();return r.transaction
end

-- Preserve deliberate router/VPS asymmetry and credentials outside the model.
local a,m=paired();local tx=apply(a,m,'default')
check(a.journal and a.journal.phase=='awaiting_confirm','Default did not verify across both models')
check(a.raw.reorder_enabled=='1')
check(a:cached_capabilities().current.mqvpn.reorder.enabled=='off')
check(m:confirm(tx).ok);m:tick();check(not a.journal and a.active=='default')

-- A lost confirm response is reconciled by querying the durable VPS decision.
a,m=paired();tx=apply(a,m,'performance')
check(a.journal and a.journal.phase=='awaiting_confirm','Performance did not verify')
check(m:confirm(tx).ok);m:tick();check(not a.journal and a.active=='performance','Lost confirm not reconciled')
check(a:cached_capabilities().current.mptcp.congestion_control=='nanbbr3_light')

-- Timeout restores both actual state machines to their respective snapshots.
a,m=paired();local before=clone(a.raw);local remote_before=a:cached_capabilities().current
tx=apply(a,m,'gaming');check(a.journal.phase=='awaiting_confirm')
a.clock=a.clock+61;m:tick();m:tick()
check(not a.journal,'Timed out profile was not rolled back')
check(a.raw.tcp_cc==before.tcp_cc and a.raw.tcp_scheduler==before.tcp_scheduler)
check(a:cached_capabilities().current.mptcp.congestion_control==remote_before.mptcp.congestion_control)

-- Custom profiles capture and restore separate current server settings.
a,m=paired();local saved=m:save('Asymmetric current');check(saved.ok,saved.error)
local p=m:find_profile(saved.id);check(p.remote_settings.mqvpn.reorder.enabled=='off')
tx=apply(a,m,saved.id);check(a.journal.phase=='awaiting_confirm')
check(m:rollback(tx).ok);m:tick();check(not a.journal)

-- Switch to both old presets; restore the previous Xray proxy and its flags.
fixture_action('xray')
a,m=paired();a.transport.proxy='xray';a.transport.xray_enabled='1'
a.transport.ss_rules_disabled='1';a.transport['ssserver:sss0']='1'
check(m:set_quick('performance_old','stability_old').ok)
check(m:status().quick.a=='performance_old' and m:status().quick.b=='stability_old')
tx=apply(a,m,'performance_old');check(a.journal.phase=='awaiting_confirm')
check(a.transport.vpn=='glorytun_tcp' and a.transport.proxy=='none' and a.transport.glory_mptcp=='1')
check(m:confirm(tx).ok);m:tick();check(a.baseline.proxy=='xray')
tx=apply(a,m,'gaming');check(a.journal.phase=='awaiting_confirm')
check(a.transport.vpn=='mqvpn' and a.transport.proxy=='xray' and a.transport.xray_enabled=='1')
check(m:confirm(tx).ok);m:tick()
tx=apply(a,m,'stability_old');check(a.journal.phase=='awaiting_confirm')
check(a.raw.tcp_scheduler=='bpf_red' and a.transport.proxy=='none')
check(m:rollback(tx).ok);m:tick();check(a.transport.vpn=='mqvpn' and a.transport.proxy=='xray')

-- A failed route update must roll back the server selection and local flags.
fixture_action('fail_route')
tx=apply(a,m,'performance_old');check(a.journal.phase=='rolling_back')
m:tick();check(not a.journal and a.transport.vpn=='mqvpn' and a.transport.proxy=='xray')
check(a:cached_capabilities().current.selection.vpn=='mqvpn')

-- No tunnel clears the route without a sentinel and restores it on return.
tx=apply(a,m,'no_tunnel');check(a.journal.phase=='awaiting_confirm')
check(a.transport.vpn=='none' and a.transport.ss_rules_udp==false)
check(a:cached_capabilities().current.selection.vpnremoteip==nil)
check(m:confirm(tx).ok);m:tick()
tx=apply(a,m,'gaming');check(a.journal.phase=='awaiting_confirm')
check(a.transport.vpn=='mqvpn' and a.transport.proxy=='xray')
check(a.transport.ss_rules_udp=='hi1' and a.transport['ssredir:hi1']=='0')
check(m:confirm(tx).ok);m:tick()
check(a:cached_capabilities().current.selection.vpnremoteip=='10.255.220.2')
tx=apply(a,m,'no_tunnel');check(a.journal.phase=='awaiting_confirm')
check(m:rollback(tx).ok);m:tick()
check(a.transport.vpn=='mqvpn' and a:cached_capabilities().current.selection.vpnremoteip=='10.255.220.2')
print('PASS: six profiles, No tunnel clear/restore, asymmetric custom, quick pair, route failure, timeout, lost confirm and transport rollback')
'''


class TransportRuntime(FakeRuntime):
    """Kernel/service effects are simulated; ProfileManager is the real code."""
    def __init__(self):
        super().__init__()
        self.value['selection']={'vpn':'mqvpn','proxy':'shadowsocks-rust',
                                 'global_vpn':'mqvpn','global_proxy':'shadowsocks-rust'}
        self.remote_ip='10.255.220.2'
        self.fail_route=False
    def availability(self):
        return {**super().availability(),'transports':['mqvpn','glorytun_tcp','none'],
                'proxies':['none','shadowsocks-rust','xray'],'tcp_proxies':['shadowsocks-rust']}
    def current(self):
        result=copy.deepcopy(self.value);result['selection']['vpnremoteip']=self.remote_ip
        return result
    def snapshot(self,target):
        return {'value':copy.deepcopy(self.value),'remote_ip':self.remote_ip}
    def apply(self,target):
        self.applies+=1
        self.value['mptcp'].update(target['mptcp'])
        if target.get('mqvpn') is not None:self.value['mqvpn'].update(target['mqvpn'])
        self.value['selection']={'vpn':target['transport'],'proxy':target['proxy'],
             'global_vpn':target['transport'],'global_proxy':target['proxy']}
    def restore(self,old):
        self.restores+=1
        self.value=copy.deepcopy(old['value']);self.remote_ip=old['remote_ip']
    def expected_remote(self,vpn):
        return {'mqvpn':'10.255.220.2','glorytun_tcp':'10.255.255.2'}[vpn]
    def apply_route(self,vpn,remote):
        if self.fail_route:
            self.fail_route=False
            raise RuntimeError('injected route failure')
        self.remote_ip=remote

class PairedContract(unittest.TestCase):
    def test_router_and_vps_transactions(self):
        with tempfile.TemporaryDirectory(prefix='omr-profile-contract-') as td:
            runtime=TransportRuntime();initial_secrets=copy.deepcopy(runtime.secrets)
            # All three algorithms are intentionally supported by the kernel fixture.
            manager=omr_profiles.ProfileManager(runtime,Path(td)/'journal',Path(td)/'lock',
                window=240,clock=lambda:1000.,monotonic=lambda:200.,boot_id=lambda:'contract',enable_timer=False)
            events=[];dropped_confirm=[False]
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self,*args):pass
                def respond(self,status,value):
                    body=json.dumps(value).encode();self.send_response(status)
                    self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)))
                    self.end_headers();self.wfile.write(body)
                def do_GET(self):
                    route=urlparse(self.path)
                    try:
                        if route.path=='/profiles/capabilities':value=manager.capabilities(int(parse_qs(route.query).get('version',['1'])[0]))
                        elif route.path=='/profiles/status':value=manager.status(parse_qs(route.query)['transaction'][0])
                        else:raise AssertionError(route.path)
                        self.respond(200,value)
                    except omr_profiles.ProfileError as e:self.respond(e.status,{'error':e.detail})
                def do_POST(self):
                    if self.path=='/fixtures/xray':
                        runtime.value['selection'].update({'proxy':'xray','global_proxy':'xray'})
                        body=b'ok';self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
                    if self.path=='/fixtures/fail_route':
                        runtime.fail_route=True
                        body=b'ok';self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
                    data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    tx=data.pop('transaction');events.append((self.path,copy.deepcopy(data)))
                    try:
                        if self.path=='/profiles/apply':value=manager.apply(tx,data)
                        elif self.path=='/profiles/route':value=manager.route(tx,data.get('vpnremoteip'),data.get('no_tunnel',False))
                        elif self.path=='/profiles/confirm':
                            value=manager.finish(tx,True)
                            if not dropped_confirm[0] and runtime.current()['mptcp']['congestion_control']=='nanbbr3_light':
                                dropped_confirm[0]=True;self.close_connection=True;return
                        elif self.path=='/profiles/rollback':value=manager.finish(tx,False)
                        else:raise AssertionError(self.path)
                        self.respond(200,value)
                    except omr_profiles.ProfileError as e:self.respond(e.status,{'error':e.detail})
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                # Reuse the router suite's isolated storage/UCI adapter, replacing
                # only its network adapter with the real localhost transport.
                fixture=(PACKAGE/'tests/test_profiles.lua').read_text().split('local function go(',1)[0]
                self.assertIn('local function fixture()',fixture)
                script=Path(td)/'paired.lua';script.write_text(fixture+DRIVER)
                env=dict(os.environ,LUA_PATH=str(PACKAGE/'files/usr/lib/lua/?.lua')+';;',PROFILE_CONTRACT_URL=f'http://127.0.0.1:{server.server_port}')
                result=subprocess.run([os.environ.get('PROFILE_LUA','lua5.1'),str(script)],env=env,capture_output=True,text=True,timeout=30)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('PASS:',result.stdout)
                self.assertTrue(dropped_confirm[0])
                self.assertEqual(runtime.secrets,initial_secrets)
                self.assertEqual(runtime.applies,11)
                self.assertEqual(runtime.restores,5)
                for path,body in events:
                    self.assertNotIn('auth_key',json.dumps(body))
                print(result.stdout.strip())
            finally:
                server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main(verbosity=2)
