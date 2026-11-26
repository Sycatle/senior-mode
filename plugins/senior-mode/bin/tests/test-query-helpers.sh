#!/usr/bin/env bash
# Tests of the query-count helpers of the presets (spec 472): each one counts the queries of a fake list, passes on a
# constant count, and fails naming the expected and the actual count on a list that queries once per record. The
# Python libraries and the Rust crates are fetched when missing; a runtime that cannot be had is reported as skipped.
set -u
presets=$(cd "$(dirname "$0")/../../presets" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cache=${TMPDIR:-/tmp}/senior-mode-query-helpers-$(id -u)
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
skip() { echo "skip: $*"; }

# A python that imports the modules $@: the system one, else a virtual environment kept in $cache.
python_with() {
  local mod
  if python3 -c "import $*" 2>/dev/null; then echo python3; return 0; fi
  [ -x "$cache/venv/bin/python" ] || python3 -m venv "$cache/venv" >/dev/null 2>&1 || return 1
  for mod in "$@"; do
    "$cache/venv/bin/python" -c "import $mod" 2>/dev/null || "$cache/venv/bin/pip" install -q "$mod" >/dev/null 2>&1 || return 1
  done
  echo "$cache/venv/bin/python"
}

# SQLAlchemy.
if py=$(python_with sqlalchemy); then
  mkdir -p "$work/sa" && cp "$presets/python/queries/sqlalchemy.py" "$work/sa/query_count.py"
  cat >"$work/sa/check.py" <<'PY'
from sqlalchemy import create_engine, text
from query_count import count_queries, expect_queries

engine = create_engine("sqlite://")
with engine.begin() as c:
    c.execute(text("create table t (id integer)"))
    c.execute(text("insert into t values (1), (2), (3)"))

def good():
    with engine.connect() as c:
        c.execute(text("select id from t")).all()

def n_plus_one():
    with engine.connect() as c:
        for (i,) in c.execute(text("select id from t")).all():
            c.execute(text("select id from t where id = :i"), {"i": i}).all()

with count_queries(engine) as counter:
    good()
assert counter.count == 1, counter.count
with expect_queries(engine, 1):
    good()
try:
    with expect_queries(engine, 1):
        n_plus_one()
except AssertionError as e:
    assert str(e) == "expected 1 queries, got 4", str(e)
else:
    raise SystemExit("an N+1 list passed")
PY
  (cd "$work/sa" && "$py" check.py) >"$work/out" 2>&1 || fail "sqlalchemy helper: $(tail -5 "$work/out")"
else skip "sqlalchemy helper: no python with sqlalchemy"; fi

# Django.
if py=$(python_with django); then
  mkdir -p "$work/dj" && cp "$presets/python/queries/django.py" "$work/dj/query_count.py"
  cat >"$work/dj/check.py" <<'PY'
import django
from django.conf import settings

settings.configure(DATABASES={"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": ":memory:"}})
django.setup()
from django.db import connection
from query_count import count_queries, expect_queries

with connection.cursor() as c:
    c.execute("create table t (id integer)")
    c.execute("insert into t values (1), (2), (3)")

def good():
    with connection.cursor() as c:
        c.execute("select id from t")
        c.fetchall()

def n_plus_one():
    with connection.cursor() as c:
        c.execute("select id from t")
        for (i,) in c.fetchall():
            c.execute("select id from t where id = %s", [i])

with count_queries() as counter:
    good()
assert counter.count == 1, counter.count
with expect_queries(1):
    good()
try:
    with expect_queries(1):
        n_plus_one()
except AssertionError as e:
    assert str(e) == "expected 1 queries, got 4", str(e)
else:
    raise SystemExit("an N+1 list passed")
PY
  (cd "$work/dj" && "$py" check.py) >"$work/out" 2>&1 || fail "django helper: $(tail -5 "$work/out")"
else skip "django helper: no python with django"; fi

# Prisma: the helper is the client extension; a stand-in client calls its hook like Prisma does, once per operation.
if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
  mkdir -p "$work/pr" && cp "$presets/node/queries/prisma.ts" "$work/pr/query-count.ts"
  cat >"$work/pr/check.mjs" <<'JS'
import assert from 'node:assert/strict'
import { countQueries, queriesOf, expectQueries } from './query-count.ts'

const rows = (n) => Array.from({ length: n }, (_, id) => ({ id }))
const op = (model, operation, run) => (args) =>
  countQueries.query.$allOperations({ model, operation, args, query: async (a) => run(a) })
const client = (n) => ({
  user: { findMany: op('user', 'findMany', () => rows(n)), findUnique: op('user', 'findUnique', (a) => ({ id: a.where.id })) },
})
const good = (db) => async () => db.user.findMany({})
const nPlusOne = (db) => async () => {
  for (const u of await db.user.findMany({})) await db.user.findUnique({ where: { id: u.id } })
}

const one = await queriesOf(good(client(1)))
assert.equal(one, 1)
await expectQueries(one, good(client(10)))
assert.equal(await queriesOf(nPlusOne(client(10))), 11)
await assert.rejects(expectQueries(1, nPlusOne(client(10))), { message: 'expected 1 queries, got 11' })
JS
  (cd "$work/pr" && node check.mjs) >"$work/out" 2>&1 || fail "prisma helper: $(tail -8 "$work/out")"
else skip "prisma helper: node 22 or later is needed to run TypeScript"; fi

# sqlx: events of target sqlx::query, as sqlx emits them, counted across tasks and threads.
if command -v cargo >/dev/null; then
  mkdir -p "$work/rs/src" "$work/rs/tests/support" && cp "$presets/rust/queries/sqlx.rs" "$work/rs/tests/support/query_count.rs"
  cat >"$work/rs/Cargo.toml" <<'TOML'
[package]
name = "helper-check"
version = "0.0.0"
edition = "2021"

[dependencies]
tracing = "0.1"
tracing-subscriber = "0.3"
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
TOML
  : >"$work/rs/src/lib.rs"
  cat >"$work/rs/tests/it.rs" <<'RS'
#[path = "support/query_count.rs"]
mod query_count;
use query_count::{expect_queries, queries_of};

async fn query() {
    tracing::debug!(target: "sqlx::query", "select 1");
    tokio::task::yield_now().await;
}
async fn other() {
    tracing::debug!(target: "app", "not a query");
}
async fn good() {
    query().await;
    other().await;
}
async fn n_plus_one(records: usize) {
    query().await;
    for _ in 0..records {
        query().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn counts_and_passes_on_a_constant_count() {
    let (one, _) = queries_of(good()).await;
    assert_eq!(one, 1);
    expect_queries(one, good()).await;
}

#[tokio::test(flavor = "multi_thread")]
#[should_panic(expected = "expected 1 queries, got 11")]
async fn fails_naming_both_counts_on_an_n_plus_one() {
    expect_queries(1, n_plus_one(10)).await;
}
RS
  if (cd "$work/rs" && CARGO_TARGET_DIR="$cache/rust-target" cargo test --quiet) >"$work/out" 2>&1; then :
  elif grep -qE 'failed to (get|download|fetch)|network|Unable to update registry|dns error' "$work/out"; then skip "sqlx helper: the crates cannot be fetched"
  else fail "sqlx helper: $(tail -12 "$work/out")"; fi
else skip "sqlx helper: no cargo"; fi

[ "$failures" -eq 0 ] && echo "query helpers: all cases pass"
exit "$failures"
