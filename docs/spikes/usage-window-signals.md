# Spike #410: usage-window signals in a headless Claude Code session

Observed on Claude Code **2.1.311**, model `claude-sonnet-5-5`, subscription login (no API key), 2026-11-25, on the daemon
machine, with `claude -p "say ok" --output-format stream-json --verbose` run from an empty directory outside any repository.
Feeds #376 (spec `docs/specs/327-parallelism-and-scale.md` §6).

## Candidate sources

| Source | Exists | Fields |
| --- | --- | --- |
| `rate_limit_event` in the stream | yes | see below |
| Statusline input | not observed | not run (see below) |
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

Claude Code documents a statusline command that receives session JSON on stdin. Testing it needed a `statusLine` entry in a
`.claude/settings.json`, which the run's guard rails refuse an agent to write, so it was **not tested**. A statusline is an
interactive-UI feature and is not known to run under `-p`; #376 does not depend on it.

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
