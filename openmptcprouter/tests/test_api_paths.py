"""Isolated Bash/Dash tests of the real shared helper; all HTTP is simulated.

No router, real UCI, service or network is touched. Run with Linux Python 3.
Curl fixtures are separate processes, so concurrency and cancellation are real.
"""
import json,os,subprocess,tempfile,time,unittest
from pathlib import Path

FEED=Path(__file__).resolve().parents[2]
HELPER=FEED/'omr-api-paths/files/api-paths.sh'
INIT=FEED/'openmptcprouter/files/etc/init.d/openmptcprouter-vps'
TRACKER=FEED/'omr-tracker/files/bin/omr-tracker-server'
HOMEPAGE='"Welcome to OpenMPTCProuter Server part"'
CURL=r'''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
a=sys.argv[1:]; iface=a[a.index('--interface')+1] if '--interface' in a else '@default'
url=a[-1]; phase='health' if url.endswith('/') else 'request'
method=a[a.index('-X')+1] if '-X' in a else 'GET'
headers=[a[i+1] for i,x in enumerate(a) if x=='-H']
event={'phase':phase,'iface':iface,'method':method,'url':url,'pid':os.getpid(),'time':time.monotonic(),
 'form':[a[i+1] for i,x in enumerate(a) if x=='--data-urlencode']}
fd=os.open(os.environ['TRACE'],os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
os.write(fd,(json.dumps(event)+'\n').encode());os.close(fd)
sc=json.loads(os.environ['SCENARIO'])
rule=sc.get(phase,{}).get(iface,{'rc':28})
if phase=='request' and 'Authorization: Bearer stale' in headers:
 rule={'code':401}
time.sleep(rule.get('delay',0))
body=rule.get('body','"Welcome to OpenMPTCProuter Server part"' if phase=='health' else '{"ok":true}')
Path(a[a.index('--output')+1]).write_text(body)
sys.stdout.write(str(rule.get('code',200)))
sys.exit(rule.get('rc',0))
'''
JSONFILTER=r'''#!/usr/bin/env python3
import json,sys
try:
 a=sys.argv[1:]
 obj=json.load(open(a[a.index('-i')+1])) if '-i' in a else json.load(sys.stdin)
 if '-t' in a:
  print('object' if isinstance(obj,dict) else 'other');sys.exit(0)
 expr=a[a.index('-e')+1] if '-e' in a else '@'
 for key in expr.removeprefix('@').strip('.').split('.') if expr!='@' else []: obj=obj[key]
 print(obj if isinstance(obj,str) else json.dumps(obj))
except (ValueError,KeyError,TypeError,IndexError): sys.exit(1)
'''

def extract(path,name):
    import re
    return re.search(r'^'+name+r'\(\) \{\n.*?^\}',path.read_text(),re.M|re.S).group()

