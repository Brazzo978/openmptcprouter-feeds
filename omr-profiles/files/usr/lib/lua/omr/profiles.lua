-- 3K profiles: transaction logic. All storage, UCI and network operations are
-- provided by an adapter, so failure/recovery behavior can be tested offline.
local M = {}

local fields = {
  tcp_scheduler = {"network", "globals", "mptcp_scheduler", "default"},
  tcp_cc = {"network", "globals", "congestion", "bbr"},
  tcp_nanbbr_aggressiveness = {"network", "globals", "nanbbr_aggressiveness", "50"},
  mq_scheduler = {"mqvpn", "multipath", "scheduler", "wlb"},
  mq_cc = {"mqvpn", "multipath", "cc", "bbr2"},
  fec_enable = {"mqvpn", "multipath", "fec_enable", "0"},
  fec_scheme = {"mqvpn", "multipath", "fec_scheme", "reed_solomon"},
  reinjection_control = {"mqvpn", "multipath", "reinjection_control", "0"},
  reinjection_mode = {"mqvpn", "multipath", "reinjection_mode", "default"},
  reorder_enabled = {"mqvpn", "reorder", "enabled", "0"},
  reorder_max_wait_ms = {"mqvpn", "reorder", "max_wait_ms", "30"},
  reorder_cap_packets = {"mqvpn", "reorder", "cap_packets", "1024"}
}
M.fields = fields

local builtins = {
  {id="default", name="Default", builtin=true, settings={
    tcp_scheduler="default", tcp_cc="bbr", tcp_nanbbr_aggressiveness="50",
    mq_scheduler="minrtt", mq_cc="bbr2", fec_enable="0", fec_scheme="reed_solomon",
    reinjection_control="0", reinjection_mode="default", reorder_enabled="1",
    reorder_max_wait_ms="30", reorder_cap_packets="1024"}},
  {id="performance", name="Performance", builtin=true, settings={
    tcp_scheduler="default", tcp_cc="nanbbr3_light", mq_scheduler="wlb", mq_cc="bbr2"}},
  {id="gaming", name="Gaming", builtin=true, settings={
    tcp_scheduler="bpf_red", tcp_cc="bbr", mq_scheduler="minrtt", mq_cc="bbr2"}}
}
local lookup = {}
for _, p in ipairs(builtins) do lookup[p.id] = p end

local mq_schedulers = {wlb=true,wlb_udp_pin=true,minrtt=true,wrtt=true,wrr=true,
  backup=true,backup_fec=true,rap=true,redundant=true}
local mq_ccs = {bbr2=true,bbr=true,cubic=true,new_reno=true,copa=true,unlimited=true,none=true}
local fec_schemes = {galois_calculation=true,packet_mask=true,reed_solomon=true,xor=true}
local reinjection_modes = {default=true,deadline=true,dgram=true}

local function shallow_copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

local function contains(t, item)
  if type(t) ~= 'table' then return false end
  for _, v in ipairs(t) do if v == item then return true end end
  return false
end

local function integer(v, lo, hi)
  if type(v) ~= 'string' or not v:match('^%d+$') then return false end
  local n = tonumber(v)
  return n ~= nil and n >= lo and n <= hi
end

local function safe_name(v)
  return type(v) == 'string' and #v > 0 and #v <= 48 and
         not v:find('[%z\1-\31\127]') and v:match('%S') ~= nil
end

