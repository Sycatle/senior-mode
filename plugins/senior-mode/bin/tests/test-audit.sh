#!/usr/bin/env bash
# Tests for the dependency audit of `senior-mode check` (#142): the audit tool of the lockfile at the root
# runs, high and critical advisories fail it, an advisory without a severity is a warning, a missing tool
# fails and `audit: false` turns it off. Offline: the tools are stubs that print the fixtures below, shaped
# like the output of npm 11, pnpm 12, pip-audit 2.10, govulncheck 1.10 and cargo-audit 0.22.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix"
cat >"$work/stub/audit-tool" <<'STUB'
#!/usr/bin/env bash
name=$(basename "$0")
echo "$name $*" >>"$AUDIT_LOG"
[ ! -f "$FIX/$name.sleep" ] || sleep "$(cat "$FIX/$name.sleep")"
cat "$FIX/$name.json"
exit "$(cat "$FIX/$name.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$work/stub/audit-tool"
for t in npm pnpm pip-audit govulncheck cargo cargo-audit; do ln -s audit-tool "$work/stub/$t"; done
export PATH="$work/stub:$PATH" AUDIT_LOG="$work/audit.log" FIX="$work/fix"

# npm audit --json: one entry per vulnerable package; its `via` holds the advisories (objects) and the
# packages it is vulnerable through (strings).
cat >"$work/fix/npm-critical.json" <<'JSON'
{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "minimist": {
      "name": "minimist",
      "severity": "critical",
      "isDirect": true,
      "via": [
        {
          "source": 1096465,
          "name": "minimist",
          "dependency": "minimist",
          "title": "Prototype Pollution in minimist",
          "url": "https://github.com/advisories/GHSA-vh95-rmgr-6w4m",
          "severity": "moderate",
          "cwe": ["CWE-1321"],
          "cvss": { "score": 5.6, "vectorString": "CVSS:3.1/AV:N/AC:H/PR:N/UI:N/S:U/C:L/I:L/A:L" },
          "range": ">=1.0.0 <1.2.3"
        },
        {
          "source": 1097678,
          "name": "minimist",
          "dependency": "minimist",
          "title": "Prototype Pollution in minimist",
          "url": "https://github.com/advisories/GHSA-xvch-5gv4-984h",
          "severity": "critical",
          "cwe": ["CWE-1321"],
          "cvss": { "score": 9.8, "vectorString": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" },
          "range": ">=1.0.0 <1.2.6"
        }
      ],
      "effects": ["mkdirp"],
      "range": "1.0.0 - 1.2.5",
      "nodes": ["node_modules/minimist"],
      "fixAvailable": { "name": "minimist", "version": "1.2.8", "isSemVerMajor": false }
    },
    "mkdirp": {
      "name": "mkdirp",
      "severity": "critical",
      "isDirect": false,
      "via": ["minimist"],
      "effects": [],
      "range": "0.4.1 - 0.5.1",
      "nodes": ["node_modules/mkdirp"],
      "fixAvailable": { "name": "mkdirp", "version": "1.0.4", "isSemVerMajor": true }
    }
  },
  "metadata": { "vulnerabilities": { "info": 0, "low": 0, "moderate": 1, "high": 0, "critical": 2, "total": 3 } }
}
JSON
# Only a moderate advisory, with no fix.
cat >"$work/fix/npm-moderate.json" <<'JSON'
{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "semver": {
      "name": "semver",
      "severity": "moderate",
      "isDirect": false,
      "via": [
        {
          "source": 1101088,
          "name": "semver",
          "dependency": "semver",
          "title": "semver vulnerable to Regular Expression Denial of Service",
          "url": "https://github.com/advisories/GHSA-c2qf-rxjj-qqgw",
          "severity": "moderate",
          "range": ">=7.0.0 <7.5.2"
        }
      ],
      "effects": [],
      "range": "7.0.0 - 7.5.1",
      "nodes": ["node_modules/semver"],
      "fixAvailable": false
    }
  },
  "metadata": { "vulnerabilities": { "info": 0, "low": 0, "moderate": 1, "high": 0, "critical": 0, "total": 1 } }
}
JSON
echo '{"auditReportVersion": 2, "vulnerabilities": {}, "metadata": {"vulnerabilities": {"total": 0}}}' >"$work/fix/npm-clean.json"
# npm cannot reach the registry.
echo '{"error": {"code": "ENOTFOUND", "summary": "request to https://registry.npmjs.org failed", "detail": ""}}' >"$work/fix/npm-error.json"

