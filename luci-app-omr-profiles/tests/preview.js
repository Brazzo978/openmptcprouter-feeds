/* Local UI preview with a simulated profile service. Never included in firmware.
 * Run: node luci-app-omr-profiles/tests/preview.js
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const base = path.join(__dirname, '..', 'htdocs', 'luci-static', 'resources');
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OMR profile preview — mock service</title><style>
body{font:15px system-ui,sans-serif;margin:0;color:#253047;background:#f4f6f9}
header{background:#243a56;color:white;padding:14px 24px}main{max-width:1100px;margin:auto;padding:20px}
.cbi-section{background:white;border:1px solid #dce2e9;border-radius:5px;padding:16px}
button,select,input{font:inherit;padding:7px 11px;border-radius:4px;border:1px solid #aab5c2}
button{cursor:pointer;background:#e6eef8}button:disabled{opacity:.48;cursor:default}
.cbi-button-positive{background:#e8f4e8}.cbi-button-negative{background:#f8e8e8}
.preview-banner{padding:8px;background:#fff3d2;font-weight:bold}a{color:#1260a1}
</style></head><body><header>OpenMPTCProuter</header><main>
<div class="preview-banner">Preview: simulated profile service. No router is connected.</div>
<div id="app"></div></main><script>
'use strict';
String.prototype.format=function(){let i=0,args=arguments;return this.replace(/%s/g,()=>String(args[i++]));};
const state={
 ok:true, active:{id:'default',name:'Default',modified:false,server_match:true}, pending:null,last_result:null,capabilities:{age_seconds:2},quick:{a:'default',b:'gaming'},
 current:{tcp_scheduler:'default',tcp_cc:'bbr',mq_scheduler:'minrtt',mq_cc:'bbr2',fec_enable:'0',fec_scheme:'xor',reinjection_control:'0',reorder_enabled:'1'},
 remote_current:{tcp_scheduler:'default',tcp_cc:'bbr',mq_scheduler:'minrtt',mq_cc:'bbr2',reorder_enabled:'0'},
 presets:[
  {id:'default',name:'Default',builtin:true,available:true,settings:{transport:'mqvpn',tcp_scheduler:'default',tcp_cc:'bbr',mq_scheduler:'minrtt',mq_cc:'bbr2',reorder_enabled:'1'},remote_settings:{tcp_scheduler:'default',tcp_cc:'bbr',mq_scheduler:'minrtt',mq_cc:'bbr2',reorder_enabled:'0'}},
  {id:'performance',name:'Performance',builtin:true,available:true,settings:{transport:'mqvpn',tcp_scheduler:'default',tcp_cc:'nanbbr3_light',mq_scheduler:'wlb',mq_cc:'bbr2'}},
  {id:'gaming',name:'Stability / Gaming',builtin:true,available:true,settings:{tcp_scheduler:'bpf_red',tcp_cc:'bbr',mq_scheduler:'minrtt',mq_cc:'bbr2',transport:'mqvpn'}},
  {id:'performance_old',name:'Performance (old)',builtin:true,available:true,settings:{tcp_scheduler:'default',tcp_cc:'bbr',transport:'glorytun_tcp',proxy:'none'}},
  {id:'stability_old',name:'Stability (old)',builtin:true,available:true,settings:{tcp_scheduler:'bpf_red',tcp_cc:'bbr',transport:'glorytun_tcp',proxy:'none'}},
  {id:'p_123',name:'Evening',builtin:false,available:true,settings:{tcp_scheduler:'default',tcp_cc:'bbr',mq_scheduler:'minrtt',mq_cc:'bbr2',fec_enable:'1'},remote_settings:{mq_scheduler:'minrtt',mq_cc:'bbr2',reorder_enabled:'0'}}
 ]
};
function E(tag,attrs,children){
 const n=document.createElement(tag);
 Object.entries(attrs||{}).forEach(([k,v])=>{if(k==='click')n.addEventListener('click',v);else n.setAttribute(k,v);});
 if(Array.isArray(children))children.forEach(c=>{if(c!=null&&c!==false)n.append(c instanceof Node?c:document.createTextNode(String(c)));});
 else if(children instanceof Node)n.append(children);
 else if(children!=null)n.innerHTML=String(children);
 return n;
}
const rpc={declare:d=>function(...args){
 if(d.object==='session')return Promise.resolve(true);
 if(d.method==='status')return Promise.resolve(JSON.parse(JSON.stringify(state)));
 if(d.method==='set_quick'){state.quick={a:args[0],b:args[1]};return Promise.resolve({ok:true});}
 if(d.method==='apply'){
  const p=state.presets.find(x=>x.id===args[0]);state.pending={transaction:'preview',id:p.id,name:p.name,phase:'awaiting_confirm',seconds_remaining:60};state.last_result=null;
 }
 if(d.method==='confirm'){const p=state.presets.find(x=>x.id===state.pending.id);state.active={id:p.id,name:p.name,modified:false,server_match:true};state.current={...state.current,...p.settings};state.remote_current={...state.remote_current,...p.settings,...p.remote_settings};state.pending=null;state.last_result={ok:true,message:'Profile confirmed.'};}
 if(d.method==='rollback'){state.pending=null;state.last_result={ok:true,message:'Previous profile restored.'};}
 if(d.method==='save')state.presets.push({id:'p_'+Math.random().toString(16).slice(2),name:args[0],builtin:false,available:true,settings:{...state.current},remote_settings:{...state.remote_current}});
 if(d.method==='delete')state.presets=state.presets.filter(p=>p.id!==args[0]);
 return Promise.resolve({ok:true});
}};
const poll={add:(fn,seconds)=>setInterval(fn,seconds*1000)};
const L={resource:s=>'/luci-static/resources/'+s,url:s=>'#'+s};
fetch('/profiles.js').then(r=>r.text()).then(code=>{
 const mod=new Function('baseclass','rpc','poll','L','E','_',code)({extend:x=>x},rpc,poll,L,E,s=>s);
 document.querySelector('#app').append(E('h2',{},'Network overview (preview)'));
 document.querySelector('#app').append(mod.create({full:false}));
 document.querySelector('#app').append(E('h2',{},'Connection profiles (preview)'));
 document.querySelector('#app').append(mod.create({full:true}));
});
</script></body></html>`;
const routes = {
	'/': ['text/html; charset=utf-8', () => html],
	'/profiles.js': ['text/javascript; charset=utf-8', () => fs.readFileSync(path.join(base,'omr','profiles.js'))],
	'/luci-static/resources/omr/profiles.css': ['text/css; charset=utf-8', () => fs.readFileSync(path.join(base,'omr','profiles.css'))]
};
const server=http.createServer((req,res)=>{
	if (req.url === '/favicon.ico') { res.writeHead(204);res.end();return; }
	const route=routes[req.url];
	if (!route) { res.writeHead(404);res.end();return; }
	res.writeHead(200,{'Content-Type':route[0]});res.end(route[1]());
});
server.listen(0,'127.0.0.1',()=>console.log('Local simulated preview: http://127.0.0.1:'+server.address().port+'/'));
