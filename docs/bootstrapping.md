# CI Bootstrapping

In order to access repositories (read only access) in both our orgs, we need to create and install
a custom GH app. You'll need an org admin in each organisation for that.

## 1. The review GitHub App

The app already exists and is owned by the **teepublic** organisation:
**[claude-code-review-org-reader](https://github.com/organizations/teepublic/settings/apps/claude-code-review-org-reader)**
(settings, for teepublic owners and app managers; public page:
https://github.com/apps/claude-code-review-org-reader). It can't be moved to redbubble while it's
public, and it has to be public to be installed on both organisations.

The table below is how it's configured, for reference or if it ever needs recreating via
*Settings → Developer settings → GitHub Apps → New GitHub App*.

| Setting | Value |
| --- | --- |
| Webhook | Uncheck *Active* |
| Repository permissions | **Contents: Read-only** · **Metadata: Read-only** (mandatory) · **Pull requests: Read-only** · **Issues: Read-only** |
| Organization and account permissions | None |
| Where can this GitHub App be installed? | **Any account**, so it can be installed on both organisations |

After creating it:

1. Copy the **Client ID** from its settings page into both `client-id:` lines of
   [`action.yml`](../action.yml). The ID isn't secret.
2. Under *Private keys*, **generate a private key**. This downloads a `.pem` file: you'll store it
   as a secret in step 3, then delete the local file.

The app never posts anything: comments use each run's `GITHUB_TOKEN`.

## 2. Install the app on both organisations

From the [app's public page](https://github.com/apps/claude-code-review-org-reader), install it
on **redbubble** and on **teepublic**, choosing **All repositories** for each. That lets Claude
read any repository a PR refers to, and the redbubble installation covers
redbubble/claude-code-reviews-rules, which every review reads the rules from.

## 3. Add the secrets to both organisations

In **each** of redbubble and teepublic: *Settings → Secrets and variables → Actions →
New organization secret*:

| Name | Value |
| --- | --- |
| `REVIEW_APP_PRIVATE_KEY` | The whole contents of the `.pem` file, including the `BEGIN`/`END` lines |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `DATADOG_API_KEY` | Datadog API key for the review's metrics, used only for them. Optional. |

For *Repository access*, choose the repositories that use the review (or all private
repositories).

Repositories that set `review-dependabot` also need the secrets under *Secrets and variables →
Dependabot*: Dependabot's runs can't read Actions secrets, so without them every Dependabot review
fails. Dependabot pull requests are skipped by default, and a review asked for with the label
uses the Actions secrets (see [Reviewing Dependabot pull requests](dependabot.md)).

To count those skips in Datadog, add `DATADOG_API_KEY` under *Dependabot* as well, for every
repository that sends metrics. It's the only one a skip needs: it never reaches Claude, and it can
only send data to Datadog, not read it.

## 4. Allow the actions

If an organisation restricts which actions can run (*Settings → Actions → General*), allow
`redbubble/claude-code-reviews`, `anthropics/claude-code-action`,
`actions/create-github-app-token` and `actions/checkout`. Repositories using the
[reusable workflow](configuration.md#the-reusable-workflow-redbubble-only) also need
`redbubble/claude-code-reviews/.github/workflows/review.yml` allowed.

## 5. Atlassian service account

For `atlassian-read`. An Atlassian organisation admin sets this up in admin.atlassian.com.

1. **A group for its access**: under *Directory → Groups*, create `claude-review-readers`. Give
   it *Browse Projects* in the Jira permission schemes of the projects reviews should read, and
   *View* in the Confluence spaces they should read. Leave out restricted spaces: whatever this
   group can see may end up summarised in a PR comment.
2. **The service account**: *Directory → Service accounts → Create a service account*, named
   e.g. `claudecodereview`, with a description naming its owner and this repository. Give it
   Jira and Confluence access with the basic user role, and add it to `claude-review-readers`.
3. **Its OAuth credential**: on the service account, *Create credentials → OAuth 2.0*, with
   exactly the scopes `read:jira-work` and `read:page:confluence` (a granular scope: search for
   it). Scopes can't be changed after it's created. Copy the client ID and client secret: they're
   shown once. The client ID isn't secret: put it in the `CLIENT_ID:` line of
   [`action.yml`](../action.yml).
4. **Check it**, with an issue and a page the group can see. Get an access token, then read
   both with it. 401 means a wrong scope, and 404 a wrong cloud ID or no access to that issue or
   page:

   ```sh
   curl -X POST https://auth.atlassian.com/oauth/token -d grant_type=client_credentials -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET"
   curl -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.atlassian.com/ex/jira/<cloud ID>/rest/api/3/issue/PROJ-123?fields=summary"
   curl -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.atlassian.com/ex/confluence/<cloud ID>/wiki/api/v2/pages/<page ID>"
   ```

   The cloud ID is in `atlassian-read`, or at `https://<site>.atlassian.net/_edge/tenant_info`.
5. **Store the client secret** in each of redbubble and teepublic as the organisation secret
   `ATLASSIAN_CLIENT_SECRET` (and under *Dependabot*, as in step 3).
6. **To replace it** (it may have leaked, or its owner left): create a new credential, update
   the secret in both organisations and the client ID in `action.yml`, then revoke the old one.
   Repositories that follow `master` get the new client ID on their next review.