# pnpm audit --json: advisories by id, with the patched range.
cat >"$work/fix/pnpm-critical.json" <<'JSON'
{
  "advisories": {
    "1096465": {
      "findings": [{ "version": "1.2.0", "paths": [".>minimist"], "dev": false, "optional": false, "bundled": false }],
      "id": 1096465,
      "title": "Prototype Pollution in minimist",
      "module_name": "minimist",
      "vulnerable_versions": ">=1.0.0 <1.2.3",
      "patched_versions": ">=1.2.3",
      "severity": "moderate",
      "cwe": "CWE-1321",
      "github_advisory_id": "GHSA-vh95-rmgr-6w4m",
      "url": "https://github.com/advisories/GHSA-vh95-rmgr-6w4m"
    },
    "1097678": {
      "findings": [{ "version": "1.2.0", "paths": [".>minimist"], "dev": false, "optional": false, "bundled": false }],
      "id": 1097678,
      "title": "Prototype Pollution in minimist",
      "module_name": "minimist",
      "vulnerable_versions": ">=1.0.0 <1.2.6",
      "patched_versions": ">=1.2.6",
      "severity": "critical",
      "cwe": "CWE-1321",
      "github_advisory_id": "GHSA-xvch-5gv4-984h",
      "url": "https://github.com/advisories/GHSA-xvch-5gv4-984h"
    }
  },
  "metadata": {
    "vulnerabilities": { "info": 0, "low": 0, "moderate": 1, "high": 0, "critical": 1 },
    "dependencies": 1, "devDependencies": 0, "optionalDependencies": 0, "totalDependencies": 1
  }
}
JSON

# pip-audit -f json: no severity, and an advisory listed once per occurrence of the package.
cat >"$work/fix/pip-audit-vulns.json" <<'JSON'
{
  "dependencies": [
    {
      "name": "flask",
      "version": "0.5",
      "vulns": [
        { "id": "PYSEC-2019-179", "fix_versions": ["1.0"], "aliases": ["CVE-2019-1010083", "GHSA-5wv5-4vpf-pj6m"], "description": "The Python Flask framework before 1.0 is vulnerable." },
        { "id": "PYSEC-2019-179", "fix_versions": ["1.0"], "aliases": ["CVE-2019-1010083", "GHSA-5wv5-4vpf-pj6m"], "description": "The Python Flask framework before 1.0 is vulnerable." },
        { "id": "PYSEC-2023-62", "fix_versions": ["2.2.5", "2.3.2"], "aliases": ["GHSA-m2qf-hxjv-5gpq", "CVE-2023-30861"], "description": "Flask is a lightweight WSGI web application framework." }
      ]
    },
    { "name": "click", "version": "8.1.7", "vulns": [] }
  ],
  "fixes": []
}
JSON

