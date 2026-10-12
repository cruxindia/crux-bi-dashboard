// Usage: node loader.js <zonal|case|point> [shard=i/n]  — expects extracted JSON in ../out/<kind> (see tools/extract-all.js)
// Bulk loader: same RPC protocol as the browser Upload Centre.
const fs=require('fs'),crypto=require('crypto');
const URL=(process.env.SUPABASE_URL||'https://czdjbbhxboweawqbjywr.supabase.co')+'/rest/v1/rpc/bi_ingest';
const KEY=process.env.SUPABASE_PUBLISHABLE_KEY; if(!KEY) throw new Error('Set SUPABASE_PUBLISHABLE_KEY');
const TOKEN=process.env.BI_INGEST_TOKEN; if(!TOKEN) throw new Error('Set BI_INGEST_TOKEN (issued by an admin, time-limited)');
async function rpc(action,payload,tries=4){
  for(let i=0;i<tries;i++){
    const r=await fetch(URL,{method:'POST',headers:{apikey:KEY,'Content-Type':'application/json'},body:JSON.stringify({p_token:TOKEN,p_action:action,p_payload:payload}),signal:AbortSignal.timeout(180000)}).catch(e=>({ok:false,status:599,text:async()=>'client timeout/network: '+e.message}));
    const t=await r.text(); if(r.ok) return JSON.parse(t);
    if(i===tries-1||r.status<500&&!/timeout|canceling/i.test(t)) throw new Error(`${action} ${r.status} ${t.slice(0,300)}`);
    await new Promise(s=>setTimeout(s,1500*(i+1)));
  }
}
const sha=f=>crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
async function loadRecords(kind,json,srcFile,chunk){
  const x=JSON.parse(fs.readFileSync(json)); const base=srcFile.split('/').pop();
  const group=base.replace(/_\d{4}-\d{2}(v\d+)?\.xlsx$/,''); const mon=base.match(/_(\d{4}-\d{2})/)[1]+'-01';
  const b=await rpc('begin',{category:kind,file_name:base,file_hash:sha(srcFile),location_group:group,period_month:mon});
  if(b.duplicate) return {file:base,duplicate:b.batch_id};
  const id=b.batch_id; let acc={new:0,changed:0,unchanged:0};
  for(let i=0;i<x.rows.length;i+=chunk){
    await rpc('stage',{batch_id:id,seq_start:i+1,rows:x.rows.slice(i,i+chunk)});
    const c=await rpc('commit',{batch_id:id}); for(const k in acc) acc[k]+=c[k]||0;
  }
  const f=await rpc('finalize',{batch_id:id});
  return {file:base,batch:id,rows:x.rows.length,...acc,status:f.status};
}
async function loadZonal(json,srcFile,keepHistory){
  const z=JSON.parse(fs.readFileSync(json)); const base=z.file_name;
  const b=await rpc('begin',{category:'zonal',file_name:base,file_hash:sha(srcFile),snapshot_date:z.snapshot_date,period_month:z.report_month});
  if(b.duplicate) return {file:base,duplicate:b.batch_id};
  const rows=z.rows.map(r=>keepHistory?r:(({history,...o})=>o)(r));
  await rpc('stage',{batch_id:b.batch_id,seq_start:0,rows:[{snapshot_date:z.snapshot_date,report_month:z.report_month,control:z.control,issues:z.issues}]});
  for(let i=0;i<rows.length;i+=150) await rpc('stage',{batch_id:b.batch_id,seq_start:i+1,rows:rows.slice(i,i+150)});
  const c=await rpc('commit',{batch_id:b.batch_id}); return {file:base,batch:b.batch_id,...c};
}
module.exports={rpc,loadRecords,loadZonal};
if(require.main===module){(async()=>{
  let [mode,...args]=process.argv.slice(2); const t0=Date.now(); let shard=null; args=args.filter(a=>{const m=a.match(/^shard=(\d+)\/(\d+)$/); if(m){shard=[+m[1],+m[2]];return false;} return true;});
  const h=s=>[...s].reduce((a,c)=>(a*31+c.charCodeAt(0))>>>0,7); const inShard=(key,i)=>!shard||((key==null?i:h(key))%shard[1])===shard[0];
  const deadline=Date.now()+ (+process.env.BUDGET_S||520)*1000;
  if(mode==='zonal'){ const files=fs.readdirSync('../out/zonal').sort(); const lastOfMonth={};
    files.forEach(f=>lastOfMonth[f.slice(0,7)]=f);
    for(const [i,f] of files.filter(f=>!args.length||args.includes(f.slice(0,10))).entries()){ if(!inShard(null,i)) continue; if(Date.now()>deadline){console.log('BUDGET_STOP');break;}
      const r=await loadZonal('../out/zonal/'+f,'../src/zonal/ZT_'+f.replace('.json','.xlsx'),lastOfMonth[f.slice(0,7)]===f);
      console.log(JSON.stringify(r)); }
  } else { const dir='../out/'+mode; let files=fs.readdirSync(dir).filter(f=>!args.length||args.includes(f.replace('.json','')));
    files.sort((a,b)=>{const k=s=>s.replace(/_(\d{4}-\d{2})(v\d+)?\.json$/,(m,p,v)=>'_'+p+(v?'0':'1'));return k(a)<k(b)?-1:1;});
    for(const f of files){ if(!inShard(f.replace(/_\d{4}-\d{2}(v\d+)?\.json$/,''),0)) continue; if(Date.now()>deadline){console.log('BUDGET_STOP');break;} const r=await loadRecords(mode,dir+'/'+f,'../src/'+mode+'/'+f.replace('.json','.xlsx'),mode==='case'?800:600);
      console.log(JSON.stringify(r)); } }
  console.log('elapsed s',Math.round((Date.now()-t0)/1000));
})().catch(e=>{console.error('FATAL',e.message);process.exit(1);});}
