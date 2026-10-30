"""Run with PROFILE_LUA, PROFILE_NIXIO_CPATH and PROFILE_NIXIO_LUAPATH.

Uses real nixio and distinct processes; no firmware path or network is touched.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

package = Path(__file__).resolve().parents[1]
lua = os.environ['PROFILE_LUA']
env = os.environ.copy()
env['LUA_PATH'] = str(package / 'files/usr/lib/lua/?.lua') + ';' + os.environ['PROFILE_NIXIO_LUAPATH'] + '/?.lua;;'
env['LUA_CPATH'] = os.environ['PROFILE_NIXIO_CPATH'] + '/?.so;;'

with tempfile.TemporaryDirectory(prefix='omr-profile-lock-') as temp:
    temp = Path(temp)
    runtime = (package / 'files/usr/lib/lua/omr/profiles_runtime.lua').read_text()
    runtime = runtime.replace("local persist='/etc/omr-profiles'", "local persist='" + str(temp / 'persist') + "'")
    runtime = runtime.replace("local runtime='/var/run/omr-profiles'", "local runtime='" + str(temp / 'run') + "'")
    (temp / 'runtime.lua').write_text(runtime)
    script = temp / 'lock.lua'
    script.write_text("""
package.preload['luci.jsonc']=function() return {} end
package.preload['luci.sys']=function() return {} end
package.preload['luci.model.uci']=function() return {} end
local nixio=require 'nixio'
local R=dofile(arg[1]);local r=R.new()
local got=r:locked(function()
  print('ACQUIRED');io.stdout:flush()
  if arg[2]=='hold' then nixio.nanosleep(120) end
  return true
end)
if not got then print('BUSY') end
""")
    cmd = [lua, str(script), str(temp / 'runtime.lua')]
    holder = subprocess.Popen(cmd + ['hold'], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        line = holder.stdout.readline().strip()
        assert line == 'ACQUIRED', (line, holder.stderr.read())
        lock = temp / 'run/state.lock'
        os.utime(lock, (time.time() - 3600, time.time() - 3600))
        contender = subprocess.run(cmd + ['try'], env=env, text=True, capture_output=True, check=True)
        assert contender.stdout.strip() == 'BUSY', contender.stderr
        holder.kill()
        holder.wait(timeout=5)
        recovered = subprocess.run(cmd + ['try'], env=env, text=True, capture_output=True, check=True)
        assert recovered.stdout.strip() == 'ACQUIRED', recovered.stderr
    finally:
        if holder.poll() is None:
            holder.kill()
            holder.wait(timeout=5)
print('PASS: an old live lock cannot be stolen; a dead owner releases it')