# govulncheck -json: a stream of messages. GO-2021-0113 is called by the code (the first frame of its
# trace names a function), GO-2022-1059 is only required by a module the code imports.
cat >"$work/fix/govulncheck-called.json" <<'JSON'
{
  "config": {
    "protocol_version": "v1.0.0",
    "scanner_name": "govulncheck",
    "scanner_version": "v1.10.0",
    "db": "https://vuln.go.dev",
    "go_version": "go1.23.6",
    "scan_level": "symbol",
    "scan_mode": "source"
  }
}
{
  "progress": {
    "message": "Scanning your code and 41 packages across 1 dependent module for known vulnerabilities..."
  }
}
{
  "osv": {
    "schema_version": "1.3.1",
    "id": "GO-2021-0113",
    "aliases": ["CVE-2021-38561", "GHSA-ppp9-7jff-5vj2"],
    "summary": "Out-of-bounds read in golang.org/x/text/language",
    "affected": [
      {
        "package": { "name": "golang.org/x/text", "ecosystem": "Go" },
        "ranges": [{ "type": "SEMVER", "events": [{ "introduced": "0" }, { "fixed": "0.3.7" }] }]
      }
    ],
    "database_specific": { "url": "https://pkg.go.dev/vuln/GO-2021-0113", "review_status": "REVIEWED" }
  }
}
{
  "osv": {
    "schema_version": "1.3.1",
    "id": "GO-2022-1059",
    "aliases": ["CVE-2022-32149", "GHSA-69ch-w2m2-3vjp"],
    "summary": "Denial of service via crafted Accept-Language header in golang.org/x/text/language",
    "affected": [
      {
        "package": { "name": "golang.org/x/text", "ecosystem": "Go" },
        "ranges": [{ "type": "SEMVER", "events": [{ "introduced": "0" }, { "fixed": "0.3.8" }] }]
      }
    ],
    "database_specific": { "url": "https://pkg.go.dev/vuln/GO-2022-1059", "review_status": "REVIEWED" }
  }
}
{
  "finding": {
    "osv": "GO-2021-0113",
    "fixed_version": "v0.3.7",
    "trace": [{ "module": "golang.org/x/text", "version": "v0.3.5" }]
  }
}
{
  "finding": {
    "osv": "GO-2021-0113",
    "fixed_version": "v0.3.7",
    "trace": [
      { "module": "golang.org/x/text", "version": "v0.3.5", "package": "golang.org/x/text/language", "function": "Parse", "position": { "filename": "language/parse.go", "offset": 1, "line": 10, "column": 6 } },
      { "module": "example.com/t", "package": "example.com/t", "function": "main", "position": { "filename": "main.go", "offset": 1, "line": 10, "column": 2 } }
    ]
  }
}
{
  "finding": {
    "osv": "GO-2022-1059",
    "fixed_version": "v0.3.8",
    "trace": [{ "module": "golang.org/x/text", "version": "v0.3.5" }]
  }
}
JSON
# Nothing called: the findings stay at the module level.
jq -c 'select(.finding | not) // select(.finding.trace | length == 1)' \
  "$work/fix/govulncheck-called.json" >"$work/fix/govulncheck-quiet.json"

# pip-audit skips a dependency it cannot audit (a local path, -e, a package the index does not know): the
# entry has a skip_reason and no vulns.
cat >"$work/fix/pip-audit-skipped.json" <<'JSON'
{
  "dependencies": [
    { "name": "flask", "version": "0.5", "vulns": [
      { "id": "PYSEC-2019-179", "fix_versions": ["1.0"], "aliases": ["CVE-2019-1010083"], "description": "Flask before 1.0." } ] },
    { "name": "loc", "skip_reason": "Dependency not found on PyPI and could not be audited: loc (0.1)" },
    { "name": "mylib", "skip_reason": "Dependency has no version specified" }
  ],
  "fixes": []
}
JSON
jq '.dependencies |= map(select(.skip_reason))' "$work/fix/pip-audit-skipped.json" >"$work/fix/pip-audit-onlyskipped.json"

