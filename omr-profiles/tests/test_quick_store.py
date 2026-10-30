"""Real nixio/Lua quick-pair persistence test on disposable files.

Use PROFILE_LUA, PROFILE_NIXIO_CPATH, PROFILE_NIXIO_LUAPATH and
PROFILE_JSON_CPATH; no device or firmware path is modified.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

package = Path(__file__).resolve().parents[1]
env = os.environ.copy()
env['LUA_PATH'] = str(package / 'files/usr/lib/lua/?.lua') + ';' + os.environ['PROFILE_NIXIO_LUAPATH'] + '/?.lua;;'
env['LUA_CPATH'] = os.environ['PROFILE_NIXIO_CPATH'] + '/?.so;' + os.environ['PROFILE_JSON_CPATH'] + '/?.so;;'
with tempfile.TemporaryDirectory(prefix='omr-profile-quick-') as directory:
    temp = Path(directory)
    persist = temp / 'persist'
    persist.mkdir()
    profile_id = 'p_' + 'a' * 32
    store = persist / 'profiles.json'
    store.write_text(json.dumps({'version': 1, 'active_id': profile_id,
                                 'profiles': [{'id': profile_id, 'name': 'Fixture'}]}))
    source = (package / 'files/usr/lib/lua/omr/profiles_runtime.lua').read_text()
    source = source.replace("local persist='/etc/omr-profiles'", "local persist='" + str(persist) + "'")
    source = source.replace("local runtime='/var/run/omr-profiles'", "local runtime='" + str(temp / 'run') + "'")
    module = temp / 'runtime.lua'
    module.write_text(source)
    script = temp / 'quick.lua'
    script.write_text("""
package.preload['luci.jsonc']=function()
  local c=require 'cjson';return {parse=c.decode,stringify=c.encode}
end
package.preload['luci.sys']=function() return {} end
package.preload['luci.model.uci']=function() return {} end
local R=dofile(arg[1]);local r=R.new()
assert(r:set_quick({a=arg[2],b='default'}))
local other=R.new();assert(other:get_quick().a==arg[2])
assert(other:delete_custom(arg[2],{a='gaming',b='default'}))
""")
    subprocess.run([env['PROFILE_LUA'], str(script), str(module), profile_id], env=env,
                   text=True, capture_output=True, check=True)
    result = json.loads(store.read_text())
    assert result['quick'] == {'a':'gaming', 'b':'default'}
    assert not result['profiles'] and result['active_id'] == 'default'
    assert store.stat().st_mode & 0o777 == 0o600
print('PASS: quick pair persists privately and custom deletion atomically updates the pair')
