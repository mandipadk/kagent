# Scheduled runs and caller identity

`ScheduledRun` is a namespaced Kubernetes resource that invokes an Agent on a
cron schedule or through a manual trigger. Kubernetes owns its configuration;
PostgreSQL stores accepted executions and their Session links. Each execution
runs through the A2A gateway as the controller's service-account principal.

## Ownership and APIs

| State | Owner | Contents |
| --- | --- | --- |
| `ScheduledRun` | Kubernetes | Agent reference, cron expression, time zone, prompt, pause flag, timeout, and reconciliation status |
| Schedule projection | PostgreSQL, maintained by reconciliation | Resource UID/generation, accepted spec, resolved Agent UID, and next occurrence |
| Execution | PostgreSQL | Accepted inputs, deadline, initiator, lease, dispatch state, and Session/task links |
| Session | Control-plane Session service | Conversation identity, creator principal, Agent binding, and scheduled-execution provenance |
| Task and history | A2A | Task identity, progress, results, and transcript |

ScheduledRunService exposes CRUD through the same `ResourceReference` and
`StructuredObject` envelope as other Kubernetes resources. The CRD is the
configuration schema. Trigger and execution-history RPCs use the schedule UID,
so deleting and recreating a resource under the same name does not transfer its
history to the replacement.

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: ScheduledRun
metadata:
  name: morning-triage
  namespace: support
spec:
  agentRef:
    name: ticket-assistant
  schedule: "0 9 * * 1-5"
  timeZone: UTC
  prompt: Summarize unassigned urgent tickets.
  paused: false
  executionTimeout: 15m
```

The Agent reference resolves within the schedule's namespace. Status reports
the observed generation and a `Ready` condition. Readiness means the schedule
configuration has been synchronized; it does not report an execution's outcome.

## Reconciliation and execution

1. The reconciler validates the schedule, resolves the Agent UID, and synchronizes
   the database projection. Invalid configuration, a missing Agent, or unavailable
   scheduler authentication disables new reservations and sets `Ready=False`.
2. The scheduler reserves due occurrences. Manual triggers authorize the target
   Agent and reserve the exact schedule generation that was checked. Each accepted
   execution captures its prompt, deadline, Agent UID, and schedule UID/generation.
3. The execution controller leases work, atomically reserves its Session, prepares
   the runtime, and claims dispatch before sending the prompt through the A2A
   gateway. The Session creator is the scheduler's principal.
4. A2A assigns the task ID and persists task progress. Subsequent reconciliation
   reads that state to record the execution's outcome or stop it at its deadline.

Cron occurrences deduplicate by schedule UID and occurrence time; manual triggers
deduplicate by schedule UID and request ID. Retries use the accepted inputs, so
later schedule edits cannot change work already reserved. A replacement Agent
with the same name cannot adopt executions bound to the old Agent UID.

The dispatch claim prevents a controller retry from sending the prompt twice.
If a response is lost, reconciliation finds the task through the original A2A
message ID. A claimed dispatch with no recorded task remains uncertain until
history appears or the deadline expires; it is not automatically sent again.

Pausing a valid schedule stops cron reservations while leaving manual triggers
available. Disabling an invalid projection prevents both kinds of new reservation.
Already accepted executions retain their inputs and remain queryable.

### Deletion and watch scope

Before reserving cron work, the scheduler reads the live CRD through an uncached
Kubernetes reader and checks its UID, generation, deletion state, and watched
namespace. The store rechecks projection eligibility and generation in the
reservation transaction. A concurrent edit cannot reserve work against a stale
projection.

The finalizer normally retires the projection before deletion completes. Live
source checks also stop new reservations after forced or offline deletion and
when a namespace leaves the controller's watch scope. A transient Kubernetes
read error skips the reservation without retiring the schedule. Accepted
executions and retained history survive schedule deletion.

## Caller and runtime identity

| Identity | Role in a scheduled execution |
| --- | --- |
| Invocation principal | The controller service account that calls the Agent |
| Session creator | The principal recorded when the execution's Session is created |
| Runtime principal | The verified Substrate Actor bound to that Session |
| Manual-trigger initiator | The caller recorded for attribution when a trigger is accepted |

`Principal.ID` is a stable, opaque identifier shared by human, service-account,
and runtime callers. Authentication normalizes the source identity and supplies
verified claims. Authorization uses those claims and trusted resource references;
consumers compare principal IDs without parsing them. `Session.creator` stores
the creating principal's ID. It does not select a credential for subsequent calls.

Kubernetes authentication uses TokenReview and maps the verified service-account
UID under a configured cluster authority. Rotation preserves the principal ID;
deleting and recreating the service account changes it. The authority must remain
stable across restarts and distinct from other Kubernetes authentication sources
sharing the store. Trusted-proxy authentication scopes its identity claim by the
authenticated issuer; the proxy owns token verification. Insecure development
mode permits caller-selected IDs without identity assurance.

Runtime principals use the verified Actor's atespace and UID. Their
`RuntimeBinding` identifies the Session and its creator for data scoping. The
runtime authorizer restricts them to that Session and its Agent; the creator
binding does not grant the creator's permissions. Human and service-account
principals have no runtime binding.

All schedules using the controller service account share its principal and
downstream permissions. Schedule, Agent, and execution references provide
attribution and authorization context. Manually triggering a schedule still
runs as the scheduler. A later direct invocation of its Session uses the new
caller's authenticated context.

## Scheduler credentials

The controller uses separate projected service-account tokens for incoming Kagent
authentication and downstream token passthrough:

| Credential | Audience | Use |
| --- | --- | --- |
| Inbound token | `kagent-invocation` | Establish the scheduler's Kagent principal |
| Outbound token | `kagent-egress` | Supply a scheduled invocation's passthrough credential |
| Kubernetes API token | Kubernetes API audience | Access the Kubernetes API |

The inbound audience is fixed at `kagent-invocation`. The outbound audience
defaults to `kagent-egress` and is configured for the receiving service.

Inbound and outbound tokens must identify the same service-account UID. Kagent
rejects equal audiences and outbound tokens that also carry the inbound audience.
The outbound token therefore cannot be replayed as a Kagent login credential.
Downstream services verify its issuer and audience and assign its downstream
permissions.

Helm configures the requested outbound lifetime:

```yaml
config:
  scheduledRuns:
    outboundCredential:
      audience: kagent-egress
      tokenFile: /run/kagent-egress/token
      expirationSeconds: 3600