local function valid_id(v)
  return type(v) == 'string' and (lookup[v] ~= nil or
         (#v == 34 and v:match('^p_[a-f0-9]+$') ~= nil))
end

local function valid_tx(v)
  return type(v) == 'string' and #v == 32 and v:match('^[a-f0-9]+$') ~= nil
end

local function allowed_values(s, complete)
  if type(s) ~= 'table' then return false end
  local count = 0
  for k, v in pairs(s) do
    if not fields[k] or type(v) ~= 'string' then return false end
    count = count + 1
  end
  if complete then for key in pairs(fields) do if s[key] == nil then return false end end end
  if count == 0 then return false end
  if s.tcp_scheduler and (not s.tcp_scheduler:match('^[a-zA-Z0-9_]+$') or #s.tcp_scheduler > 32) then return false end
  if s.tcp_cc and (not s.tcp_cc:match('^[a-zA-Z0-9_]+$') or #s.tcp_cc > 32) then return false end
  if s.tcp_nanbbr_aggressiveness and not integer(s.tcp_nanbbr_aggressiveness, 1, 100) then return false end
  if s.mq_scheduler and not mq_schedulers[s.mq_scheduler] then return false end
  if s.mq_cc and not mq_ccs[s.mq_cc] then return false end
  if s.fec_enable and s.fec_enable ~= '0' and s.fec_enable ~= '1' then return false end
  if s.fec_scheme and not fec_schemes[s.fec_scheme] then return false end
  if s.reinjection_control and s.reinjection_control ~= '0' and s.reinjection_control ~= '1' then return false end
  if s.reinjection_mode and not reinjection_modes[s.reinjection_mode] then return false end
  if s.reorder_enabled and s.reorder_enabled ~= '0' and s.reorder_enabled ~= '1' then return false end
  if s.reorder_max_wait_ms and not integer(s.reorder_max_wait_ms, 0, 60000) then return false end
  if s.reorder_cap_packets and not integer(s.reorder_cap_packets, 1, 65536) then return false end
  return true
end
M.allowed_values = allowed_values

local function bool01(value)
  if value==true or value==1 or value=='1' then return '1' end
  if value==false or value==0 or value=='0' then return '0' end
end

-- Build support and runtime FEC state are distinct facts.
function M.metrics_ready(metrics,expected)
  if type(metrics)~='table' or not metrics.reachable or type(metrics.build_info)~='table' or
     type(metrics.stats)~='table' or metrics.build_info.scheduler~=expected.mq_scheduler or
     tonumber(metrics.stats.n_clients)~=1 or type(metrics.status)~='table' or
     type(metrics.status.clients)~='table' or #metrics.status.clients~=1 then return false end
  local built=bool01(metrics.build_info.fec_enabled)
  if built=='0' then return expected.fec_enable=='0' end
  if built~='1' or type(metrics.fec)~='table' or type(metrics.fec.clients)~='table' or
     #metrics.fec.clients~=1 then return false end
  return bool01(metrics.fec.clients[1].enable_fec)==expected.fec_enable
end

local function effective(raw)
  local result = {}
  for key, spec in pairs(fields) do
    local value = raw[key]
    result[key] = (type(value) == 'string' and value ~= '') and value or spec[4]
  end
  return result
end
M.effective = effective

local function target_from(current, changes)
  local result = shallow_copy(current)
  for k, v in pairs(changes) do result[k] = v end
  return result
end

local function matches(actual, expected)
  if type(actual) ~= 'table' then return false end
  for k, v in pairs(expected or {}) do if tostring(actual[k]) ~= tostring(v) then return false end end
  return true
end

local function to_remote(settings)
  local p = {mptcp={}, mqvpn={}}
  if settings.tcp_scheduler then p.mptcp.scheduler = settings.tcp_scheduler end
  if settings.tcp_cc then p.mptcp.congestion_control = settings.tcp_cc end
  if settings.tcp_nanbbr_aggressiveness then
    p.mptcp.nanbbr_aggressiveness = tonumber(settings.tcp_nanbbr_aggressiveness)
  end
  if settings.mq_scheduler then p.mqvpn.scheduler = settings.mq_scheduler end
  if settings.mq_cc then p.mqvpn.cc = settings.mq_cc end
  if settings.fec_enable then p.mqvpn.fec_enable = settings.fec_enable == '1' end
  if settings.fec_scheme then p.mqvpn.fec_scheme = settings.fec_scheme end
  if settings.reinjection_control then p.mqvpn.reinjection_control = settings.reinjection_control == '1' end
  if settings.reinjection_mode then p.mqvpn.reinjection_mode = settings.reinjection_mode end
  if settings.reorder_enabled or settings.reorder_max_wait_ms or settings.reorder_cap_packets then
    p.mqvpn.reorder = {}
    if settings.reorder_enabled then p.mqvpn.reorder.enabled = settings.reorder_enabled == '1' and 'on' or 'off' end
    if settings.reorder_max_wait_ms then p.mqvpn.reorder.max_wait_ms = tonumber(settings.reorder_max_wait_ms) end
    if settings.reorder_cap_packets then p.mqvpn.reorder.cap_packets = tonumber(settings.reorder_cap_packets) end
  end
  return p
end
M.to_remote = to_remote

-- Only these scalar tuning settings may be persisted. In particular, reject
-- rather than save a full /config response containing addresses or credentials.
local function sanitize_remote(current)
  if type(current)~='table' or type(current.mptcp)~='table' or type(current.mqvpn)~='table' then return nil end
  local m,q=current.mptcp,current.mqvpn
  if type(m.scheduler)~='string' or type(m.congestion_control)~='string' or
     type(q.scheduler)~='string' or type(q.cc)~='string' or type(q.fec_enable)~='boolean' or
     type(q.fec_scheme)~='string' or type(q.reinjection_control)~='boolean' or
     type(q.reinjection_mode)~='string' or type(q.reorder)~='table' then return nil end
  local r=q.reorder
  if (r.enabled~='on' and r.enabled~='off' and r.enabled~='auto') or
     type(r.max_wait_ms)~='number' or type(r.cap_packets)~='number' then return nil end
  local flat={tcp_scheduler=m.scheduler,tcp_cc=m.congestion_control,mq_scheduler=q.scheduler,mq_cc=q.cc,
    fec_enable=q.fec_enable and '1' or '0',fec_scheme=q.fec_scheme,
    reinjection_control=q.reinjection_control and '1' or '0',reinjection_mode=q.reinjection_mode,
    reorder_enabled=r.enabled=='off' and '0' or '1',
    reorder_max_wait_ms=tostring(r.max_wait_ms),reorder_cap_packets=tostring(r.cap_packets)}
  if m.nanbbr_aggressiveness~=nil then flat.tcp_nanbbr_aggressiveness=tostring(m.nanbbr_aggressiveness) end
  if not allowed_values(flat, false) then return nil end
  local clean=to_remote(flat)
  clean.mqvpn.reorder.enabled=r.enabled -- preserve server-only "auto"
  return clean
end
M.sanitize_remote = sanitize_remote

local function remote_for_profile(p)
  if not p.builtin then return sanitize_remote(p.remote_settings) end
  local settings=to_remote(p.settings)
  if p.id=='default' then
    -- The 3K client UCI enables reorder and defaults to reed_solomon; the
    -- published VPS template leaves reorder off and its API reports xor for
    -- an absent FEC scheme. FEC itself is disabled on both sides.
    settings.mqvpn.fec_scheme='xor'
    settings.mqvpn.reorder.enabled='off'
  end
  return settings
end

local function remote_matches(current, desired)
  if type(current) ~= 'table' then return false end
  local function deep(actual, wanted)
    if type(actual) ~= 'table' or type(wanted) ~= 'table' then return false end
    for k, v in pairs(wanted) do
      if type(v) == 'table' then
        if not deep(actual[k], v) then return false end
      elseif tostring(actual[k]) ~= tostring(v) then return false end
    end
    return true
  end
  return deep(current, desired)
end

local function remote_available(cap, settings)
  if type(cap) ~= 'table' or cap.supported ~= true or tonumber(cap.version) ~= 1 or
     type(cap.current) ~= 'table' or type(cap.availability) ~= 'table' then
    return false, 'VPS profile API unavailable; update the VPS before switching profiles.'
  end
  local a = cap.availability
  for _, pair in ipairs({{'tcp_scheduler','tcp_schedulers'},{'tcp_cc','tcp_cc'},
      {'mq_scheduler','mq_schedulers'},{'mq_cc','mq_cc'},{'fec_scheme','fec_schemes'}}) do
    if settings[pair[1]] and not (pair[1]=='fec_scheme' and settings.fec_enable=='0') and
       not contains(a[pair[2]], settings[pair[1]]) then
      return false, 'A selected algorithm is unavailable on the VPS: ' .. settings[pair[1]]
    end
  end
  return true
end

local function remote_flat(settings)
  if type(settings)~='table' or type(settings.mptcp)~='table' or type(settings.mqvpn)~='table' then return {} end
  return {tcp_scheduler=settings.mptcp.scheduler,tcp_cc=settings.mptcp.congestion_control,
    mq_scheduler=settings.mqvpn.scheduler,mq_cc=settings.mqvpn.cc,fec_scheme=settings.mqvpn.fec_scheme,
    fec_enable=settings.mqvpn.fec_enable==nil and nil or (settings.mqvpn.fec_enable and '1' or '0')}
end

local function remote_display(settings)
  if type(settings)~='table' or type(settings.mptcp)~='table' or type(settings.mqvpn)~='table' then return nil end
  local m,q=settings.mptcp,settings.mqvpn
  local r=q.reorder or {}
  local out={tcp_scheduler=m.scheduler,tcp_cc=m.congestion_control,mq_scheduler=q.scheduler,mq_cc=q.cc,
    fec_scheme=q.fec_scheme,reinjection_mode=q.reinjection_mode,
    reorder_max_wait_ms=r.max_wait_ms and tostring(r.max_wait_ms),
    reorder_cap_packets=r.cap_packets and tostring(r.cap_packets)}
  if m.nanbbr_aggressiveness~=nil then out.tcp_nanbbr_aggressiveness=tostring(m.nanbbr_aggressiveness) end
  if q.fec_enable~=nil then out.fec_enable=q.fec_enable and '1' or '0' end
  if q.reinjection_control~=nil then out.reinjection_control=q.reinjection_control and '1' or '0' end
  if r.enabled then out.reorder_enabled=r.enabled=='on' and '1' or r.enabled=='off' and '0' or r.enabled end
  return out
end

local Model = {}
Model.__index = Model
function M.new(adapter) return setmetatable({a=adapter}, Model) end

function Model:profiles()
  local result = {}
  for _, p in ipairs(builtins) do result[#result+1] = {id=p.id,name=p.name,builtin=true,settings=shallow_copy(p.settings)} end
  for _, p in ipairs(self.a:custom_list() or {}) do
    if valid_id(p.id) and p.id:match('^p_') and safe_name(p.name) and allowed_values(p.settings, true)
       and sanitize_remote(p.remote_settings) then
      result[#result+1] = {id=p.id,name=p.name,builtin=false,settings=shallow_copy(p.settings),
        remote_settings=sanitize_remote(p.remote_settings)}
    end
  end
  return result
end

function Model:find_profile(id)
  if not valid_id(id) then return nil end
  for _, p in ipairs(self:profiles()) do if p.id == id then return p end end
end

function Model:status()
  local a = self.a
  local raw = a:read_raw()
  if not raw then return {ok=false,error='Unable to read the current router settings.'} end
  local current = a:current_effective(raw)
  if not current then return {ok=false,error='Unable to read active router tuning.'} end
  local active_id = a:get_active() or 'default'
  local active = self:find_profile(active_id) or self:find_profile('default')
  local cap, cap_reason, cap_age = a:cached_capabilities()
  local local_ok, local_reason = a:local_ready()
  local list = self:profiles()
  for _, p in ipairs(list) do
    local reasons = {}
    if not local_ok then reasons[#reasons+1] = local_reason end
    local have_local, why_local = a:local_available(p.settings)
    if not have_local then reasons[#reasons+1] = why_local end
    local have_remote, why_remote = remote_available(cap, remote_flat(remote_for_profile(p)))
    if not have_remote then reasons[#reasons+1] = cap_reason or why_remote end
    p.available = #reasons == 0
    p.unavailable_reasons = reasons
    p.remote_settings = remote_display(remote_for_profile(p))
  end
  local pending, journal_err = a:read_journal()
  local public = nil
  if pending then
    public = {transaction=pending.transaction,id=pending.id,name=pending.name,
      phase=pending.phase,error=pending.error,deadline=pending.deadline_wall,
      seconds_remaining=(pending.deadline_mono and pending.boot_id == a:boot_id()) and
        math.max(0, math.floor(pending.deadline_mono-a:monotonic())) or 0}
  elseif journal_err then
    public = {phase='rollback_failed',error='The recovery journal is unreadable. Restore the configuration before changing profiles.',seconds_remaining=0}
  end
  local remote_match = nil
  if cap then remote_match = remote_matches(cap.current,remote_for_profile(active)) end
  return {ok=true,active={id=active.id,name=active.name,
      modified=not matches(current,active.settings) or remote_match==false,server_match=remote_match},
    presets=list,current=current,remote_current=cap and remote_display(cap.current),pending=public,last_result=a:read_last(),capabilities={
      local_ready=local_ok, vps_ready=type(cap)=='table' and cap.supported==true and tonumber(cap.version)==1,
      age_seconds=cap_age}}
end

function Model:save(name)
  if not safe_name(name) then return {ok=false,error='Name must contain 1–48 printable characters.'} end
  return self.a:locked(function()
    local pending, err = self.a:read_journal()
    if pending or err then return {ok=false,error='Finish the pending profile change first.'} end
    local raw = self.a:read_raw()
    if not raw then return {ok=false,error='Unable to read the current router settings.'} end
    local settings = self.a:current_effective(raw)
    if not settings then return {ok=false,error='Unable to read active router tuning.'} end
    if not allowed_values(settings, true) then return {ok=false,error='The current settings cannot be saved safely.'} end
    local ready, why = self.a:local_ready()
    if not ready then return {ok=false,error=why} end
    local server=self.a:selected_server()
    if not server then return {ok=false,error='A single active VPS is required.'} end
    -- Save means an actual fresh read, not a potentially stale GUI cache. The
    -- bounded read runs under the short transaction lock so no profile apply
    -- can race this snapshot. Abort if the router values changed meanwhile.
    local cap = self.a:remote(server,'capabilities','00000000000000000000000000000000',nil,8)
    local remote = cap and sanitize_remote(cap.current)
    if not cap or cap.supported~=true or tonumber(cap.version)~=1 or not remote then
      return {ok=false,error='Unable to read current VPS settings. Try again when the VPS is reachable.'}
    end
    local after=self.a:read_raw()
    if not after then return {ok=false,error='Unable to read the current router settings.'} end
    for key in pairs(fields) do
      if raw[key]~=after[key] then return {ok=false,error='Router settings changed while saving; try again.'} end
    end
    local profiles = self.a:custom_list() or {}
    if #profiles >= 32 then return {ok=false,error='The custom profile limit is 32.'} end
    for _, p in ipairs(self:profiles()) do if p.name:lower() == name:lower() then return {ok=false,error='A profile with this name already exists.'} end end
    local id = 'p_' .. (self.a:random_id() or '')
    if not valid_id(id) then return {ok=false,error='Unable to create a profile identifier.'} end
    if not self.a:save_custom(id, name, settings, remote) then return {ok=false,error='Unable to save the profile.'} end
    return {ok=true,id=id}
  end)
end

function Model:delete(id)
  if not valid_id(id) or lookup[id] then return {ok=false,error='Built-in profiles cannot be deleted.'} end
  return self.a:locked(function()
    local pending, err = self.a:read_journal()
    if pending or err then return {ok=false,error='Finish the pending profile change first.'} end
    if not self:find_profile(id) then return {ok=false,error='Profile not found.'} end
    if not self.a:delete_custom(id) then return {ok=false,error='Unable to delete the profile.'} end
    if self.a:get_active() == id then self.a:set_active('default') end
    return {ok=true}
  end)
end

function Model:apply(id)
  return self.a:locked(function()
    local pending, err = self.a:read_journal()
    if pending or err then return {ok=false,error='Another profile change requires attention.'} end
    local profile = self:find_profile(id)
    if not profile then return {ok=false,error='Profile not found.'} end
    local ready, why = self.a:local_ready()
    if not ready then return {ok=false,error=why} end
    local local_ok, local_why = self.a:local_available(profile.settings)
    if not local_ok then return {ok=false,error=local_why} end
    local cap, cap_reason = self.a:cached_capabilities()
    local remote_target=remote_for_profile(profile)
    if not remote_target then return {ok=false,error='The saved VPS settings are invalid.'} end
    local remote_ok, remote_why = remote_available(cap, remote_flat(remote_target))
    if not remote_ok then return {ok=false,error=cap_reason or remote_why} end
    local server = self.a:selected_server()
    if not server then return {ok=false,error='A single active VPS is required.'} end
    local raw = self.a:read_raw()
    if not raw then return {ok=false,error='Unable to read the current router settings.'} end
    local before_effective=self.a:current_effective(raw)
    if not before_effective then return {ok=false,error='Unable to read active router tuning.'} end
    local target = target_from(before_effective, profile.settings)
    if not allowed_values(target, true) then return {ok=false,error='Profile settings are invalid.'} end
    local id128 = self.a:random_id()
    if not valid_tx(id128) then return {ok=false,error='Unable to create a transaction.'} end
    local j = {transaction=id128,id=profile.id,name=profile.name,server=server,phase='queued',
      boot_id=self.a:boot_id(),created_mono=self.a:monotonic(),before=raw,before_effective=before_effective,changes=profile.settings,
      target=target,remote_target=remote_target,remote_started=false,local_started=false}
    if not self.a:write_journal(j) then return {ok=false,error='Unable to start profile transaction.'} end
    self.a:heartbeat()
    return {ok=true,transaction=id128}
  end)
end

function Model:confirm(transaction)
  if not valid_tx(transaction) then return {ok=false,error='Invalid transaction.'} end
  return self.a:locked(function()
    local j = self.a:read_journal()
    if not j or j.transaction ~= transaction then return {ok=false,error='Transaction not found.'} end
    if j.phase ~= 'awaiting_confirm' then return {ok=false,error='Profile is not ready for confirmation.'} end
    if j.boot_id ~= self.a:boot_id() or self.a:monotonic() >= j.deadline_mono then
      j.phase='rolling_back'; j.error='Confirmation time expired.'; self.a:write_journal(j)
      return {ok=false,error='Confirmation time expired; reverting.'}
    end
    j.phase='confirming'; j.error=nil
    if not self.a:write_journal(j) then return {ok=false,error='Unable to confirm profile.'} end
    return {ok=true,transaction=transaction}
  end)
end

function Model:rollback(transaction)
  if not valid_tx(transaction) then return {ok=false,error='Invalid transaction.'} end
  return self.a:locked(function()
    local j = self.a:read_journal()
    if not j or j.transaction ~= transaction then return {ok=false,error='Transaction not found.'} end
    if j.phase ~= 'awaiting_confirm' and j.phase ~= 'rollback_failed' then
      return {ok=false,error='Profile change is still in progress.'}
    end
    j.phase='rolling_back'; j.error=nil
    if not self.a:write_journal(j) then return {ok=false,error='Unable to start rollback.'} end
    return {ok=true,transaction=transaction}
  end)
end

local function fail_before_change(a, j, message)
  a:locked(function()
    a:write_last({ok=false,message=message,profile_id=j.id})
    a:clear_journal()
  end)
end

function Model:run_apply(j)
  local a = self.a
  local marked = a:locked(function()
    local cur = a:read_journal()
    if not cur or cur.transaction ~= j.transaction or cur.phase ~= 'queued' then return false end
    cur.phase='applying'; cur.step='checking'; return a:write_journal(cur)
  end)
  if not marked then return end
  local cap = a:remote(j.server, 'capabilities', j.transaction)
  local available, why = remote_available(cap, remote_flat(j.remote_target))
  if not available then fail_before_change(a,j,why); return end
  local local_ok = a:local_available(j.changes)
  if not local_ok then fail_before_change(a,j,'A selected local algorithm is unavailable.'); return end
  local remote_target = j.remote_target
  local marked_remote = a:locked(function()
    local cur = a:read_journal()
    if not cur or cur.transaction ~= j.transaction or cur.phase ~= 'applying' then return false end
    cur.remote_started=true; cur.step='remote_apply'
    return a:write_journal(cur)
  end)
  if not marked_remote then return end
  local reply = a:remote(j.server, 'apply', j.transaction, remote_target)
  if not reply or reply.result ~= 'done' then
    -- The request may have arrived even if its response did not. The server
    -- journal and transaction ID resolve this; never assume no change.
    a:locked(function()
      local cur=a:read_journal()
      if cur and cur.transaction==j.transaction then
        cur.phase='rolling_back'; cur.error='VPS apply was not confirmed; reverting.'; a:write_journal(cur)
      end
    end)
    return
  end
  local marked_local = a:locked(function()
    local cur = a:read_journal()
    if not cur or cur.transaction ~= j.transaction or cur.phase ~= 'applying' then return false end
    cur.local_started=true; cur.step='local_apply'; return a:write_journal(cur)
  end)
  if not marked_local then return end
  local ok = a:write_effective(j.changes) and a:restart_and_verify(j.target)
  if ok then
    local verify = a:remote(j.server, 'capabilities', j.transaction)
    ok = verify and remote_matches(verify.current, remote_target)
  end
  local server_status = ok and a:remote(j.server,'status',j.transaction) or nil
  ok = ok and server_status and server_status.result=='done' and server_status.state=='pending' and
       type(server_status.seconds_remaining)=='number' and server_status.seconds_remaining>=70
  a:locked(function()
    local cur=a:read_journal()
    if not cur or cur.transaction~=j.transaction or cur.phase~='applying' then return end
    if ok then
      cur.phase='awaiting_confirm'; cur.step=nil; cur.deadline_mono=a:monotonic()+60
      cur.deadline_wall=a:wall_time()+60; cur.error=nil
    else
      cur.phase='rolling_back'; cur.error='Profile verification failed; reverting.'
    end
    a:write_journal(cur)
  end)
end

function Model:run_rollback(j)
  local a=self.a
  -- Restore local configuration first, then remote settings, then restart the
  -- local tunnel. Verifying the old local tunnel against the still-new VPS
  -- settings would otherwise cause a spurious rollback failure.
  local local_restored = not j.local_started or a:restore_raw(j.before)
  local remote_ok = not j.remote_started
  if j.remote_started then
    local reply=a:remote(j.server,'rollback',j.transaction)
    local status=a:remote(j.server,'status',j.transaction)
    remote_ok = (status and status.result=='done' and status.state=='rolled_back') or
                (reply and reply.result=='done' and reply.state=='rolled_back')
  end
  local local_ok = local_restored and (not j.local_started or a:restart_and_verify(j.before_effective,j.before))
  a:locked(function()
    local cur=a:read_journal()
    if not cur or cur.transaction~=j.transaction or cur.phase~='rolling_back' then return end
    if local_ok and remote_ok then
      a:write_last({ok=false,message='Profile reverted.',profile_id=j.id})
      a:clear_journal()
    else
      cur.phase='rollback_failed'; cur.error='Rollback is not fully verified. Retry when the VPS is reachable.'
      cur.guard_release_mono=cur.guard_release_mono or (a:monotonic()+300)
      a:write_journal(cur)
    end
  end)
end

function Model:run_confirm(j)
  local a=self.a
  local response=a:remote(j.server,'confirm',j.transaction)
  local status=a:remote(j.server,'status',j.transaction)
  local state=status and status.result=='done' and status.state or nil
  if not state and response and response.result=='done' then state=response.state end
  a:locked(function()
    local cur=a:read_journal()
    if not cur or cur.transaction~=j.transaction or cur.phase~='confirming' then return end
    if state=='confirmed' then
      if a:set_active(cur.id) then
        a:write_last({ok=true,message='Profile applied.',profile_id=cur.id}); a:clear_journal()
      else
        cur.error='VPS confirmed; waiting to save the local active profile.'; a:write_journal(cur)
      end
    elseif state=='rolled_back' then
      cur.phase='rolling_back'; cur.error='The VPS reverted the profile; restoring local settings.'; a:write_journal(cur)
    elseif state=='rollback_failed' then
      cur.phase='rollback_failed'; cur.error='The VPS could not complete rollback.'; a:write_journal(cur)
    else
      -- Confirm may have succeeded with a lost reply; do not restore local
      -- settings until the authoritative server transaction state is known.
      cur.error='Waiting to verify the VPS confirmation.'
      cur.guard_release_mono=cur.guard_release_mono or (a:monotonic()+300)
      a:write_journal(cur)
    end
  end)
end

function Model:recover()
  local a=self.a
  a:locked(function()
    local j=a:read_journal()
    if not j then return end
    if j.phase=='confirming' then return end -- reconcile durable VPS decision
    if j.phase=='queued' or j.phase=='applying' or j.phase=='awaiting_confirm' then
      j.phase='rolling_back'; j.error='Recovering an interrupted profile change.'; a:write_journal(j)
    end
  end)
end

function Model:tick()
  local a=self.a
  a:heartbeat()
  local j=a:read_journal()
  if not j then return end
  if j.phase=='queued' then self:run_apply(j)
  elseif j.phase=='rolling_back' then self:run_rollback(j)
  elseif j.phase=='confirming' then self:run_confirm(j)
  elseif j.phase=='awaiting_confirm' and (j.boot_id~=a:boot_id() or a:monotonic()>=j.deadline_mono) then
    a:locked(function()
      local cur=a:read_journal()
      if cur and cur.transaction==j.transaction and cur.phase=='awaiting_confirm' and
         (cur.boot_id~=a:boot_id() or a:monotonic()>=cur.deadline_mono) then
        cur.phase='rolling_back'; cur.error='Confirmation time expired.'; a:write_journal(cur)
      end
    end)
  end
end

return M
