/* Run with node. Executes the actual LuCI module with a minimal DOM and RPC.
 * There is no router, service, or browser connection in this fixture.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');

String.prototype.format = function() {
	let i = 0, values = arguments;
	return this.replace(/%s/g, () => String(values[i++]));
};
class Element {
	constructor(tag, attributes, children) {
		this.tagName = tag;
		this.attributes = attributes || {};
		this.listeners = {};
		this.childNodes = [];
		this.value = this.attributes.value || '';
		this.disabled = !!this.attributes.disabled;
		this.parentNode = null;
		if (typeof this.attributes.click === 'function') this.listeners.click = this.attributes.click;
		[].concat(children || []).forEach(child => this.appendChild(typeof child === 'string' ? new Text(child) : child));
	}
	get firstChild() { return this.childNodes[0] || null; }
	get textContent() { return this.childNodes.map(x => x.textContent).join(''); }
	set textContent(value) { this.childNodes = [new Text(String(value))]; }
	appendChild(child) {
		if (child == null || child === false) return;
		if (child.parentNode) child.parentNode.removeChild(child);
		child.parentNode = this; this.childNodes.push(child); return child;
	}
	removeChild(child) {
		const i = this.childNodes.indexOf(child);
		if (i >= 0) this.childNodes.splice(i, 1);
		child.parentNode = null;
		return child;
	}
	setAttribute(key, value) { this.attributes[key] = value; }
	addEventListener(event, listener) { this.listeners[event] = listener; }
	click() { if (!this.disabled && this.listeners.click) return this.listeners.click({target:this}); }
}
class Text { constructor(value) { this.value = value; this.parentNode = null; } get textContent() { return this.value; } }
/* LuCI's dom.append parses a scalar string as HTML but creates text nodes for
 * array children. Simulate that distinction to catch accidental injection. */
function E(tag, attrs, children) {
	if (typeof children === 'string' && /<\s*img\b/i.test(children))
		return new Element(tag, attrs, [new Element('img')]);
	return new Element(tag, attrs, children);
}
function nodes(root) { return [root].concat((root.childNodes || []).flatMap(nodes)); }
function find(root, tag, label) { return nodes(root).find(n => n.tagName === tag && n.textContent === label); }
function tick() { return new Promise(resolve => setImmediate(resolve)); }

function fixture(allowed) {
	const calls = [], polls = [];
	const state = {
		ok: true, active: {id:'default',name:'Default',modified:false,server_match:true},
		current: {tcp_scheduler:'default',tcp_cc:'bbr',mq_scheduler:'minrtt',mq_cc:'bbr2',
			fec_enable:'0',auth_key:'secret-must-not-render'},
		remote_current: {mq_scheduler:'wlb',reorder_enabled:'0'},
		presets: [
			{id:'default',name:'Default',builtin:true,available:true,settings:{tcp_cc:'bbr',transport:'mqvpn'}},
			{id:'performance',name:'Performance',builtin:true,available:true,settings:{tcp_cc:'nanbbr3_light',transport:'mqvpn'}},
			{id:'gaming',name:'Gaming',builtin:true,available:true,settings:{tcp_scheduler:'bpf_red',transport:'mqvpn'}},
			{id:'p_1234',name:'<img src=x onerror=alert(1)>',builtin:false,available:true,settings:{mq_cc:'bbr2'},remote_settings:{reorder_enabled:'0'}}
		], pending: null, last_result: null, capabilities:{age_seconds:4}, quick:{a:'default',b:'gaming'}
	};
	let failure = null, statusFailure = false, holdStatus = false, releaseStatus = null;
	const rpc = {declare: function(def) {
		return function() {
			const args = Array.from(arguments);
			calls.push({object:def.object,method:def.method,args:args});
			if (def.object === 'session') return Promise.resolve(!!allowed[args[2]]);
			if (def.method === 'status') {
				if (statusFailure) return Promise.reject(new Error('unreachable'));
				const snapshot = JSON.parse(JSON.stringify(state));
				if (holdStatus) {
					holdStatus = false;
					return new Promise(resolve => { releaseStatus = () => resolve(snapshot); });
				}
				return Promise.resolve(snapshot);
			}
			if (failure) return Promise.resolve({ok:false,error:failure});
			if (def.method === 'set_quick') { state.quick={a:args[0],b:args[1]}; return Promise.resolve({ok:true}); }
			if (def.method === 'apply') {
				state.pending = {transaction:'abc123',id:args[0],name:'Candidate',phase:'awaiting_confirm',seconds_remaining:60};
				return Promise.resolve({ok:true,transaction:'abc123'});
			}
			if (def.method === 'confirm') {
				state.active = {id:state.pending.id,name:'Candidate',modified:false};
				state.pending = null; state.last_result = {ok:true,message:'Profile confirmed.'};
			}
			if (def.method === 'rollback') {
				state.pending = null; state.last_result = {ok:true,message:'Previous profile restored.'};
			}
			if (def.method === 'delete') state.presets = state.presets.filter(p => p.id !== args[0]);
			if (def.method === 'save') state.presets.push({id:'p_5678',name:args[0],builtin:false,settings:state.current});
			return Promise.resolve({ok:true});
		};
	}};
	const document = {querySelector:()=>null,createElement:tag=>new Element(tag),head:new Element('head')};
	const window = {confirm:()=>true};
	const poll = {add:fn=>polls.push(fn)};
	const L = {resource:s=>'/luci-static/resources/'+s,url:s=>'/cgi-bin/luci/'+s};
	const code = fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/resources/omr/profiles.js'),'utf8');
	const mod = new Function('baseclass','rpc','poll','L','E','_','document','window',code)(
		{extend:x=>x},rpc,poll,L,E,s=>s,document,window);
	return {mod,state,calls,polls,setFailure:x=>{failure=x;},setStatusFailure:x=>{statusFailure=x;},
		holdNextStatus:()=>{holdStatus=true;},releaseStatus:()=>releaseStatus()};
}

