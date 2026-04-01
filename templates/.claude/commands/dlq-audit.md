# /dlq-audit — Audit production DLQ messages and triage root causes

You are the dlq-audit skill. Your job is to inspect production SQS dead letter queues, identify why messages are failing, and either create fix tasks or document findings.

## Input

Optional: `$ARGUMENTS` — a specific DLQ short name to focus on (e.g. `safer-output-nonpertinent`). If omitted, audit all non-empty DLQs.

## Prerequisites

- Production AWS credentials via `aws-vault exec production`
- Queue inventory in `docs/infrastructure.md` (create it if missing — see Step 1)
- Code repo checked out at `~/code/{repo-name}` (default: `content-moderation`)

---

## Step 1: Build Queue Inventory (if needed)

If `docs/infrastructure.md` doesn't have a queue list, generate it:

```bash
aws-vault exec production -- aws sqs list-queues \
  --queue-name-prefix "production-content-moderation" \
  --max-results 1000 \
  --query 'QueueUrls' --output json
```

Save queue/DLQ pairs to `docs/infrastructure.md`.

---

## Step 2: Find Non-Empty DLQs

Get message counts for all DLQs:

```bash
aws-vault exec production -- aws sqs get-queue-attributes \
  --attribute-names ApproximateNumberOfMessages \
  --queue-url "https://sqs.us-west-2.amazonaws.com/{account}/{dlq-name}" \
  --query 'Attributes.ApproximateNumberOfMessages' --output text
```

Do this for every DLQ in the inventory. Use a script to loop through them and print only non-zero ones.

**Skip these unless explicitly asked:**
- Backfill DLQs (names containing `backfill`) — often have intentional noise during active operations
- Any DLQ you already know is an active infrastructure incident (document in `docs/infrastructure.md`)

---

## Step 3: Inspect Messages

For each non-empty DLQ, receive up to 10 messages:

```bash
aws-vault exec production -- aws sqs receive-message \
  --queue-url "https://sqs.us-west-2.amazonaws.com/{account}/{dlq-name}" \
  --max-number-of-messages 10 \
  --attribute-names All
```

**Important:** receiving messages makes them temporarily invisible (visibility timeout). Do NOT delete messages unless you are certain they should be discarded. If you're just inspecting, messages will reappear after the visibility timeout.

**Key fields to note from each message:**
- `Body` — the message payload (parse the JSON)
- `ApproximateReceiveCount` — how many times it's been retried (high = chronic, low = recent/transient)
- `SentTimestamp` — when it entered the DLQ
- `DeadLetterQueueSourceArn` — which queue it came from

---

## Step 4: Cross-Reference with Code

For each DLQ'd message, find the processor that handles it:

1. The DLQ source name tells you the queue (e.g. `safer-output-nonpertinent-queue`)
2. Search the codebase for the `@EventPattern` that matches: `grep -r "safer-output-nonpertinent" ~/code/content-moderation/service/src`
3. Read the processor and any services it calls
4. Understand what the message payload represents and where processing could fail

**Common failure patterns to look for:**

- **GraphQL partial responses**: `parseGraphqlResponse()` in `parse-graphql.ts` throws on field-level errors (errors with a `path` array) even when `data` is valid. Look for `DOWNSTREAM_SERVICE_ERROR` in GQL responses for nullable fields.
- **Missing/deleted S3 objects**: Scanner or processor tries to fetch an S3 object that no longer exists. Look for `NoSuchKey`, `AccessDenied (403)`, or `Not Found (404)` errors embedded in message bodies.
- **Orphan accounts**: Account whose owner (`User`) was deleted; GQL resolvers for `ownedBy` return `DOWNSTREAM_SERVICE_ERROR`. Fixed by task-009 (parseGraphqlResponse fix).
- **Zod schema validation failures**: Message body doesn't match the expected schema. Often means the upstream schema changed.
- **Transient errors + low `maxReceiveCount`**: Some queues have `maxReceiveCount: 1` — a single transient failure (network blip, throttle spike) becomes permanent. Check `RedrivePolicy.maxReceiveCount` on the source queue.
- **External service downtime**: Scanning services, monolith, or third-party APIs returning 5xx. Check if the error is specific to certain accounts/content or affects everything.

---

## Step 5: Classify Each DLQ

For each non-empty DLQ, assign a classification:

| Classification | Meaning | Action |
|---|---|---|
| **Code fix needed** | A bug in the processor is causing valid messages to fail | Create a task |
| **Infrastructure incident** | Infra-level issue (S3 migration, service outage) — not a code bug | Document, wait for infra team |
| **Transient + safe to redrive** | Transient failure, message is valid, safe to process now | Redrive |
| **Stale/purgeable** | Message is for deleted content, banned accounts, or otherwise no longer actionable | Note for the operator to purge |
| **Needs investigation** | Not enough info to classify | Document what you know and what's needed |

---

## Step 6: Take Action

### If code fix needed:
Create a task in `queue/pending/` following the task file format. Include:
- The specific error and where it occurs
- The proposed fix (code snippets if possible)
- Which accounts/messages are affected
- Whether stuck DLQ messages can be redriven after the fix ships

### If safe to redrive:
Use `StartMessageMoveTask` if you have permission:
```bash
aws-vault exec production -- aws sqs start-message-move-task \
  --source-arn "arn:aws:sqs:us-west-2:{account}/{dlq-name}" \
  --destination-arn "arn:aws:sqs:us-west-2:{account}/{source-queue-name}"
```

If you don't have `sqs:StartMessageMoveTask` permission, note it for the operator to action via the AWS console.

### If infrastructure incident:
Document in `docs/infrastructure.md` under the DLQ status snapshot with owner and status.

---

## Step 7: Update Documentation

Update `docs/infrastructure.md`:
- Update the DLQ status snapshot table with findings
- Add to Known Root Causes if a new systemic pattern is found
- Note which DLQs can be redriven once a fix ships

Update `state.md` with a Recent Activity entry summarising the audit.

---

## Operational Notes

- **Don't delete messages** unless explicitly asked. Receiving and inspecting is safe; deletion is irreversible.
- **Don't send test messages** to live queues — any message sent will be processed by the production worker.
- **SQS counts are approximate.** `ApproximateNumberOfMessages` can lag; a queue that looks empty may have a few messages.
- **Visibility timeouts matter.** If you receive a message for inspection, it becomes invisible for the queue's visibility timeout (often 30–40 minutes). Don't be surprised if subsequent receives return nothing.
- **`maxReceiveCount: 1` queues** are unforgiving — any single failure is permanent. Transient errors on these queues always require a manual redrive.