# cargo audit --json: no severity, only a CVSS vector.
cat >"$work/fix/cargo-vulns.json" <<'JSON'
{
  "database": { "advisory-count": 900, "last-commit": "0123", "last-updated": "2026-11-10T00:00:00+01:00" },
  "lockfile": { "dependency-count": 5 },
  "settings": { "target_arch": [], "target_os": [], "severity": null, "ignore": [], "informational_warnings": ["unmaintained"] },
  "vulnerabilities": {
    "found": true,
    "count": 1,
    "list": [
      {
        "advisory": {
          "id": "RUSTSEC-2020-0071",
          "package": "time",
          "title": "Potential segfault in the time crate",
          "description": "Unix-like operating systems may segfault due to dereferencing a dangling pointer.",
          "date": "2020-11-18",
          "aliases": ["CVE-2020-26235", "GHSA-wcg3-cvx6-7396"],
          "categories": ["code-execution", "memory-corruption"],
          "cvss": "CVSS:3.1/AV:L/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H",
          "informational": null,
          "url": "https://github.com/time-rs/time/issues/293",
          "withdrawn": null
        },
        "versions": { "patched": [">=0.2.23"], "unaffected": ["=0.2.0", "=0.2.1"] },
        "affected": { "arch": [], "os": ["linux"], "functions": { "time::now": ["^0.1"] } },
        "package": { "name": "time", "version": "0.1.43", "source": "registry+https://github.com/rust-lang/crates.io-index", "dependencies": [] }
      }
    ]
  },
  "warnings": {}
}
JSON
echo '{"lockfile": {"dependency-count": 5}, "vulnerabilities": {"found": false, "count": 0, "list": []}, "warnings": {}}' >"$work/fix/cargo-clean.json"

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: base"
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
run() { (cd "$repo" && "$cli" check) >"$work/out" 2>&1; }
# lock <lockfile>: the only lockfile of the repository, and no tool has run.
lock() {
  rm -f "$repo/package-lock.json" "$repo/pnpm-lock.yaml" "$repo/requirements.txt" "$repo/go.sum" "$repo/Cargo.lock" \
    "$work"/fix/*.rc "$work"/fix/*.sleep
  : >"$AUDIT_LOG"
  [ -z "$1" ] || echo x >"$repo/$1"
}
# use <tool> <fixture>: what the tool prints.
use() { cp "$work/fix/$2.json" "$work/fix/$1.json"; }
# without <tool>: a PATH on which the tool is missing, whatever the machine has installed.
without() {
  local d f out="$work/path-without-$1" IFS=:
  mkdir -p "$out"
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ "${f##*/}" = "$1" ] || [ -e "$out/${f##*/}" ] || ln -s "$f" "$out/${f##*/}"
    done
  done
  printf '%s\n' "$out"
}

config '{"checks": [{"name": "lint", "run": "true"}]}'
# No lockfile: nothing to audit, and it says so.
lock ""
run || fail "no lockfile: the check fails: $(cat "$work/out")"
grep -q "^skip  dependency audit: no lockfile" "$work/out" || fail "no lockfile: not shown as skipped: $(cat "$work/out")"
[ ! -s "$AUDIT_LOG" ] || fail "no lockfile: a tool ran: $(cat "$AUDIT_LOG")"
grep -q "6/6 checks passed" "$work/out" || fail "no lockfile: summary: $(cat "$work/out")"

# npm: a critical advisory fails the check, naming the package, the advisory and the fixed version; the
# moderate one is a warning.
lock package-lock.json
use npm npm-critical
run && fail "npm: a critical advisory passes"
grep -qx "npm audit --json" "$AUDIT_LOG" || fail "npm: wrong command: $(cat "$AUDIT_LOG")"
grep -q "^FAIL  dependency audit ([0-9.]*s)$" "$work/out" || fail "npm: audit not reported as failed: $(cat "$work/out")"
grep -qE "critical: minimist GHSA-xvch-5gv4-984h, fixed in 1.2.8" "$work/out" || fail "npm: package, advisory and fix not named: $(cat "$work/out")"
grep -qE "warning: moderate: minimist GHSA-vh95-rmgr-6w4m, fixed in 1.2.8" "$work/out" || fail "npm: moderate advisory not a warning: $(cat "$work/out")"
grep -q "GHSA-vh95-rmgr-6w4m" <(grep -v warning "$work/out") && fail "npm: the moderate advisory blocks"
grep -q "mkdirp" "$work/out" && fail "npm: a package vulnerable through another is listed as an advisory: $(cat "$work/out")"
grep -q "failed: dependency audit" "$work/out" || fail "npm: summary: $(cat "$work/out")"

