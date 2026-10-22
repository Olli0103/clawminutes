// Doctor loads this entry independently of Gateway routes and model credentials.
// Existing notes settings use the current schema and require no transformation.
export function normalizeCompatibilityConfig({cfg}) {
  const settings=cfg.plugins?.entries?.['teams-transcribe']?.config;
  if(settings!==undefined) {
    if(!settings||typeof settings!=='object'||Array.isArray(settings))throw new Error('Meeting notes settings must be an object');
    if(Object.keys(settings).some(key=>!['notesModel','notesAgentId'].includes(key)))throw new Error('Unknown meeting notes setting');
    if(settings.notesModel!==undefined&&(typeof settings.notesModel!=='string'||settings.notesModel.length<3||settings.notesModel.length>200||!/^[-\w]+\/\S{1,180}$/.test(settings.notesModel)))throw new Error('Notes model must use provider/model');
    if(settings.notesAgentId!==undefined&&(typeof settings.notesAgentId!=='string'||settings.notesAgentId.length<1||settings.notesAgentId.length>80))throw new Error('Invalid notes credential owner');
  }
  return {config:cfg,changes:[]};
}

// Meeting storage is owned by the OpenClaw archive SDK. The helper's recordings
// stay on its Mac; this plugin has no separate Gateway state migration.
export const stateMigrations=[];
