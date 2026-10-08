// Synthetic loopback-only server used by the native contract suite. No provider.
import http from 'node:http';
import {gatewayHandler,installedRuntimeDirectory} from '../src/gateway.mjs';
let completions=0;
const handler=gatewayHandler({stateDir:process.argv[2],openclawDir:process.env.OPENCLAW_TEAMS_SDK_TEST_DIR||installedRuntimeDirectory(),
  complete:async()=>{completions++;return {provider:'fixture',model:'fixture-model',text:JSON.stringify({sections:[{title:'Summary',body:'Synthetic notes.'}]})};}});
const server=http.createServer(async(req,res)=>{
  if(req.url==='/statistics'){
    res.setHeader('Content-Type','application/json');res.end(JSON.stringify({completions}));return;
  }
  await handler(req,res);
});
server.listen(0,'127.0.0.1',()=>process.stdout.write(String(server.address().port)+'\n'));

process.on('SIGTERM',()=>process.exit(0));
setTimeout(()=>process.exit(2),60000).unref();
