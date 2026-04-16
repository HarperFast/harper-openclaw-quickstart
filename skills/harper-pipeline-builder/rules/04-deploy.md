# Step 4: Deploy

**Goal:** get the scaffolded component running on the Harper cluster.

## Two deploy paths — pick one

### Path A: git URL (preferred)

1. `cd` into `<workspace>/harper-pipelines/<PIPELINE_ID>/`
2. `git init`, `git add .`, `git commit -m "pipeline: <PIPELINE_ID>"`
3. Push to `$GIT_REMOTE_DEFAULT` under a branch or subfolder convention. If the remote is a monorepo, push to `pipelines/<PIPELINE_ID>/` on main; if each pipeline is its own repo, create the repo via the GitHub API (`POST /user/repos`) then push.
4. Tag the commit: `git tag v0.1.0 && git push --tags`.
5. Call the Harper operations API to deploy:

```bash
curl -sS -u $HARPER_USERNAME:$HARPER_PASSWORD \
     -H 'Content-Type: application/json' \
     -d '{
           "operation": "deploy_component",
           "project": "<PIPELINE_ID>",
           "package": "<org>/<repo>#semver:v0.1.0",
           "restart": "rolling",
           "replicated": true
         }' \
     $HARPER_URL
```

The Harper cluster pulls the git URL, runs `npm install`, and rolls the new component out.

### Path B: tar payload (when you don't have a git remote)

1. `tar -cf /tmp/<PIPELINE_ID>.tar -C <workspace>/harper-pipelines <PIPELINE_ID>`
2. `base64 < /tmp/<PIPELINE_ID>.tar` → capture as `$PAYLOAD`
3. POST to `deploy_component` with `payload: $PAYLOAD` instead of `package`.

Use Path A unless you have a reason not to. Path A gives you auditable history.

## Verifying the deploy started

The `deploy_component` call returns immediately on success:

```json
{ "message": "Successfully deployed: <PIPELINE_ID>" }
```

That means "Harper accepted the deploy" — not "the pipeline is running." You confirm the latter in step 5.

## If the deploy fails

Common failures and fixes:

| Error | Cause | Fix |
|---|---|---|
| `404 from npm install` | git URL wrong or repo private without SSH | check `$GIT_REMOTE_DEFAULT`; for private repos use `add_ssh_key` first |
| `SyntaxError in resources.js` | template not fully rendered | re-run step 3 validation; unrendered `{{` will fail `node --check` |
| `Cannot find module 'cron-parser'` | dependencies not installed | Harper runs `npm install` automatically; if it didn't, check cluster logs |
| `403 from deploy_component` | the user you're using isn't super_user | cluster owner needs to grant super_user to the agent's credentials |

Never retry a deploy more than twice. On the third failure, file a `pending_human_action` with `blocker: "other"` and the error detail.

## Don't restart on every deploy in production

In production, once a cluster has many pipelines, `restart: "rolling"` still briefly interrupts all of them. For iterative agent work, `restart: "rolling"` is fine. For high-volume clusters, the cluster owner should set up a dedicated "pipeline worker" node pool and target that.