# A high advisory blocks as well; the fix is the package to update when it is another one.
jq '.vulnerabilities.mkdirp.via = [{"source": 1, "name": "mkdirp", "title": "t", "url": "https://github.com/advisories/GHSA-aaaa-bbbb-cccc", "severity": "high"}]
  | .vulnerabilities.minimist.via = []' "$work/fix/npm-critical.json" >"$work/fix/npm.json"
run && fail "npm: a high advisory passes"
grep -qE "high: mkdirp GHSA-aaaa-bbbb-cccc, fixed in 1.0.4" "$work/out" || fail "npm: high advisory not named: $(cat "$work/out")"

# Moderate only: it passes, and shows the advisory as a warning; no fix is said so.
use npm npm-moderate
run || fail "npm: a moderate advisory fails: $(cat "$work/out")"
grep -q "^ok    dependency audit ([0-9.]*s)$" "$work/out" || fail "npm: moderate: not ok: $(cat "$work/out")"
grep -qE "warning: moderate: semver GHSA-c2qf-rxjj-qqgw, no fixed version" "$work/out" || fail "npm: moderate not shown: $(cat "$work/out")"

use npm npm-clean
run || fail "npm: a clean audit fails: $(cat "$work/out")"
grep -q "^ok    dependency audit ([0-9.]*s)$" "$work/out" || fail "npm: clean: not ok: $(cat "$work/out")"
grep -q "warning" "$work/out" && fail "npm: clean audit warns: $(cat "$work/out")"

# A tool that cannot answer (no network) fails the check: nothing was audited.
use npm npm-error
echo 1 >"$work/fix/npm.rc"
run && fail "npm: an error answer passes"
grep -q "^FAIL  dependency audit ([0-9.]*s)$" "$work/out" || fail "npm: error not reported: $(cat "$work/out")"
grep -q "registry.npmjs.org" "$work/out" || fail "npm: the reason is lost: $(cat "$work/out")"
: >"$work/fix/npm.json"
run && fail "npm: an empty answer passes"
grep -q "^FAIL  dependency audit ([0-9.]*s)$" "$work/out" || fail "npm: empty answer not reported: $(cat "$work/out")"
grep -q "the tool gave no output" "$work/out" || fail "npm: no reason given for an empty answer: $(cat "$work/out")"
grep -qE "^ +$" "$work/out" && fail "npm: a blank reason line: $(cat "$work/out" | cat -A | head -20)"
use npm npm-clean

# pnpm, when its lockfile is there (before npm's).
lock pnpm-lock.yaml
echo x >"$repo/package-lock.json"
use pnpm pnpm-critical
run && fail "pnpm: a critical advisory passes"
grep -qx "pnpm audit --json" "$AUDIT_LOG" || fail "pnpm: wrong command: $(cat "$AUDIT_LOG")"
grep -q "^npm" "$AUDIT_LOG" && fail "pnpm: npm ran as well"
grep -qE "critical: minimist GHSA-xvch-5gv4-984h, fixed in >=1.2.6" "$work/out" || fail "pnpm: package, advisory and fix not named: $(cat "$work/out")"
grep -qE "warning: moderate: minimist GHSA-vh95-rmgr-6w4m" "$work/out" || fail "pnpm: moderate not a warning: $(cat "$work/out")"

# A failing audit shows every blocking advisory, not the last 20 lines; a very long list is capped.
many() { # <count>: that many critical advisories, as pnpm prints them
  jq -nc --argjson n "$1" '{advisories: ([range($n)] | map({key: "\(.)", value: {id: ., title: "t", module_name: "pkg\(.)",
    patched_versions: ">=2.0.0", severity: "critical", github_advisory_id: "GHSA-\(.)"}}) | from_entries)}'
}
lock pnpm-lock.yaml
many 30 >"$work/fix/pnpm.json"
run && fail "many: 30 critical advisories pass"
for i in 0 15 29; do
  grep -qF "critical: pkg$i GHSA-$i, fixed in >=2.0.0" "$work/out" || fail "many: advisory $i is not shown: $(tail -n 5 "$work/out")"
