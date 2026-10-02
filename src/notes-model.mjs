export function notesSelection(cfg,settings={}) {
 const entries=cfg?.agents?.entries||{};
 const ids=Array.isArray(entries)?entries.map(e=>e.id):Object.keys(entries);
 const agentId=settings.notesAgentId||cfg?.agents?.defaults?.systemAgent?.agentId||(ids.length===1?ids[0]:undefined);
 const entry=Array.isArray(entries)?entries.find(e=>e.id===agentId):entries[agentId];
 const raw=entry?.model||cfg?.agents?.defaults?.model;
 if(settings.notesModel!==undefined && (typeof settings.notesModel!=='string'||!/^[-\w]+\/\S{1,180}$/.test(settings.notesModel)))throw Error('Choose a notes model as provider/model in the Gateway plugin settings.');
 return {agentId,model:settings.notesModel||(typeof raw==='string'?raw:raw?.primary)};
}
export function gatewayCompletion(cfg,settings={}){
 return async ({system,user})=>{
  if(user.length>350000)throw Error('Meeting text exceeds the AI notes limit. Use simple notes or transcript only.');
  const {prepareSimpleCompletionModelForAgent,completeWithPreparedSimpleCompletionModel,extractAssistantText}=await import("openclaw/plugin-sdk/simple-completion-runtime");
  const selection=notesSelection(cfg,settings);
  if(!selection.agentId)throw Error("Select a notes owner in the Gateway plugin settings. Recording preserved.");
  const signal=AbortSignal.timeout(120000);
  let prepared;try{prepared=await prepareSimpleCompletionModelForAgent({cfg,agentId:selection.agentId,modelRef:selection.model,signal});}catch{throw Error("Gateway notes model preparation failed. Check Gateway model access. Recording preserved.");}
  if(prepared.error)throw Error('Gateway notes model is unavailable. Check the Gateway model configuration.');
  let answer;try{answer=await completeWithPreparedSimpleCompletionModel({...prepared,cfg,context:{systemPrompt:system,tools:[],messages:[{role:'user',content:user,timestamp:Date.now()}]},options:{maxTokens:6000,reasoning:'low',signal}});}catch{throw Error('Gateway notes model completion failed. Check Gateway model access. Recording preserved.');}
  if(answer.content?.some(c=>c.type==='toolCall'))throw Error('The notes model attempted a tool call. No action was run.');
  if(answer.stopReason==='error'||answer.stopReason==='aborted')throw Error('Gateway notes model did not finish. Recording preserved.');
  return {text:extractAssistantText(answer),provider:answer.provider||prepared.model.provider,model:answer.model||prepared.model.id};
 };
}
