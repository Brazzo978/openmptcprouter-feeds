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
local function quote(s) return "'"..s:gsub("'", "'\\''").."'" end
local serial=1000
local function paired()
  local a,m=fixture();a.serial=serial;serial=serial+1000
  function a:remote(server,action,tx,payload)
    assert(server=='vps1')
    local route=action;local method='GET';local body
    if action=='status' then route='status?transaction='..tx
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
    local ok,value=pcall(json.decode,text);return ok and value or nil
  end
  function a:cached_capabilities() return self:remote('vps1','capabilities',string.rep('0',32)),nil,0 end
  return a,m
end
local function check(v,message) assert(v,message or 'Contract assertion failed') end
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
print('PASS: Default asymmetry, Performance + lost confirm, Gaming timeout rollback, custom save/revert across Lua and Python managers')
'''

class PairedContract(unittest.TestCase):
    def test_router_and_vps_transactions(self):
        with tempfile.TemporaryDirectory(prefix='omr-profile-contract-') as td:
            runtime=FakeRuntime();initial_secrets=copy.deepcopy(runtime.secrets)
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
                        if route.path=='/profiles/capabilities':value=manager.capabilities()
                        elif route.path=='/profiles/status':value=manager.status(parse_qs(route.query)['transaction'][0])
                        else:raise AssertionError(route.path)
                        self.respond(200,value)
                    except omr_profiles.ProfileError as e:self.respond(e.status,{'error':e.detail})
                def do_POST(self):
                    data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    tx=data.pop('transaction');events.append((self.path,copy.deepcopy(data)))
                    try:
                        if self.path=='/profiles/apply':value=manager.apply(tx,data)
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
                self.assertEqual(runtime.applies,4)
                self.assertEqual(runtime.restores,2)
                for path,body in events:
                    self.assertNotIn('auth_key',json.dumps(body))
                print(result.stdout.strip())
            finally:
                server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main(verbosity=2)
