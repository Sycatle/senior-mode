# Spike #410: usage-window signals in a headless Claude Code session

Observed on Claude Code **2.1.311**, model `claude-sonnet-5-5`, subscription login (no API key), 2026-11-25, on the daemon
machine, with `claude -p "say ok" --output-format stream-json --verbose` run from an empty directory outside any repository.
Feeds #376 (spec `docs/specs/327-parallelism-and-scale.md` §6).

## Candidate sources

| Source | Exists | Fields |
| --- | --- | --- |
| `rate_limit_event` in the stream | yes | see below |
| Statusline input | yes, per the changelog (not run) | `rate_limits`: 5-hour and 7-day windows, `used_percentage`, `resets_at` (see below) |
| Final `result` JSON | no | no rate or limit field |
| None | fallback | reactive hold of §6 |

### 1. `rate_limit_event` (stream-json)

One line of `"type":"rate_limit_event"`, emitted after the assistant message and before the final `result` line. It appeared
in both runs made. Captured sample (session ids and uuid dropped):

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795589400,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.2,"resetsAt":1795589400,"status":"allowed"},"seven_day":{"utilization":0.71,"resetsAt":1795777200,"status":"allowed"}}}}
```

- `rate_limit_info.unifiedWindows.five_hour` and `.seven_day`: `utilization` (number), `resetsAt` (Unix seconds), `status`.
- `rate_limit_info.status`, `.rateLimitType` (the window currently binding), `.resetsAt`, `.overageStatus`, `.isUsingOverage`.
- `utilization` is a **fraction of 1**, not a percentage: `0.71` on the seven-day window, whose reset was 2.2 days away
  (about 69% of the week elapsed), matches 71%. `used_percent = utilization * 100`. Only one point was captured, so the
  scale is inferred, not documented: #376 should clamp and treat a value above 1 as already a percentage.
- Both windows are present on a session with a fresh cache and one turn; a session that never reaches the API has no event.
- Not observed: the shape when `status` is `allowed_warning` or `rejected`, or when `unifiedWindows` lacks a window. #376
  reads every field tolerantly (absent window: unknown).

### 2. Statusline input

Claude Code documents a statusline command that receives session JSON on stdin. Running it needed a `statusLine` entry in a
`.claude/settings.json`, which the run's guard rails refuse an agent to write, so it was **not run and no sample was
captured**. What the Claude Code changelog (`~/.claude/cache/changelog.md`, read on 2.1.326) records:

- 2.1.80: "Added `rate_limits` field to statusline scripts for displaying Claude.ai rate limit usage (5-hour and 7-day
  windows with `used_percentage` and `resets_at`)". So the field exists from 2.1.80, hence on 2.1.311. The changelog does not
  give the exact keys of the two windows or the unit of `resets_at`.
- It is only filled for Claude.ai subscribers; a later fix stops it showing a window's pre-reset percentage after the
  window reset while the session was idle (the value is refreshed by API calls, as for the stream event).
- `rate_limits.spend_limit` (`used_usd`, `limit_usd`, `period`) exists only behind a Claude apps gateway: not relevant here.

Nothing in the changelog or in `claude --help` says the statusline command runs under `-p`; it is an interactive-UI feature.
#376 does not depend on it: the stream event (§1) carries the same two windows without a settings entry.

### 3. Final `result` JSON

The last line has `usage`, `modelUsage`, `total_cost_usd`, `duration_*` and others, with no rate-limit, window or reset
field. Tokens used are there, so the estimate fallback of §6 can be fed from it.

## Decision for #376

- **First source: the `rate_limit_event` of the stream.** The runner already uses `stream-json` per session, so it needs no
  extra call. Keep the last event per poll, write `{window, used_percent, resets_at, observed_at}` for each of the two
  windows (`observed_at` = the time the line was read, since the event carries none), and apply the 15-minute staleness rule.
- **Fallback when no event is seen** (older Claude Code, API-key login, a session that errored before the API): the reactive
  hold (`serve_limit`) and the token estimate of §6, with "no usage signal" logged once an hour.

## Account-wide or per session

`utilization` is the subscription's window, not the session's: two separate sessions started a few seconds apart returned
identical values for both windows, including a session that used tokens in between, and the 5-hour and 7-day windows are
defined by the subscription. It is therefore **account-wide**, shared by every machine on the subscription, which matches
§6. Not verified from a second machine, and the value is refreshed only when a session makes an API call, so an idle
machine reads the last event it saw, hence the staleness rule.