async function ready() { await tick(); await tick(); }
async function refresh(f) { await Promise.all(f.polls.map(p=>p())); await ready(); }
async function tests() {
	{
		const f=fixture({apply:true});
		f.state.presets[1].settings.mq_scheduler='wlb';
		f.state.presets[1].available=false;
		f.state.presets[2].settings.mq_scheduler='minrtt';
		f.state.presets.push({id:'stability_old',name:'Stability old',builtin:true,available:true,settings:{transport:'glorytun_tcp',tcp_scheduler:'bpf_red'}});
		f.state.presets.push({id:'performance_old',name:'Performance old',builtin:true,available:true,settings:{transport:'glorytun_tcp',tcp_scheduler:'default'}});
		const root=f.mod.create({full:true});
		await ready();
		const preview=nodes(root).find(n=>n.attributes && n.attributes.class==='omr-preview');
		const profile=nodes(preview).find(n=>n.attributes && n.attributes['aria-label']==='Preview profile');
		const diagrams=nodes(preview).filter(n=>n.attributes && n.attributes['data-protocol']);
		const diagram=protocol=>diagrams.find(n=>n.attributes['data-protocol']===protocol);
		const set=(element,value)=>{ element.value=value; element.listeners.change({target:element}); };
		assert.strictEqual(profile.value,'default');
		assert.strictEqual(diagrams.length,3);
		assert(diagram('tcp').attributes.class.includes('is-automatic'));
		assert(preview.textContent.includes('this sequence is one illustration'));
		assert(preview.textContent.includes('WAN-bound diagnostic pings and bypass traffic are not shown'));
		set(profile,'gaming');
		assert(diagram('tcp').attributes.class.includes('is-duplicate'));
		assert(preview.textContent.includes('same packet'));
		assert(diagram('icmp').attributes.class.includes('is-minrtt'));
		assert(diagram('udp').attributes.class.includes('is-minrtt'));
		set(profile,'performance');
		set(profile,'p_1234');
		assert(diagrams.every(d=>d.attributes.class.includes('is-unknown')));
		assert(preview.textContent.includes('Transport is not recorded'));
		set(profile,'performance');
		assert(diagram('icmp').attributes.class.includes('is-balanced'));
		assert(diagram('udp').attributes.class.includes('is-balanced'));
		assert(preview.textContent.includes('equally weighted'));
		set(profile,'stability_old');
		assert(diagrams.every(d=>d.attributes.class.includes('is-duplicate')));
		assert(preview.textContent.includes('Glorytun TCP'));
		for (const d of diagrams) {
			const packets=nodes(d).filter(n=>n.attributes&&String(n.attributes.class||'').includes('packet-a'));
			assert.strictEqual(packets[0].textContent,packets[1].textContent);
		}
		set(profile,'performance_old');
		assert(diagrams.every(d=>d.attributes.class.includes('is-dense')));
		for (const d of diagrams) {
			const packets=nodes(d).filter(n=>n.attributes&&String(n.attributes.class||'').includes('packet-a'));
			assert.notStrictEqual(packets[0].textContent,packets[1].textContent);
		}
		set(profile,'performance');
		assert.strictEqual(f.calls.filter(c=>c.method==='apply').length,0, 'preview must not apply');
		const card=nodes(root).find(n=>n.attributes && n.attributes.class==='omr-profile-name' && n.textContent==='Performance').parentNode;
		assert(find(card,'button','Use profile').disabled, 'preview of an unavailable profile does not enable apply');
		find(preview,'button','Pause animation').click();
		assert(diagrams.every(d=>d.attributes.class.includes('is-paused')));
		f.state.active.id='gaming'; await refresh(f);
		assert.strictEqual(profile.value,'performance', 'poll preserves preview selection');
		assert.strictEqual(nodes(root).find(n=>n===preview),preview, 'poll does not rebuild the preview');
		find(preview,'button','Resume animation').click();
		assert(diagrams.every(d=>!d.attributes.class.includes('is-paused')));
		const css=fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/resources/omr/profiles.css'),'utf8');
		assert(css.includes('.is-automatic .packet-a') && css.includes('.is-automatic .wan2 .omr-preview-packet'));
		assert(css.includes('prefers-reduced-motion: reduce') && css.includes('animation: none'));
		assert(root.textContent.includes('temporarily interrupting the tunnel'));
	}
	{
		const f=fixture({apply:true,set_quick:true,confirm:true,rollback:true}), root=f.mod.create({full:false}); await ready();
		const toggle=()=>nodes(root).find(n=>n.tagName==='input' && n.attributes.role==='switch');
		assert(!toggle().attributes.checked && !toggle().disabled);
		assert(find(root,'button','A: Default').disabled);
		assert(!find(root,'button','B: Gaming').disabled);
		let a=nodes(root).find(n=>n.attributes&&n.attributes['aria-label']==='Quick profile A');
		a.value='performance'; a.listeners.change({target:a});
		f.holdNextStatus(); const oldPoll=f.polls[0]();
		const saving=find(root,'button','Save quick profiles').click(); await ready();
		f.releaseStatus(); await Promise.all([oldPoll,saving]); await ready();
		assert.deepStrictEqual(f.state.quick,{a:'performance',b:'gaming'});
		assert.strictEqual(nodes(root).find(n=>n.attributes&&n.attributes['aria-label']==='Quick profile A').value,'performance');
		assert.strictEqual(f.calls.filter(c=>c.method==='apply').length,0, 'saving quick pair does not apply');
		assert(root.textContent.includes('outside this pair'));
		assert(toggle().disabled, 'outside pair must not imply A');
		find(root,'button','A: Performance').click(); await ready();
		assert.strictEqual(f.calls.filter(c=>c.method==='apply').length,1);
		assert(root.textContent.includes('last confirmed profile remains unchanged'));
		assert(find(root,'button','A: Performance').disabled && find(root,'button','B: Gaming').disabled && toggle().disabled);
		assert.strictEqual(find(root,'button','A: Performance').attributes['aria-pressed'],'false', 'pending target is not shown as confirmed');
		await find(root,'button','Keep profile').click(); await ready();
		assert.strictEqual(find(root,'button','A: Performance').attributes['aria-pressed'],'true');
		assert(!toggle().disabled && !toggle().attributes.checked);
		toggle().listeners.change({target:toggle()}); await ready();
		assert(!toggle().attributes.checked && toggle().disabled, 'switch remains on confirmed A during pending B');
		await find(root,'button','Keep profile').click(); await ready();
		assert(toggle().attributes.checked, 'switch moves to B after confirmation');
	}
	{
		const f=fixture({}), root=f.mod.create({full:true}); await ready();
		assert(find(root,'button','Restore default').disabled);
		assert(find(root,'button','Use profile').disabled);
		assert(root.textContent.includes('view profiles but cannot apply'));
		assert(root.textContent.includes('<img src=x onerror=alert(1)>'));
		assert(root.textContent.includes('Current settings on VPS'));
		assert(root.textContent.includes('VPS settings'));
		assert(root.textContent.includes('VPS settings match this profile.'));
		assert(!root.textContent.includes('secret-must-not-render'));
		assert(!nodes(root).some(n => n.tagName === 'img'));
	}
	{
		const f=fixture({apply:true,save:true,delete:true,confirm:true,rollback:true});
		const root=f.mod.create({full:true}); await ready();
		assert(!find(root,'button','Restore default').disabled);
		const perfCard=nodes(root).find(n => n.attributes && n.attributes.class === 'omr-profile-name' && n.textContent === 'Performance').parentNode;
		await find(perfCard,'button','Use profile').click(); await ready();
		assert.strictEqual(f.calls.filter(c=>c.method==='apply').length,1);
		assert.strictEqual(f.calls.find(c=>c.method==='apply').args[0],'performance');
		assert(root.textContent.includes('Automatic restore in 60 seconds'));
		assert(find(root,'button','Use profile').disabled);
		await find(root,'button','Keep profile').click(); await ready();
		assert.strictEqual(f.calls.find(c=>c.method==='confirm').args[0],'abc123');
		assert(root.textContent.includes('Profile confirmed.'));
	}
	{
		const f=fixture({apply:true,rollback:true}), root=f.mod.create({full:false}); await ready();
		f.state.pending={transaction:'failed1',name:'<img src=x>',phase:'rollback_failed',error:'VPS unavailable <img src=x>'};
		await refresh(f);
		assert(root.textContent.includes('VPS unavailable'));
		assert(root.textContent.includes('<img src=x>'));
		assert(!nodes(root).some(n=>n.tagName==='img'));
		assert(!find(root,'button','Keep profile'));
		await find(root,'button','Retry restore').click(); await ready();
		assert.strictEqual(f.calls.find(c=>c.method==='rollback').args[0],'failed1');
	}
	{
		const f=fixture({apply:true,confirm:true,rollback:true}), root=f.mod.create({full:true}); await ready();
		f.holdNextStatus();
		const stalePoll=f.polls[0]();
		const card=nodes(root).find(n => n.attributes && n.attributes.class === 'omr-profile-name' && n.textContent === 'Performance').parentNode;
		const applying=find(card,'button','Use profile').click();
		await ready();
		assert(find(root,'button','Use profile').disabled, 'actions remain disabled while an old status request is outstanding');
		f.releaseStatus();
		await Promise.all([stalePoll,applying]); await ready();
		assert(find(root,'button','Keep profile'), 'a fresh post-apply status reveals the pending transaction');
	}
	{
		const f=fixture({apply:true}), root=f.mod.create({full:true}); await ready();
		f.state.current.mq_cc='<img src=x>';
		f.state.presets[1].available=false;
		f.state.presets[1].unavailable_reasons=['<img src=x>'];
		f.state.last_result={ok:false,message:'<img src=x>'};
		await refresh(f);
		assert(root.textContent.includes('<img src=x>'));
		assert(!nodes(root).some(n=>n.tagName==='img'));
		const unavailableCard=nodes(root).find(n=>n.attributes&&n.attributes.class==='omr-profile-name'&&n.textContent==='Performance').parentNode;
		assert(find(unavailableCard,'button','Use profile').disabled,'unavailable algorithm cannot be applied');
		f.setStatusFailure(true); await refresh(f);
		assert(root.textContent.includes('Unable to contact the profile service.'));
		f.setStatusFailure(false); await refresh(f);
		assert(!root.textContent.includes('Unable to contact the profile service.'));
	}
	{
		const f=fixture({apply:true}), root=f.mod.create({full:true}); await ready();
		f.state.active={id:'performance',name:'Performance',modified:false,server_match:false};
		await refresh(f);
		assert(root.textContent.includes('VPS settings differ from this profile.'));
		assert(root.textContent.includes('Last checked 4 seconds ago.'));
		const card=nodes(root).find(n=>n.attributes&&n.attributes.class==='omr-profile-name'&&n.textContent==='Performance').parentNode;
		assert(!find(card,'button','Use profile').disabled,'a divergent server can be resynchronized');
		delete f.state.active.server_match;
		await refresh(f);
		assert(root.textContent.includes('VPS settings have not been verified.'));
	}
	{
		const f=fixture({apply:true,save:true}), root=f.mod.create({full:true}); await ready();
		f.setFailure('VPS unavailable');
		const card=nodes(root).find(n => n.attributes && n.attributes.class === 'omr-profile-name' && n.textContent === 'Gaming').parentNode;
		await find(card,'button','Use profile').click(); await ready();
		assert(root.textContent.includes('VPS unavailable'));
		assert(!root.textContent.includes('Profile confirmed.'));
		f.setFailure(null);
		const input=nodes(root).find(n=>n.tagName==='input');
		input.value='  Home & night  ';
		await find(root,'button','Save current settings').click(); await ready();
		assert.strictEqual(f.calls.find(c=>c.method==='save').args[0],'Home & night');
		assert(root.textContent.includes('Profile saved.'));
	}
	console.log('Profile UI: read-only, escaping, apply/confirm, rollback failure, error and custom-save cases passed.');
}
tests().catch(err => { console.error(err.stack || err); process.exitCode=1; });
