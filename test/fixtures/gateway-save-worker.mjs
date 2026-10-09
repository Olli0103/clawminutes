import {saveEnvelope,verifyEnvelope} from '../../src/gateway.mjs';

process.once('message',async ({stateDir,openclawDir,envelope,hold=false,verify=false,fail=false})=>{
  let calls=0;
  try{
    const result=await (verify?verifyEnvelope:saveEnvelope)(envelope,{stateDir,openclawDir,complete:async()=>{
      calls++;
      if(hold){
        const released=new Promise(resolve=>process.once('message',resolve));
        process.send({kind:'completion'});
        await released;
      }
      if(fail)throw Error('Synthetic provider failure');
      return {text:JSON.stringify({sections:[{title:'Summary',body:'Synthetic completion'}]}),provider:'fixture',model:'fixture'};
    }});
    process.send({kind:'result',ok:true,calls,sessionId:result.sessionId},()=>process.disconnect());
  }catch(error){
    process.send({kind:'result',ok:false,calls,code:error.code,retryable:error.retryable,completionAttempted:error.completionAttempted},()=>process.disconnect());
  }
});
