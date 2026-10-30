"""Real curl/TLS loopback tests; JSONfilter is a Python fixture, not OpenWrt's binary.

All listeners bind 127.0.0.1. No router or external server is contacted.
The multi-WAN timing/mode tests are separately in test_api_paths.py.
"""
import http.server,json,os,ssl,subprocess,tempfile,threading,time,unittest
from pathlib import Path
from test_api_paths import HELPER,JSONFILTER

class ApiHttpsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();cls.root=Path(cls.tmp.name)
        cls.events=[];cls.lock=threading.Lock()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*a):pass
            def send_json(self,status,value):
                payload=json.dumps(value).encode()
                self.send_response(status);self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(payload)));self.end_headers()
                try:self.wfile.write(payload)
                except (BrokenPipeError,ssl.SSLError):pass
            def do_GET(self):
                with cls.lock:cls.events.append(('GET',self.path,None))
                self.send_json(200,'Welcome to OpenMPTCProuter Server part' if self.path=='/' else {'vpn':{'remoteip':'192.0.2.1'}})
            def do_POST(self):
                body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
                with cls.lock:cls.events.append(('POST',self.path,body))
                if self.path=='/uncertain':time.sleep(10.5)
                if self.path=='/denied':self.send_json(403,{'detail':'Only the primary writable user may change remote LAN access'})
                else:self.send_json(200,{'result':'done'})
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(cls.root/'key.pem'),'-out',str(cls.root/'cert.pem'),'-days','1','-subj','/CN=localhost'],capture_output=True,check=True)
        cls.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        cls.server.daemon_threads=True;cls.server.block_on_close=False
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cls.root/'cert.pem',cls.root/'key.pem')
        cls.server.socket=context.wrap_socket(cls.server.socket,server_side=True)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
        cls.base=f'https://127.0.0.1:{cls.server.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join();cls.tmp.cleanup()

    def request(self,method,route,payload='{}',secret=''):
        with tempfile.TemporaryDirectory() as td:
            d=Path(td);p=d/'jsonfilter';p.write_text(JSONFILTER);p.chmod(0o700)
            tmp=d/'tmp';tmp.mkdir()
            env=dict(os.environ,PATH=str(d)+':'+os.environ['PATH'],OMR_API_TMPDIR=str(tmp),NO_PROXY='127.0.0.1')
            script='multipath() { echo "lo is in default mode"; }; . "$1"; omr_api_request "$2" "$3" "$4" fixture "$5" "$6"'
            result=subprocess.run(['dash','-c',script,'audit',str(HELPER),method,self.base,route,payload,secret],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(list(tmp.iterdir()),[],result.stderr)
            return result

    def test_real_https_post_is_delivered_once(self):
        p=self.request('POST','set-config','{"scheduler":"minrtt"}')
        self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(json.loads(p.stdout),{'result':'done'})
        self.assertEqual([x for x in self.events if x[1]=='/set-config'],[('POST','/set-config','{"scheduler":"minrtt"}')])

    def test_real_https_login_form_encoding(self):
        p=self.request('LOGIN','token','user+1','p&a ss')
        self.assertEqual(p.returncode,0,p.stderr)
        event=next(x for x in self.events if x[1]=='/token')
        from urllib.parse import parse_qs
        self.assertEqual(parse_qs(event[2]),{'username':['user+1'],'password':['p&a ss']})

    def test_real_https_permission_error_is_preserved(self):
        p=self.request('POST','denied')
        self.assertEqual(p.returncode,11,p.stderr)
        self.assertIn('primary writable',json.loads(p.stdout)['detail'])

    def test_lost_post_response_does_not_duplicate_server_operation(self):
        p=self.request('POST','uncertain')
        self.assertEqual(p.returncode,12,p.stderr)
        self.assertTrue(json.loads(p.stdout)['delivery_uncertain'])
        self.assertEqual(len([x for x in self.events if x[1]=='/uncertain']),1)

if __name__=='__main__':unittest.main(verbosity=2)