done
many 130 >"$work/fix/pnpm.json"
run && fail "many: 130 critical advisories pass"
[ "$(grep -c "critical: pkg" "$work/out")" -eq 100 ] || fail "many: $(grep -c "critical: pkg" "$work/out") advisories shown, wanted the cap of 100"
grep -qF "... 30 more blocking advisories" "$work/out" || fail "many: the cap is not said: $(tail -n 5 "$work/out")"
use pnpm pnpm-critical

# A tool that hangs is stopped by `timeout` when there is one, and the check says so.
if command -v timeout >/dev/null; then
  lock package-lock.json
  use npm npm-clean
  echo 5 >"$work/fix/npm.sleep"
  (cd "$repo" && SENIOR_MODE_AUDIT_TIMEOUT=1 "$cli" check) >"$work/out" 2>&1 && fail "timeout: a hanging audit passes"
  grep -q "^FAIL  dependency audit ([0-9.]*s)$" "$work/out" || fail "timeout: not reported: $(cat "$work/out")"
  grep -q "timed out after 1 s" "$work/out" || fail "timeout: not said: $(cat "$work/out")"
fi

# pip: no severity, so the advisories are warnings, once each; the check passes.
lock requirements.txt
use pip-audit pip-audit-vulns
run || fail "pip: advisories without a severity fail: $(cat "$work/out")"
grep -qx "pip-audit -r requirements.txt -f json" "$AUDIT_LOG" || fail "pip: wrong command: $(cat "$AUDIT_LOG")"
grep -q "^ok    dependency audit ([0-9.]*s)$" "$work/out" || fail "pip: not ok: $(cat "$work/out")"
grep -qE "warning: no severity: flask PYSEC-2019-179, fixed in 1.0$" "$work/out" || fail "pip: warning missing: $(cat "$work/out")"
grep -qE "warning: no severity: flask PYSEC-2023-62, fixed in 2.2.5, 2.3.2$" "$work/out" || fail "pip: fixed versions: $(cat "$work/out")"
[ "$(grep -c PYSEC-2019-179 "$work/out")" -eq 1 ] || fail "pip: a repeated advisory is listed twice: $(cat "$work/out")"
# The older pip-audit prints the list itself.
jq '.dependencies' "$work/fix/pip-audit-vulns.json" >"$work/fix/pip-audit-old.json"
use pip-audit pip-audit-old
run || fail "pip: the list format fails: $(cat "$work/out")"
grep -q "warning: no severity: flask PYSEC-2023-62" "$work/out" || fail "pip: the list format is not read: $(cat "$work/out")"
use pip-audit pip-audit-vulns

# A dependency pip-audit skipped is a warning, not an unusable answer.
use pip-audit pip-audit-skipped
run || fail "pip: a skipped dependency fails the audit: $(cat "$work/out")"
grep -q "^ok    dependency audit ([0-9.]*s)$" "$work/out" || fail "pip: skipped: not ok: $(cat "$work/out")"
grep -qF "warning: not audited: loc (Dependency not found on PyPI and could not be audited: loc (0.1))" "$work/out" ||
  fail "pip: a skipped dependency is not shown: $(cat "$work/out")"
grep -qF "warning: not audited: mylib (Dependency has no version specified)" "$work/out" || fail "pip: second skipped dependency: $(cat "$work/out")"
grep -qE "warning: no severity: flask PYSEC-2019-179, fixed in 1.0$" "$work/out" || fail "pip: the advisories next to a skipped dependency are lost: $(cat "$work/out")"
use pip-audit pip-audit-onlyskipped
run || fail "pip: only skipped dependencies fail the audit: $(cat "$work/out")"
use pip-audit pip-audit-vulns