```

Kubernetes requires at least 600 seconds and may issue a different lifetime.
Kubelet rotates the projected tokens. Each invocation captures the current
verified outbound token, so its remaining lifetime may be shorter than the
requested TTL. Further credential-dependent requests fail after expiry; a
running invocation does not adopt a rotated token. Changing the scheduler's
service-account UID prevents it from continuing executions attributed to the
previous principal.

Go and Python carry the caller credential in invocation-local context. Bearer
tokens are absent from CRDs, revisions, Sessions, execution records, and the
controller's persistent state. Claude and Codex do not support caller-token
passthrough. The Actor's internal `kagent-runtime` JWT authenticates runtime calls
to the control plane independently of the invocation credential.

[Runtime credential injection](credential-injection.md) describes header sources,
destination grants, transport behavior, and credential expiry.

## Session access and retained data

Authorization distinguishes schedule configuration (`ScheduledRun`), invocation
(`ScheduledRunInvocation`), and history (`ScheduledRunHistory`). Services combine
these checks with Session permissions. Session reads require schedule history
access; continuation and lifecycle mutations require the corresponding schedule
invocation permission. Listings filter unauthorized Sessions before pagination.
Stored schedule references preserve these checks after the CRD is deleted.

Checkpoints retain the source Session's creator and scheduled provenance. Reads,
creation, and forks require source Session read access and schedule history
permission as well as the checkpoint operation's permission. Renaming or removing
a scheduled checkpoint requires the corresponding schedule invocation permission.
Retained provenance supports these checks after the source Session expires. A
fork belongs to its authenticated caller and has no scheduled-execution provenance.

Read-only shares remain limited to their Session and cannot invoke work. Shares
are managed by their recorded creator. Runtime access remains limited to the
Actor's verified Session binding.

Memory is partitioned by Agent namespace/name and creator principal ID. Schedules
using the same service account and Agent therefore share memory. Rotation and
later callers do not change the partition, and recreating an Agent under the same
name retains that principal's memory.
