import {DeliveryError} from './delivery-errors.mjs';
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
  if(user.length>350000)throw new DeliveryError('ai_input_too_large','Meeting text exceeds the AI notes limit. Use simple notes or transcript only.');
  const {prepareSimpleCompletionModelForAgent,completeWithPreparedSimpleCompletionModel,extractAssistantText}=await import("openclaw/plugin-sdk/simple-completion-runtime");
  const selection=notesSelection(cfg,settings);
  if(!selection.agentId)throw new DeliveryError('notes_owner_required','Select a notes owner in the Gateway plugin settings. Recording preserved.',{status:503});
  const signal=AbortSignal.timeout(120000);
  let prepared;try{prepared=await prepareSimpleCompletionModelForAgent({cfg,agentId:selection.agentId,modelRef:selection.model,signal});}catch(cause){throw new DeliveryError('notes_model_unavailable','Gateway notes model preparation failed. Check Gateway model access. Recording preserved.',{status:503,cause});}
  if(prepared.error)throw new DeliveryError('notes_model_unavailable','Gateway notes model is unavailable. Check the Gateway model configuration.',{status:503});
  let answer;try{answer=await completeWithPreparedSimpleCompletionModel({...prepared,cfg,context:{systemPrompt:system,tools:[],messages:[{role:'user',content:user,timestamp:Date.now()}]},options:{maxTokens:6000,reasoning:'low',signal}});}catch(cause){throw new DeliveryError('ai_completion_failed','Gateway notes model completion failed. Recording preserved.',{retryable:true,completionAttempted:true,status:503,cause});}
  if(answer.content?.some(c=>c.type==='toolCall'))throw new DeliveryError('ai_tool_attempt','The notes model attempted a tool call. No action was run.',{completionAttempted:true});
  if(answer.stopReason==='error'||answer.stopReason==='aborted')throw new DeliveryError('ai_completion_failed','Gateway notes model did not finish. Recording preserved.',{retryable:true,completionAttempted:true,status:503});
  return {text:extractAssistantText(answer),provider:answer.provider||prepared.model.provider,model:answer.model||prepared.model.id};
 };
}