# go: a called vulnerability is a warning (no severity); one that is only required is not reported.
lock go.sum
use govulncheck govulncheck-called
run || fail "go: advisories without a severity fail: $(cat "$work/out")"
grep -qx "govulncheck -json ./..." "$AUDIT_LOG" || fail "go: wrong command: $(cat "$AUDIT_LOG")"
grep -qE "warning: no severity: golang.org/x/text GO-2021-0113, fixed in v0.3.7$" "$work/out" || fail "go: warning missing: $(cat "$work/out")"
grep -q "GO-2022-1059" "$work/out" && fail "go: a vulnerability the code does not call is reported: $(cat "$work/out")"
use govulncheck govulncheck-quiet
run || fail "go: nothing called fails: $(cat "$work/out")"
grep -q warning "$work/out" && fail "go: nothing called warns: $(cat "$work/out")"
use govulncheck govulncheck-called
echo 2 >"$work/fix/govulncheck.rc"
run && fail "go: a failing govulncheck passes"
grep -q "^FAIL  dependency audit ([0-9.]*s)$" "$work/out" || fail "go: failure not reported: $(cat "$work/out")"
rm -f "$work/fix/govulncheck.rc"

# cargo
lock Cargo.lock
use cargo cargo-vulns
echo 1 >"$work/fix/cargo.rc"
run || fail "cargo: advisories without a severity fail: $(cat "$work/out")"
grep -qx "cargo audit --json" "$AUDIT_LOG" || fail "cargo: wrong command: $(cat "$AUDIT_LOG")"
grep -qE "warning: no severity: time RUSTSEC-2020-0071, fixed in >=0.2.23$" "$work/out" || fail "cargo: warning missing: $(cat "$work/out")"
use cargo cargo-clean
run || fail "cargo: a clean audit fails: $(cat "$work/out")"
grep -q "^ok    dependency audit ([0-9.]*s)$" "$work/out" || fail "cargo: clean: not ok: $(cat "$work/out")"

# A missing tool fails the check and says how to install it.
missing() { # <lockfile> <binary> <text of the install hint>
  lock "$1"
  (cd "$repo" && PATH=$(without "$2") "$cli" check) >"$work/out" 2>&1 && fail "$2 missing: the check passes"
  grep -q "^FAIL  dependency audit ([0-9.]*s)$" "$work/out" || fail "$2 missing: not reported: $(cat "$work/out")"
  grep -q "$2 not installed" "$work/out" || fail "$2 missing: not named: $(cat "$work/out")"
  grep -qF -- "$3" "$work/out" || fail "$2 missing: no install hint '$3': $(cat "$work/out")"
}
missing package-lock.json npm "https://nodejs.org"
missing pnpm-lock.yaml pnpm "npm install -g pnpm"
missing requirements.txt pip-audit "pipx install pip-audit"
missing go.sum govulncheck "go install golang.org/x/vuln/cmd/govulncheck@latest"
missing Cargo.lock cargo-audit "cargo install cargo-audit --locked"

# audit: false turns it off: nothing runs, a missing tool is no matter, and the check says so.
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}]}'
lock package-lock.json
use npm npm-critical
run || fail "audit false: the check fails: $(cat "$work/out")"
grep -q "^skip  dependency audit: off (audit: false)" "$work/out" || fail "audit false: not shown as off: $(cat "$work/out")"
[ ! -s "$AUDIT_LOG" ] || fail "audit false: a tool ran: $(cat "$AUDIT_LOG")"
(cd "$repo" && PATH=$(without npm) "$cli" check) >"$work/out" 2>&1 || fail "audit false: a missing tool fails: $(cat "$work/out")"
config '{"audit": "no", "checks": [{"name": "lint", "run": "true"}]}'
run && fail "audit: a value that is no boolean passes"
grep -q "audit must be true or false" "$work/out" || fail "audit: bad value not explained: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "audit: all cases pass"
exit "$failures"
