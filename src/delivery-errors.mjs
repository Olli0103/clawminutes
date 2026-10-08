/** Safe, stable outcomes shared with the helper. Never serialize provider exceptions. */
export class DeliveryError extends Error {
  constructor(code,detail,{retryable=false,completionAttempted=false,status=422,cause}={}){
    super(detail,{cause});this.name='DeliveryError';Object.assign(this,{code,retryable,completionAttempted,status});
  }
}
export function deliveryError(error,{completionAttempted=false}={}){
  if(error instanceof DeliveryError)return error;
  return new DeliveryError(completionAttempted?'ai_completion_failed':'archive_unavailable',
    completionAttempted?'The notes model could not finish. Audio and transcript are preserved.':'The meeting could not be saved. Your local files are preserved.',
    {retryable:true,completionAttempted,status:503});
}
