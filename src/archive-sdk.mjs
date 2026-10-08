import fs from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {DeliveryError} from './delivery-errors.mjs';
import {verifyArchiveStore} from './archive-contract.mjs';

const failure=cause=>new DeliveryError('plugin_update_needed','The Gateway archive implementation could not be verified. Check the installed SDK and plugin versions. Local files are preserved.',{status:503,cause});
const inside=(root,file)=>{
  const relative=path.relative(path.resolve(root),file);
  return path.isAbsolute(file)&&!!relative&&relative!=='..'&&!relative.startsWith('..'+path.sep)&&!path.isAbsolute(relative);
};
const digest=source=>createHash('sha256').update(source).digest('hex');
async function load(file,source){
  const hash=digest(source??await fs.readFile(file)),url=pathToFileURL(file);
  url.searchParams.set('clawminutesContract',hash);
  return {url:url.href,hash,module:await import(url.href)};
}
// One interface owns SDK discovery, admission proof, version provenance and
// existing-database resolution. No caller writes guessed SQLite rows.
export async function archiveRuntime(openclawDir){
  if(!openclawDir)throw new DeliveryError('plugin_update_needed','needs_evidence: installed OpenClaw directory is required for the Meetings archive adapter.',{status:503});
  try{
    const pkg=JSON.parse(await fs.readFile(path.join(openclawDir,'package.json'),'utf8'));
    if(pkg.name!=='openclaw'||typeof pkg.version!=='string'||pkg.version.length>80||!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$(?![\s\S])/.test(pkg.version))throw Error('Invalid SDK provenance');
    const dist=path.join(openclawDir,'dist'),files=(await fs.readdir(dist)).sort();
    let storeEntry,resolverEntry;
    for(const name of files.filter(name=>/^store-.*\.mjs$/.test(name))){
      const file=path.join(dist,name);
      const source=await fs.readFile(file,'utf8');
      if(!source.includes('src/transcripts/store.ts'))continue;
      const {url,hash,module}=await load(file,source);
      const entry=Object.entries(module).find(([,value])=>typeof value==='function'&&typeof value.prototype?.appendUtteranceForSession==='function');
      if(entry){storeEntry={url,hash,key:entry[0],Store:entry[1]};break;}
    }
    for(const name of files.filter(name=>/^openclaw-state-db\.paths-.*\.mjs$/.test(name))){
      const {url,hash,module}=await load(path.join(dist,name));
      const entry=Object.entries(module).find(([,value])=>typeof value==='function'&&value.name==='resolveOpenClawStateSqlitePath');
      if(entry){resolverEntry={url,hash,key:entry[0],resolve:entry[1]};break;}
    }
    if(!storeEntry||!resolverEntry)throw Error('Archive SDK interface changed');
    const descriptor={storeURL:storeEntry.url,storeExport:storeEntry.key,storeSHA256:storeEntry.hash,
      resolverURL:resolverEntry.url,resolverExport:resolverEntry.key,resolverSHA256:resolverEntry.hash};
    await verifyArchiveStore(storeEntry.Store,descriptor);
    for(const entry of [storeEntry,resolverEntry])if(digest(await fs.readFile(new URL(entry.url)))!==entry.hash)throw Error('Archive module changed during admission');
    return Object.freeze({Store:storeEntry.Store,version:pkg.version,adapterVersion:2,verification:'isolated-readback-v2',
      async existingReader(stateDir){
        const file=resolverEntry.resolve({...process.env,OPENCLAW_STATE_DIR:stateDir});
        if(typeof file!=='string'||!inside(stateDir,file))throw failure();
        try{
          const info=await fs.lstat(file);
          if(!info.isFile()||info.isSymbolicLink())throw Error('Archive database requires review');
          const actualRoot=await fs.realpath(stateDir),actualFile=await fs.realpath(file);
          if(!inside(actualRoot,actualFile))throw Error('Archive database escaped state through a link');
          const store=new storeEntry.Store(path.join(stateDir,'transcripts'),{path:file,readOnly:true,env:{...process.env,OPENCLAW_STATE_DIR:stateDir}});
          // Expose only the readers verified by the isolated probe. SDK write
          // methods do not consistently honor the readOnly constructor option.
          return Object.freeze(Object.fromEntries(['readSession','readUtterancesForSession','readSummary'].map(name=>[name,store[name].bind(store)])));
        }catch(error){if(error.code==='ENOENT')return null;throw failure(error);}
      }
    });
  }catch(cause){if(cause instanceof DeliveryError)throw cause;throw failure(cause);}
}
