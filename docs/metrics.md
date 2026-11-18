# Metrics in Datadog

With `datadog-api-key` (as in [Usage](../README.md#usage)), every run sends metrics to Datadog at the end of the job,
including runs that skip a draft, a Dependabot pull request or a decision record. Without it, none
are sent. A run Dependabot starts, including one that skips its pull request, only gets the secrets
under *Dependabot*, so it only sends metrics where `DATADOG_API_KEY` is a Dependabot secret too
(see [CI Bootstrapping](bootstrapping.md#3-add-the-secrets-to-both-organisations)). They go to
Articore's Datadog site, US1 (`api.datadoghq.com`).

| Metric | Type | What it is |
| --- | --- | --- |
| `github.actions.claude_review.runs` | count | 1 per run |
| `github.actions.claude_review.duration.total` | distribution | Seconds from the job's start to the end of the last step |
| `github.actions.claude_review.billed_minutes` | count | The runner minutes GitHub bills for the job, estimated |
| `github.actions.claude_review.duration.claude` | distribution | Seconds Claude spent on the review |
| `github.actions.claude_review.cost_usd` | distribution | The review's cost, the same estimate as the cost line |
| `github.actions.claude_review.tokens` | count | Tokens, by `token_type`: `input`, `output`, `cache_write`, `cache_read` |

Every metric is tagged with `repo`, `model`, `trigger` (`auto`, `label` for a run from a label
being added, or `rerun`) and `outcome`: `success`, `failure`, `cancelled`, `not_started` (an
earlier step failed or the run was cancelled before the review started), `skipped_draft`,
`skipped_dependabot` or `skipped_adr`. Once the pull request has been read, they're also tagged
with `author_type`, `bot` or `human`, for who opened it, and, for a bot, `bot` with its name
without `[bot]`, such as `bot:dependabot`. A human's login isn't sent. Skipped runs send `runs`, `duration.total` and `billed_minutes` only. The time
spent outside the review is `duration.total` minus `duration.claude`. The total leaves out the post-job cleanup
after the last step, usually 2 to 4 seconds. GitHub bills each job in whole minutes, rounded up,
so `billed_minutes` adds 3 seconds to the total before rounding up. It's a minute short for a job
that ends within a few seconds of a minute, and right for the rest.

A review that fails after Claude returns a result, such as running out of turns, still sends its
cost, time and tokens, tagged `outcome:failure`. Runs cancelled during the review, or that fail
before Claude returns a result, send no cost, though Anthropic still charges for them. For the
real cost of all reviews, see the API key's usage in the Anthropic Console.
