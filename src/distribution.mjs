import fs from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {pipeline} from 'node:stream/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const {version}=JSON.parse(await fs.readFile(new URL('../package.json',import.meta.url),'utf8'));
export const helperArchive=fileURLToPath(new URL('../helper/recording-mac.zip',import.meta.url));
export async function distributionHandler(req,res){
  if(req.method!=='GET'){res.writeHead(405);res.end();return true;}
  const buffer=await fs.readFile(helperArchive);
  res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','private, no-store');
  res.end(JSON.stringify({plugin:'teams-transcribe',version,helperName:'ocmh',sha256:createHash('sha256').update(buffer).digest('hex'),downloadPath:'/plugins/teams-transcribe/helper.zip',requiresLocalOpenClaw:false,lifecycle:['install','run','update','remove']}));
  return true;
}
export async function downloadHandler(req,res){
  if(req.method!=='GET'){res.writeHead(405);res.end();return true;}
  const stat=await fs.stat(helperArchive);
  res.setHeader('Content-Type','application/zip');res.setHeader('Content-Length',stat.size);res.setHeader('Cache-Control','private, no-store');
  res.setHeader('Content-Disposition','attachment; filename="ocmh-recording-mac.zip"');
  await pipeline(createReadStream(helperArchive),res);return true;
}