class ApiPathTests(unittest.TestCase):
    def run_case(self,command,scenario,rows='ethA is in default mode\nethB is in backup mode\nethC is in subflow mode',extra=''):
        outputs=[]
        for shell in ('bash','dash'):
            with self.subTest(shell=shell),tempfile.TemporaryDirectory() as td:
                d=Path(td); b=d/'bin';b.mkdir();tmp=d/'tmp';tmp.mkdir()
                for name,content in [('curl',CURL),('jsonfilter',JSONFILTER),('logger','#!/bin/sh\nexit 0\n')]:
                    p=b/name;p.write_text(content);p.chmod(0o700)
                env=dict(os.environ,PATH=str(b)+':'+os.environ['PATH'],TRACE=str(d/'trace'),SCENARIO=json.dumps(scenario),ROWS=rows,OMR_API_TMPDIR=str(tmp))
                script='multipath() { printf "%s\\n" "$ROWS"; }; valid_subnet6() { case "$1" in *:*) echo ok;; *) echo invalid;; esac; };\n'
                script+=' . "'+str(HELPER)+'"\n'+extra+'\n'+command
                start=time.monotonic();p=subprocess.run([shell,'-c',script],env=env,capture_output=True,text=True,timeout=8)
                elapsed=time.monotonic()-start
                events=[json.loads(x) for x in (d/'trace').read_text().splitlines()] if (d/'trace').exists() else []
                self.assertEqual(list(tmp.iterdir()),[],p.stderr)
                outputs.append((p,events,elapsed))
        return outputs

    def test_interface_modes_and_duplicates(self):
        rows='ethA is in default mode\nethB is in backup mode\nethC is in subflow mode\nethD is in signal mode\nethA is in default mode\nlan is deactivated\n--bad is in default mode'
        for p,_,_ in self.run_case('omr_api_interfaces',{},rows):
            self.assertEqual(p.stdout.splitlines(),['ethA','ethB','ethC','ethD'])

    def test_fast_backup_wins_and_all_wans_are_probed(self):
        sc={'health':{'@default':{'delay':1.5,'rc':28},'ethA':{'delay':1.5,'rc':28},'ethB':{'delay':.12},'ethC':{'delay':1.5,'rc':28}}}
        for p,events,elapsed in self.run_case('omr_api_select_path https://192.0.2.1:65500',sc):
            self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout.strip(),'ethB')
            self.assertEqual({x['iface'] for x in events},{'@default','ethA','ethB','ethC'})
            self.assertLess(elapsed,.9)
            for e in events:
                with self.assertRaises(ProcessLookupError):os.kill(e['pid'],0)

    def test_html_and_http_error_do_not_win(self):
        sc={'health':{'@default':{'body':'<html>proxy</html>'},'ethA':{'code':503},'ethB':{'delay':.1}}}
        for p,_,_ in self.run_case('omr_api_select_path https://192.0.2.1:65500',sc):self.assertEqual(p.stdout.strip(),'ethB')

    def test_no_healthy_path_means_no_write(self):
        for p,events,_ in self.run_case('omr_api_request POST https://192.0.2.1:65500 mqvpn token "{}"',{}):
            self.assertNotEqual(p.returncode,0);self.assertFalse(any(x['phase']=='request' for x in events))

    def test_post_and_side_effecting_config_get_are_not_fanned_out(self):
        sc={'health':{'ethB':{}},'request':{'ethB':{}}}
        for method,route in [('POST','mqvpn'),('GET','config?serial=test')]:
            for p,events,_ in self.run_case(f'omr_api_request {method} https://192.0.2.1:65500 "{route}" token "{{}}"',sc):
                self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(json.loads(p.stdout),{'ok':True})
                self.assertEqual(len([x for x in events if x['phase']=='request']),1)

    def test_timeout_after_possible_upload_is_not_replayed(self):
        sc={'health':{'ethB':{},'ethC':{'delay':.15}},'request':{'ethB':{'rc':28},'ethC':{}}}
        for p,events,_ in self.run_case('omr_api_request POST https://192.0.2.1:65500 mqvpn token "{}"',sc):
            self.assertEqual(p.returncode,12);self.assertTrue(json.loads(p.stdout)['delivery_uncertain'])
            self.assertEqual(len([x for x in events if x['phase']=='request']),1)

    def test_connect_failure_before_delivery_can_use_another_wan(self):
        sc={'health':{'ethB':{},'ethC':{'delay':.15}},'request':{'ethB':{'rc':7},'ethC':{}}}
        for p,events,_ in self.run_case('omr_api_request POST https://192.0.2.1:65500 mqvpn token "{}"',sc):
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertEqual([x['iface'] for x in events if x['phase']=='request'],['ethB','ethC'])

    def test_invalid_json_and_auth_failure_are_not_returned_as_config(self):
        for response,code in [({'body':'<html>bad</html>'},12),({'code':401},10),({'code':403},11),({'code':403,'body':'{"detail":"Could not validate credentials"}'},10),({'code':429},11),({'code':503},11)]:
            sc={'health':{'ethB':{}},'request':{'ethB':response}}
            for p,events,_ in self.run_case('omr_api_request GET https://192.0.2.1:65500 config token',sc):
                self.assertEqual(p.returncode,code,p.stderr)
                if code==10:self.assertEqual(p.stdout,'')
                else:self.assertIsNotNone(json.loads(p.stdout))
                self.assertEqual(len([x for x in events if x['phase']=='request']),1)

    def test_ipv6_url_and_interface_binding(self):
        sc={'health':{'ethC':{}},'request':{'ethC':{}}}
        for p,events,_ in self.run_case('omr_api_request GET "$(omr_api_base_url 2001:db8::1 65500)" config token',sc):
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertTrue(all(x['url'].startswith('https://[2001:db8::1]:65500/') for x in events))
            self.assertEqual([x['iface'] for x in events if x['phase']=='request'],['ethC'])

    def test_login_is_single_and_uses_encoded_form_fields(self):
        sc={'health':{'ethB':{}},'request':{'ethB':{'body':'{"access_token":"fixture"}'}}}
        for p,events,_ in self.run_case('omr_api_request LOGIN https://192.0.2.1:65500 token "" "user+1" "p&a ss"',sc):
            self.assertEqual(p.returncode,0,p.stderr)
            req=[x for x in events if x['phase']=='request'];self.assertEqual(len(req),1)
            self.assertEqual(req[0]['form'],['username=user+1','password=p&a ss'])

    def test_server_tracker_checks_backup_concurrently(self):
        sc={'health':{'@default':{'delay':1.5,'rc':28},'ethA':{'delay':1.5,'rc':28},'ethB':{}}}
        extra=extract(TRACKER,'_check_server_intf')+'\nserver_ping=false; retry=0; intervaltries=0; OMR_TRACKER_TIMEOUT=1\n'
        for p,_,elapsed in self.run_case('_check_server_intf 192.0.2.1 65500; printf "%s" "$server_ping"',sc,extra=extra):
            self.assertEqual(p.stdout,'true',p.stderr);self.assertLess(elapsed,.9)

    def test_get_wrapper_refreshes_auth_only_once(self):
        sc={'health':{'ethB':{}},'request':{'ethB':{}}}
        extra=extract(INIT,'_get_json')+'''
token=stale;server=192.0.2.1;serverport=65500
_login() { token=fresh; }
'''
        for p,events,_ in self.run_case('_get_json config',sc,extra=extra):
            self.assertEqual(json.loads(p.stdout),{'ok':True},p.stderr)
            self.assertEqual(len([x for x in events if x['phase']=='request']),2)

    def test_post_wrapper_does_not_replay_an_ambiguous_timeout(self):
        sc={'health':{'ethB':{}},'request':{'ethB':{'rc':28}}}
        extra=extract(INIT,'_set_json')+'\ntoken=fresh;server=192.0.2.1;serverport=65500\n'
        for p,events,_ in self.run_case('_set_json mqvpn "{}"',sc,extra=extra):
            self.assertEqual(p.returncode,12,p.stderr);self.assertTrue(json.loads(p.stdout)['delivery_uncertain'])
            self.assertEqual(len([x for x in events if x['phase']=='request']),1)

    def test_login_rejection_does_not_repeat_on_other_server_addresses(self):
        sc={'health':{'ethB':{}},'request':{'ethB':{'code':400,'body':'{"detail":"Incorrect username or password"}'}}}
        extra=extract(INIT,'_login')+'''
token='';servername=vps
config_load() { :; }
config_list_foreach() { "$3" 192.0.2.1; "$3" 192.0.2.2; }
uci() {
 case "$*" in
  '-q get openmptcprouter.vps.username') echo user;;
  '-q get openmptcprouter.vps.password') echo fixture;;
  '-q get openmptcprouter.vps.port') echo 65500;;
 esac
}
'''
        for p,events,_ in self.run_case('_login',sc,extra=extra):
            self.assertEqual(p.stdout,'',p.stderr)
            self.assertEqual(len([x for x in events if x['phase']=='request']),1)

    def test_last_probe_completion_cannot_hide_a_published_winner(self):
        # Insert a synchronization hook without altering the selection branches:
        # the winner is published after the first check, before the done scan.
        instrumented=HELPER.read_text().replace('\t\tdone_count=0; n=1','\t\t_audit_finish\n\t\tdone_count=0; n=1')
        extra=instrumented+'''
_omr_api_probe() { :; }
_audit_finish() {
 mkdir -p "$dir/winner"
 printf '%s\\n' @default > "$dir/winner/interface"
 : > "$dir/1.done"
}
'''
        for p,_,_ in self.run_case('omr_api_select_path https://192.0.2.1:65500',{},rows='',extra=extra):
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertEqual(p.stdout.strip(),'@default')

    def test_post_auth_rejection_can_refresh_and_submit_once_authorized(self):
        sc={'health':{'ethB':{}},'request':{'ethB':{}}}
        extra=extract(INIT,'_set_json')+'''
token=stale;server=192.0.2.1;serverport=65500
_login() { token=fresh; }
'''
        for p,events,_ in self.run_case('_set_json mqvpn "{}"',sc,extra=extra):
            self.assertEqual(json.loads(p.stdout),{'ok':True},p.stderr)
            self.assertEqual(len([x for x in events if x['phase']=='request']),2)

    def test_wireguard_ip_loop_stops_after_uncertain_delivery_or_http_denial(self):
        for response in ({'rc':28},{'code':403,'body':'{"detail":"Only the primary writable user may change remote LAN access"}'},{'code':502,'body':'<html>gateway</html>'}):
            sc={'health':{'ethB':{}},'request':{'ethB':response}}
            extra=extract(INIT,'_set_json')+'\n'+extract(INIT,'_wireguard_remote_access_ip')+'''
token=fresh;serverport=65500
wireguard_remote_result='';wireguard_remote_action=allow
'''
            for p,events,_ in self.run_case('_wireguard_remote_access_ip 192.0.2.1; _wireguard_remote_access_ip 192.0.2.2; printf "%s" "$wireguard_remote_result"',sc,extra=extra):
                result=json.loads(p.stdout)
                self.assertTrue('error' in result or 'detail' in result,p.stderr)
                self.assertEqual(len([x for x in events if x['phase']=='request']),1)

    def test_partial_upgrade_pulls_shared_helper_package(self):
        self.assertIn('omr-api-paths',(FEED/'omr-tracker/Makefile').read_text())
        self.assertIn('omr-api-paths',(FEED/'openmptcprouter/Makefile').read_text())
        package=(FEED/'omr-api-paths/Makefile').read_text()
        self.assertIn('$(INSTALL_DATA) ./files/api-paths.sh $(1)/usr/share/omr/api-paths.sh',package)
        self.assertTrue(HELPER.exists())

    def test_sync_token_context_preserves_ipv6_colons(self):
        extra=extract(INIT,'_parse_token_server')
        for address in ('192.0.2.1','vps.example.test','2001:db8::1','::1'):
            command='_parse_token_server "'+address+':65500:fixture.jwt"; printf "%s|%s|%s" "$server" "$serverport" "$token"'
            for p,_,_ in self.run_case(command,{},extra=extra):
                self.assertEqual(p.stdout,address+'|65500|fixture.jwt',p.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
