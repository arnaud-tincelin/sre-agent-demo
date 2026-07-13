# Repo notes for maintainers

Non-obvious things about this repository. None of this is needed to *run* the demo — see
[README.md](README.md) for that. This is for whoever edits the Bicep, the scripts, or the
agent configuration.

## Where agent behaviour lives

Everything the SRE Agent reads at runtime is declared in [sre-config/](sre-config) and
applied by [scripts/post-provision.sh](scripts/post-provision.sh):

| Path | Applied to | API |
| --- | --- | --- |
| `custom-instructions.md` | Global instructions, every investigation | `PUT /api/v2/agent/customInstructions` |
| `knowledge-base/*.md` | Searchable reference | `POST /api/v1/AgentMemory/upload` (multipart) |
| `skills/*.md` | Progressive-disclosure procedures | `PUT /api/v2/extendedAgent/skills/{name}` |
| `instructions/*.md` | Subagent system prompts | `PUT /api/v2/extendedAgent/agents/{name}` |
| `agent-config.json` | Tool grants and alert routing | as above + `PUT /api/v2/extendedAgent/incidentFilters/{name}` |

Edit the markdown, re-run `bash scripts/post-provision.sh`. It is idempotent.

`${GITHUB_REPO}` and `${RG}` are the only placeholders substituted into sre-config markdown.

The `/api/v2/extendedAgent/*` surface is the one
[the reference lab](https://github.com/microsoft/sre-agent/blob/main/labs/zava-aks-postgres/scripts/setup-sre-agent.ps1)
uses, and it is the better one: every resource is an idempotent `PUT` by name whose
properties can be read straight back for verification. Prefer it over the parallel
`/api/v2/agent/skills` and `/api/v1/incidentPlayground/filters` routes, which need
delete-then-create dances and expose no way to read content back.

## Data-plane API gotchas

**Unknown paths return HTTP 200 with HTML, not 404.** The agent endpoint serves its web UI
as a catch-all. An incorrect API path therefore looks like a success and silently does
nothing — this repo previously shipped three such paths and configured nothing at all for
months. Always assert the response body starts with `{` or `[`, and verify by reading
configuration back rather than trusting a status code.

**The subagent API accepts unknown tool names silently.** A typo or a tool that does not
exist on the agent build becomes a capability the subagent simply never has, with no error.
The verify step in `post-provision.sh` cross-checks every grant against
`GET /api/v2/agent/tools` and prints `phantom=` for anything unmatched. Keep that check.

**Skills: use `PUT /api/v2/extendedAgent/skills/{name}`.** The body goes in
`properties.skillContent` and reads straight back, so the verify step diffs the deployed
skill against the source file.

The other route is a trap. `POST /api/v2/agent/skills` requires the body nested in `files[]`
with `fileName`, `filePath` **and** `content` all present; a top-level `content` field is
accepted and silently ignored, and omitting `filePath` drops the file. Both failure modes
produce a skill that looks healthy — description present, `files: [{"fileName":
"SKILL.md"}]`, enabled — with an empty `SKILL.md`, and that route exposes no read-back at
all (every `GET .../skills/{id}/files/SKILL.md` variant returns 404). The only way to catch
it there is to ask the agent in a chat thread to read the file.

**Response plans: use `PUT /api/v2/extendedAgent/incidentFilters/{name}`**, with the filter
fields under `properties`. It is a clean upsert. The `/api/v1/incidentPlayground/filters/{id}`
route is the same object but returns 409 when it already exists, so it needs a delete first
or an edit silently leaves the old routing live.

**Response plans return 409 if they already exist** — delete before PUT, otherwise an edit
appears to succeed while the old routing stays live.

**Knowledge files must go through `POST /api/v1/AgentMemory/upload`** (multipart), not the
`PUT /api/v2/extendedAgent/connectors/{file}` route the reference lab uses. The connector
route is tempting because it is an idempotent upsert and its files *can* be deleted, but on
this agent build it stores the payload as `knowledge_<name>.bin` and the indexer then
rejects it as an unsupported format — `isIndexed` stays `false` permanently and the agent can
never search the content. The multipart upload indexes correctly under the original
filename.

The cost of that choice: **uploaded knowledge files cannot be deleted through the API**
(405 on every variant). Stale uploads have to be removed in the portal. Indexing is also
asynchronous — a file reports `isIndexed=false` with a "could not be indexed" reason for a
few seconds before settling — so the verify step polls before reporting.

**Code Access requires the top-level `name` to equal the `{repoName}` path segment**, or
updates fail with `400 ObjectNameMismatch`. It clones one branch — the script pins it to the
branch you deployed from, overridable with `azd env set GITHUB_BRANCH`.

## Verifying agent configuration

Because so much of this API fails silently, `post-provision.sh` ends by reading the whole
configuration back and printing it. Trust that output over any status code. Skills are
diffed against their source files, and every subagent tool grant is cross-checked against
the live roster.

If you ever need to verify something with no read-back endpoint, create a chat thread and
ask the agent directly:

```bash
curl -X POST "${AGENT_ENDPOINT}/api/v1/threads" -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"title":"probe","startMessage":{"text":"Read the SKILL.md for <skill> and report its section headings, or EMPTY."}}'
```

Then poll `GET /api/v1/threads/{id}/messages`. This is how the empty-skill-body behaviour of
the `/api/v2/agent/skills` route was found; nothing in its REST surface revealed it.

## Azure gotchas

**`AppRoleName` is the Container App name.** Telemetry arrives as `ca-zava-backend-<env>`,
not the container name, and setting `OTEL_SERVICE_NAME` does nothing because the Container
Apps resource detector overrides it. Every KQL query uses
`AppRoleName startswith "ca-zava-backend"`. An equality match on `"zava-backend"` returns
zero rows, so alerts never fire and nothing reports an error. Container console logs are the
exception — they *do* key on the container name.

**Bicep deploys incrementally.** Removing a resource from a template does not delete it from
Azure. The old `alert-zava-oom-*` metric alert kept dispatching to the action group after it
was removed from `sre-agent.bicep` and had to be deleted by hand.

**`infra/fetch-container-image.bicep` exists because `azd provision` alone would otherwise
reset both container apps to the placeholder image** in `main.bicep`, silently replacing the
demo app with `containerapps-helloworld`. It reads the running image back via the
`SERVICE_*_RESOURCE_EXISTS` parameters azd sets.

**The alerts set `skipQueryValidation`** because `AppExceptions` and `AppRequests` do not
exist in a brand-new workspace until the app has sent its first telemetry, which would
otherwise fail deployment.

## Scenario 2 is a runtime 503, not a crash loop

The backend starts successfully with a bad `CATALOG_SOURCE` and returns 503 from the catalog
routes, while `/healthz` stays 200. This is deliberate: a container that crashes on startup
may never take traffic in Container Apps single-revision mode, leaving the previous healthy
revision serving and no visible outage. The runtime-503 path guarantees the fault is visible
while keeping it entirely in Azure configuration.
