"""Execute the feed initializer in a disposable filesystem with a fake kernel."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'files/etc/uci-defaults/2093-opkg'

class ApkRepositories(unittest.TestCase):
    def test_branding_keeps_the_upstream_package_channel(self):
        for version in ['v0.64.2-3K', 'v0.64.2-3k-r0-abcdef',
                        'v0.64.3-3K', 'v0.64.3-3k-r0-abcdef', 'v0.64.2']:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                etc = root/'etc'; repos = etc/'apk/repositories.d'
                repos.mkdir(parents=True)
                (etc/'os-release').write_text('ID=openmptcprouter\nVERSION_ID='+version+'\nOPENWRT_ARCH=x86_64\n')
                (repos/'distfeeds.list').write_text('obsolete repository\n')
                tools = root/'bin'; tools.mkdir()
                uname = tools/'uname'; uname.write_text('#!/bin/sh\nprintf "%s\\n" 6.18.39\n'); uname.chmod(0o755)
                script = root/'initialize.sh'
                script.write_text(SCRIPT.read_text().replace('/etc/',str(etc)+'/'))
                env = dict(os.environ, PATH=str(tools)+':'+os.environ['PATH'])
                subprocess.run(['bash',str(script)],env=env,check=True,capture_output=True,text=True)
                channel = 'v0.64.2-6.18' if '-3' in version else version
                expected = ['https://packages.openmptcprouter.com/'+channel+'/x86_64/'+name+'/packages.adb'
                            for name in ['luci','packages','base','routing','telephony']]
                self.assertEqual((repos/'customfeeds.list').read_text().splitlines(),expected)
                self.assertEqual((repos/'distfeeds.list').read_text(),'')

if __name__ == '__main__': unittest.main()
