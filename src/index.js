import {gatewayHandler,installedRuntimeDirectory} from './gateway.mjs';
import os from 'node:os';
import {gatewayCompletion,notesSelection} from './notes-model.mjs';
import path from 'node:path';
import {defineFeaturePlugin} from 'openclaw/plugin-sdk/feature-plugin';
import {defineFeatureContract} from 'openclaw/plugin-sdk/feature-contract';
import {fileURLToPath} from 'node:url';
import fs from 'node:fs/promises';
import {distributionHandler,downloadHandler,helperArchive} from './distribution.mjs';
const contract=defineFeatureContract({pluginId:'teams-transcribe',operations:{status:{kind:'query',description:'Inspect recording-Mac transcription status without capture',input:{type:'object',properties:{},additionalProperties:false},output:{type:'object',additionalProperties:true}}},events:{}});
const entry=defineFeaturePlugin({
  contract,name:'ClawMinutes',
  description:'Local consent-based Teams recording and transcription. No participant joins the call.',
  setup(api){
    const selection=notesSelection(api.config,api.pluginConfig);
    const settings={notesModel:selection.model,complete:gatewayCompletion(api.config,api.pluginConfig),openclawDir:installedRuntimeDirectory(),stateDir:process.env.OPENCLAW_STATE_DIR||path.join(os.homedir(),'.openclaw')};
    api.registerHttpRoute({path:'/plugins/teams-transcribe/ingest',auth:'gateway',match:'exact',handler:gatewayHandler(settings)});
    api.registerHttpRoute({path:'/plugins/teams-transcribe/helper',auth:'gateway',match:'exact',handler:distributionHandler});
    api.registerHttpRoute({path:'/plugins/teams-transcribe/helper.zip',auth:'gateway',match:'exact',handler:downloadHandler});
    api.registerCli(({program})=>{
      const root=program.command('teams-transcribe').description('Manage the bundled recording-Mac helper from the Gateway');
      root.command('helper-path').action(()=>console.log(path.join(path.dirname(fileURLToPath(import.meta.url)),'../helper/ocmh.app')));
      root.command('helper-export').requiredOption('--output <path>','Destination zip on the Gateway').action(async opts=>{
        await fs.copyFile(helperArchive,path.resolve(opts.output));
        console.log(JSON.stringify({helperArchive:path.resolve(opts.output),helper:'ocmh',pluginOwner:'teams-transcribe',requiresLocalOpenClaw:false,lifecycle:'Bundled helper.py install / run / update / remove on the recording Mac'}));
      });
    },{descriptors:[{name:'teams-transcribe',description:'Bot-free Teams transcription helper bundle',hasSubcommands:true}]});
    return {status:()=>({gatewayMachine:os.hostname(),ingestPath:'/plugins/teams-transcribe/ingest',auth:'gateway',rawAudioAccepted:false,helperRunsOn:'recording_mac'})};
  }
});
export default entry;
