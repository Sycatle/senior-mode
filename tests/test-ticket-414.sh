#!/usr/bin/env bash
# Red skeleton of #414: one case per acceptance criterion. Replace each body with a real test; the ticket is not ready while one says "not implemented" or is skipped.
set -u
failures=0
skeleton() { echo "FAIL: $1: not implemented"; failures=$((failures + 1)); }

# Given no ref `refs/senior-mode/leases/ticket-12`, when two workers claim it at the same moment, then exactly one claim succeeds and the other reads that the lease is held (the loser makes no change).
skeleton Given\ no\ ref\ \`refs/senior-mode/leases/ticket-12\`\,\ when\ two\ workers\ claim\ it\ at\ the\ same\ moment\,\ then\ exactly\ one\ claim\ succeeds\ and\ the\ other\ reads\ that\ the\ lease\ is\ held\ \(the\ loser\ makes\ no\ change\).

# Given a held lease, when its holder renews, then `expires` moves forward in server time and the ref advances by fast-forward; when another worker tries to renew it, then it is refused.
skeleton Given\ a\ held\ lease\,\ when\ its\ holder\ renews\,\ then\ \`expires\`\ moves\ forward\ in\ server\ time\ and\ the\ ref\ advances\ by\ fast-forward\;\ when\ another\ worker\ tries\ to\ renew\ it\,\ then\ it\ is\ refused.

# Given a lease whose `expires` plus the grace is in the past in server time, when a worker takes it over, then one takeover succeeds, the old holder's next renewal is refused, and the takeover is counted from the ref's history.
skeleton Given\ a\ lease\ whose\ \`expires\`\ plus\ the\ grace\ is\ in\ the\ past\ in\ server\ time\,\ when\ a\ worker\ takes\ it\ over\,\ then\ one\ takeover\ succeeds\,\ the\ old\ holder\'s\ next\ renewal\ is\ refused\,\ and\ the\ takeover\ is\ counted\ from\ the\ ref\'s\ history.

# Given a local clock 90 seconds ahead or behind, then expiry decisions use server time (the `Date` header of the API answer) and give the same result as a correct clock; given a measured skew larger than a quarter of the TTL, then claiming is refused with that reason.
skeleton Given\ a\ local\ clock\ 90\ seconds\ ahead\ or\ behind\,\ then\ expiry\ decisions\ use\ server\ time\ \(the\ \`Date\`\ header\ of\ the\ API\ answer\)\ and\ give\ the\ same\ result\ as\ a\ correct\ clock\;\ given\ a\ measured\ skew\ larger\ than\ a\ quarter\ of\ the\ TTL\,\ then\ claiming\ is\ refused\ with\ that\ reason.

# Given a release, then the ref ends in a released state that a new claim can take at once.
skeleton Given\ a\ release\,\ then\ the\ ref\ ends\ in\ a\ released\ state\ that\ a\ new\ claim\ can\ take\ at\ once.

exit "$failures"
