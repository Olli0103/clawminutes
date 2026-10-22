import fs from 'node:fs/promises';
import {constants} from 'node:fs';
import path from 'node:path';
import {DeliveryError} from './delivery-errors.mjs';

const unavailable=()=>new DeliveryError('notes_state_conflict','Meeting save ownership could not be verified. Existing files are preserved; review Gateway storage before retrying.',{status:409});
const busy=()=>new DeliveryError('save_in_progress','Another process is saving this meeting. Retry after it finishes.',{retryable:true,status:409});
function owned(info){return process.getuid===undefined||info.uid===process.getuid();}
async function directory(file,{privateMode=false}={}){
  const info=await fs.lstat(file);
  if(!info.isDirectory()||!owned(info)||(privateMode&&(info.mode&0o077)!==0))throw unavailable();
  return info;
}
async function regular(file,{optional=false,empty=false}={}){
  try{
    const info=await fs.lstat(file);
    if(!info.isFile()||info.nlink!==1||!owned(info)||(info.mode&0o077)!==0||(empty&&info.size!==0))throw unavailable();
    return info;
  }catch(error){if(optional&&error.code==='ENOENT')return undefined;throw error;}
}

// An empty, private SQLite database is an OS-managed mutex, not a PID/expiry
// lease. Keep its inode on disk after release. Never unlink a supposedly stale
// lock: a live process may still hold the original inode. BEGIN IMMEDIATE has
// a zero busy timeout, so contention cannot stall the event loop waiting for
// another model request. The transaction contains no meeting data or writes.
export async function withSaveOwnership(stateDir,id,operation){
  let db;
  try{
    if(typeof stateDir!=='string'||!stateDir.length||!/^teams-[a-f0-9]{24}$/.test(id))throw unavailable();
    await fs.mkdir(stateDir,{recursive:true,mode:0o700});
    const root=await fs.realpath(stateDir);
    const plugin=path.join(root,'teams-transcribe');
    await fs.mkdir(plugin,{recursive:true,mode:0o700});await directory(plugin);
    const locks=path.join(plugin,'save-ownership');
    await fs.mkdir(locks,{mode:0o700}).catch(error=>{if(error.code!=='EEXIST')throw error;});
    const parent=await directory(locks,{privateMode:true});
    const file=path.join(locks,id+'.sqlite');
    try{
      const created=await fs.open(file,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
      await created.close();
    }catch(error){if(error.code!=='EEXIST')throw error;}
    const before=await regular(file,{empty:true});
    for(const suffix of ['-journal','-wal','-shm'])await regular(file+suffix,{optional:true});
    const {DatabaseSync}=await import('node:sqlite');
    db=new DatabaseSync(file,{timeout:0,allowExtension:false});
    db.exec('BEGIN IMMEDIATE');
    const after=await regular(file,{empty:true}),currentParent=await directory(locks,{privateMode:true});
    if(before.dev!==after.dev||before.ino!==after.ino||parent.dev!==currentParent.dev||parent.ino!==currentParent.ino)throw unavailable();
  }catch(error){
    db?.close();
    if(error instanceof DeliveryError)throw error;
    if(error.errcode===5||error.errcode===6)throw busy();
    throw unavailable();
  }
  try{return await operation();}
  finally{db.close();}
}
