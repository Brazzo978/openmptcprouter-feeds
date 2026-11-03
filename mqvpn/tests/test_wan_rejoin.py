"""Isolated shell fixtures; no device, socket, UCI store or service is touched."""
import json,os,subprocess,tempfile,unittest,sys
from pathlib import Path
FEED=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(FEED/'openmptcprouter/tests'))
from test_api_paths import JSONFILTER
HOOK=FEED/'mqvpn/files/etc/hotplug.d/iface/40-mqvpn-path-rejoin'
TRACKER=FEED/'omr-tracker/files/usr/share/omr/post-tracking.d/005-mqvpn-path'
CLI=FEED/'mqvpn/files/usr/bin/mqvpn-path'
STUB=r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name;a=sys.argv[1:];e=os.environ
with open(e['TRACE'],'a') as f:f.write(json.dumps([name,*a])+'\n')
if name=='uci':
 key=a[-1]
 if '.proto' in key:print('dhcpv6' if 'wan1_6.' in key else 'dhcp')
 elif key=='mqvpn.settings.enable':print(e.get('ENABLE','1'))
 elif key=='openmptcprouter.settings.vpn':print(e.get('VPN','mqvpn'))
 elif key.endswith('.multipath'):print(e.get('MODE','master'))
 elif key.endswith('.vpn'):print('0')
 elif key.endswith('control_addr'):print('127.0.0.1')
 elif key.endswith('control_port'):print('9091')
elif name=='ubus':print(json.dumps({'up':e.get('UP','1')=='1','l3_device':e.get('DEVICE','eth1')}))
elif name in ('pidof','pgrep'):print('42');sys.exit(0 if e.get('RUNNING','1')=='1' else 1)
elif name=='mqvpn-path':
 p=Path(e['STATE']);state=json.loads(p.read_text())
 if a[0]=='list':print(json.dumps({'ok':True,'paths':state['paths']}))
 elif a[0]=='add':
  state['attempts']+=1
  ok=state['attempts']>int(e.get('FAIL_ADDS','0'))
  if ok:state['paths'].append(a[1])
  p.write_text(json.dumps(state));sys.exit(0 if ok else 1)
 elif a[0]=='remove':state['paths'].remove(a[1]);p.write_text(json.dumps(state))
elif name=='nc':
 request=json.load(sys.stdin)
 print(json.dumps({'ok':e.get('RPC_OK','true')=='true','paths':['eth1']}))
'''
class RejoinTests(unittest.TestCase):
 def run_fixture(self,source,extra=None,paths=None,args=()):
  with tempfile.TemporaryDirectory() as td:
   d=Path(td);b=d/'bin';b.mkdir();trace=d/'trace';state=d/'state'
   state.write_text(json.dumps({'paths':paths or [],'attempts':0}))
   for name in ['uci','ubus','pidof','pgrep','mqvpn-path','nc','sleep','logger']:
    p=b/name;p.write_text(STUB);p.chmod(0o700)
   (b/'jsonfilter').write_text(JSONFILTER);(b/'jsonfilter').chmod(0o700)
   guard=d/'guard';guard.write_text('#!/bin/sh\nexit '+('0' if (extra or {}).get('GUARD')=='1' else '1')+'\n');guard.chmod(0o700)
   body=source.read_text().replace('/usr/libexec/omr-profiles/guard',str(guard))
   script=d/'test.sh';script.write_text('_log() { :; }\n'+body);script.chmod(0o700)
   env=dict(os.environ,PATH=str(b)+':'+os.environ['PATH'],TRACE=str(trace),STATE=str(state),ACTION='ifup',INTERFACE='wan1',DEVICE='eth1',OMR_TRACKER_DEVICE='eth1',OMR_TRACKER_INTERFACE='wan1',OMR_TRACKER_STATUS='OK',OMR_TRACKER_PREV_STATUS='OK')
   env.update(extra or {})
   p=subprocess.run(['dash',str(script),*args],env=env,capture_output=True,text=True,timeout=5)
   calls=[json.loads(x) for x in trace.read_text().splitlines()] if trace.exists() else []
   return p,json.loads(state.read_text()),calls
 def test_ifup_restores_missing_path_without_restart(self):
  p,s,c=self.run_fixture(HOOK);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(s['paths'],['eth1'])
  self.assertFalse(any('restart' in row for row in c))
 def test_present_path_is_untouched(self):
  p,s,_=self.run_fixture(HOOK,paths=['eth1']);self.assertEqual(p.returncode,0);self.assertEqual(s['attempts'],0)
 def test_backup_mode_and_ipv6_companion_preserved(self):
  p,s,c=self.run_fixture(HOOK,{'MODE':'backup','INTERFACE':'wan1_6','ACTION':'ifupdate'})
  self.assertEqual(p.returncode,0,p.stderr);self.assertIn(['mqvpn-path','add','eth1','backup'],c)
  self.assertIn(['ubus','call','network.interface.wan1','status'],c)
 def test_disabled_unrelated_down_and_guarded_events_do_nothing(self):
  for extra in [{'ENABLE':'0'},{'VPN':'glorytun_tcp'},{'MODE':'off'},{'ACTION':'ifdown'},{'INTERFACE':'lan'},{'UP':'0'},{'RUNNING':'0'},{'GUARD':'1'},{'DEVICE':'eth1;bad'},{'INTERFACE':'wan1;bad'}]:
   with self.subTest(extra=extra):
    p,s,_=self.run_fixture(HOOK,extra);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(s['attempts'],0)
 def test_add_failure_retries_are_bounded(self):
  p,s,_=self.run_fixture(HOOK,{'FAIL_ADDS':'2'});self.assertEqual(p.returncode,0);self.assertEqual(s['attempts'],3)
  p,s,_=self.run_fixture(HOOK,{'FAIL_ADDS':'99'});self.assertNotEqual(p.returncode,0);self.assertEqual(s['attempts'],3)
 def test_tracker_reconciles_healthy_missing_path_without_status_change(self):
  p,s,_=self.run_fixture(TRACKER);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(s['paths'],['eth1'])
 def test_tracker_does_not_repeatedly_remove_or_override_guard(self):
  for extra in [{'OMR_TRACKER_STATUS':'ERROR','OMR_TRACKER_PREV_STATUS':'ERROR'},{'GUARD':'1'}]:
   p,s,_=self.run_fixture(TRACKER,extra,paths=['eth1']);self.assertEqual(p.returncode,0);self.assertEqual(s['paths'],['eth1'])
 def test_cli_reports_actual_rpc_success(self):
  for cmd in [('list',),('add','eth1'),('remove','eth1')]:
   for ok in ('true','false'):
    p,_,_=self.run_fixture(CLI,{'RPC_OK':ok},args=cmd)
    self.assertEqual(p.returncode==0,ok=='true',(cmd,ok,p.stderr))
if __name__=='__main__':unittest.main(verbosity=2)
