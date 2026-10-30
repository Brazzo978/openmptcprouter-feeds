"""Exercise the actual libuci/nixio bindings against disposable files.

Provide PROFILE_LUA, PROFILE_NIXIO_CPATH, PROFILE_NIXIO_LUAPATH,
PROFILE_UCI_CPATH and PROFILE_JSON_CPATH; LD_LIBRARY_PATH must include libuci.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

package = Path(__file__).resolve().parents[1]
env = os.environ.copy()
env['LUA_PATH'] = str(package / 'files/usr/lib/lua/?.lua') + ';' + os.environ['PROFILE_NIXIO_LUAPATH'] + '/?.lua;;'
env['LUA_CPATH'] = ';'.join(os.environ[x] + '/?.so' for x in ('PROFILE_NIXIO_CPATH', 'PROFILE_UCI_CPATH', 'PROFILE_JSON_CPATH')) + ';;'
with tempfile.TemporaryDirectory(prefix='omr-profile-uci-') as d:
    root = Path(d)
    config, run = root / 'config', root / 'run'
    config.mkdir();run.mkdir()
    network = config / 'network'
    network.write_text("config globals 'globals'\n option mptcp_scheduler 'default'\n option congestion 'bbr'\n\nconfig interface 'wan'\n option proto 'dhcp'\n option ipaddr '192.0.2.10'\n")
    network.chmod(0o600)
    source = (package / 'files/usr/libexec/omr-profiles/uci-isolated').read_text().split('\n', 1)[1]
    source = source.replace("'/etc/config/'", "'" + str(config) + "/'")
    source = source.replace("'/etc/config/.omrprofile-'", "'" + str(config) + "/.omrprofile-'")
    source = source.replace("'/var/run/omr-profiles/", "'" + str(run) + "/")
    helper = root / 'helper.lua'
    helper.write_text("""package.preload['luci.jsonc']=function()
  local c=require 'cjson';return {parse=c.decode,stringify=c.encode}
end
""" + source)
    def invoke(mode):
        result = subprocess.run([os.environ['PROFILE_LUA'], str(helper), 'network', mode], env=env,
                                capture_output=True, text=True)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        return result
    before = json.loads(invoke('read').stdout)
    assert before['tcp_cc'] == 'bbr' and before['tcp_scheduler'] == 'default'
    (run / 'uci-request.json').write_text(json.dumps({'values': {'tcp_cc':'nanbbr3_light'}, 'raw':False}))
    invoke('write')
    text = network.read_text()
    assert 'nanbbr3_light' in text and '192.0.2.10' in text and 'dhcp' in text
    assert network.stat().st_mode & 0o777 == 0o600
    (run / 'uci-request.json').write_text(json.dumps({'values': {'tcp_cc':False}, 'raw':True}))
    invoke('write')
    assert json.loads(invoke('read').stdout)['tcp_cc'] is False
    assert '192.0.2.10' in network.read_text()
print('PASS: real libuci updates allowlisted field and preserves unrelated WAN configuration and mode')
