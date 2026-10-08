# Check for an already saved meeting

Older helpers saved successful Gateway receipts without a transcript hash or complete source fingerprint. Matching a session ID, utterance count and speech alone cannot prove which meeting details were sent. These meetings stay in Needs attention and cannot be resent automatically or through the direct save path. Existing declared fingerprints must still match the current source.

Meeting details offer **Check for saved meeting…** when an older receipt lacks fingerprints or the local receipt is absent. A missing confirmation does not establish that the Gateway saved anything. Opening the sheet only reviews local files. **Check on Gateway** explicitly sends the closed text envelope for comparison. It sends the transcript, timestamps, observed meeting details and notes selection, never audio. If the notes default changed, choose the original notes root above its year/month folders. This does not change the future default or copy history.

## Verification contract

The existing ingest endpoint accepts `POST ?mode=verify`. The helper requires `capabilities.receiptVerification: 1` before sending meeting text. Unknown, repeated or additional query parameters fail validation. Normal saves use the original endpoint without a query.

Verification uses the admitted SDK's database-path resolver and an existing-archive reader exposing only the three exercised read methods. The SDK's readOnly option alone does not make all its methods read-only. It first checks that the database exists because the SDK otherwise creates a state directory even for a failed read-only open. The adapter's compatibility probe still uses a separate temporary synthetic store. Verification does not reserve a notes attempt, call a model, create a session, append speech, write a summary or update the Gateway's attempt ledger.

The Gateway compares the exact utterances and their evidence, source, title, clocks, STT provenance, participants, meeting context, capture gaps, revision, notes backend and template. It requires a completed canonical summary and consistent readback. A missing, partial or conflicting record cannot become a successful verification. A same-process in-flight save is rejected. Cross-process Gateway ownership remains an unverified host assumption.

The response includes persisted meeting documents and a versioned `canonical_readback` proof containing the SHA-256 of the exact request body bytes. The helper checks that proof, archive identity, count and document shape. It rechecks the reviewed local files and directory identity under the meeting save lock and installer lifecycle lease, including after the network response.

## Local repair and limits

A genuinely absent receipt is snapshot-bound as absent. Preparation derives the expected session identity from the recording's start time and stable recording ID, then compares the exact text package. A receipt appearing during review or readback invalidates the plan. Malformed, unreadable or linked receipts are not treated as absent. Prior transcript-fingerprint conflicts and invalid state still block verification. Existing notes-location bindings must match that identity and preserve the original destination, even if the future default changed. Ordinary exports cannot use the receipt-less binding.

A verified match restores a missing receipt, or preserves an existing old receipt as `archive-receipt.legacy-<sha256>.json`, binds the returned receipt to the current transcript bytes and complete normalized text package, recovers the local export and reconciles progress. Existing export edits and audio remain. A replaced recording directory, changed source, unavailable ownership or malformed reply blocks publication. See [delivery evidence](delivery-evidence.md) for the two local fingerprints.

Receipt publication, export and state are separate writes. If export or progress fails after verification, the repaired receipt and its original backup remain. A normal verified-export retry can finish offline without another completion. This is not a transaction across recording and notes folders. Atomic rename does not guarantee hardware durability, and a hostile concurrent replacement of parent paths is outside this filesystem model.

Attempt counts, unknown paid budgets and frozen legacy retry/recovery files stay intact. A transcript-only recovery's existing request is included for canonical comparison; verification does not arm or consume another request. A prior local delivery fingerprint that differs from the current transcript still requires review. Unprovable failed-attempt Gateway fingerprints are not reset or reconciled by this action. This path repairs provably completed saves only; it does not authorize another paid attempt or audio deletion.

## Verification evidence

Isolated tests use real SDK 2026.9.7 and 2026.9.8 stores with synthetic model callbacks. They cover read-only canonical admission, zero verification writes/completions, unchanged ledgers, missing and partial archives, conflicting text/template/title and query rejection. The Swift-to-JavaScript HTTP contract strips a saved receipt's local hash, verifies it, repairs the receipt and retains an edited export without increasing the synthetic completion count. It also removes a completed save's local receipt, marks its local budget unknown and replaces the Gateway attempt ledger with an unprovable legacy hash. Canonical readback repairs the exact save, retains the edited original export, leaves both budgets/ledger bytes intact and keeps the same five synthetic completions across the entire contract.

Native tests cover pure preparation, frozen evidence and unknown budgets, unsupported capabilities, incorrect request proof, source changes during readback, earlier fingerprint conflicts, malformed documents, replaced directories, save/installer ownership and offline export recovery. Light/dark sheets for legacy and missing receipts render offscreen. These are source and fixture results. Installed helper behavior, proxy query forwarding and live canonical readback remain `needs_evidence` until approved activation and acceptance.
