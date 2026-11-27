#!/usr/bin/env bash
# Tests for the performance rules of `senior-mode check` (#472): a foreign key added without an index (#744), the linter of the migrations (#747), the benchmark of a hot path (#758), the benchmarks of tier 3 (#761). Offline: each case is a
# branch off main in a fixture repository.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
git_() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
run() { (cd "$repo" && "$cli" check) >"$work/out" 2>&1; }
run3() { (cd "$repo" && "$cli" check --tier 3) >"$work/out" 2>&1; }
export XDG_DATA_HOME="$work/xdg"

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/prisma" "$repo/db/migrations"
echo '{"audit":false,"checks":[{"name":"lint","run":"true"}]}' >"$repo/.claude/senior-mode.json"
cat >"$repo/prisma/schema.prisma" <<'PRISMA'
model User {
  id    Int    @id
  posts Post[]
}

model Post {
  id       Int  @id
  authorId Int
  author   User @relation(fields: [authorId], references: [id])
}
PRISMA
cat >"$repo/db/migrations/001_init.sql" <<'SQL'
CREATE TABLE users (id integer PRIMARY KEY);
CREATE TABLE posts (id integer PRIMARY KEY, author_id integer NOT NULL REFERENCES users (id));
SQL
echo 'one' >"$repo/README.md"
git_ add -A
git_ commit -q -m "chore: base"

n=0
# branch <file> <content>: a branch off main whose only commit appends the content to the file.
branch() {
  n=$((n + 1))
  git_ checkout -q -- .claude/senior-mode.json
  git_ checkout -q main
  git_ checkout -q -b "t$n"
  mkdir -p "$(dirname "$repo/$1")"
  printf '%s\n' "$2" >>"$repo/$1"
  git_ add -A
  git_ commit -q -m "feat: change $n"
}

# Prisma: a new foreign key with no index fails naming file, line and column.
branch prisma/schema.prisma 'model Comment {
  id     Int  @id
  postId Int
  post   Post @relation(fields: [postId], references: [id])
}'
run && fail "a Prisma foreign key without an index passes: $(cat "$work/out")"
grep -q "FAIL  foreign keys" "$work/out" || fail "foreign keys not reported as failed: $(cat "$work/out")"
grep -q "prisma/schema.prisma:14 foreign keys Comment.postId is a foreign key with no index" "$work/out" || fail "file, line and column not given: $(cat "$work/out")"

# Prisma: with a @@index on the column in the model it passes.
branch prisma/schema.prisma 'model Comment {
  id     Int  @id
  postId Int
  post   Post @relation(fields: [postId], references: [id])

  @@index([postId, id])
}'
run || fail "a Prisma foreign key with @@index fails: $(cat "$work/out")"
grep -q "ok    foreign keys" "$work/out" || fail "the rule did not run on a schema change: $(cat "$work/out")"

# Prisma: a foreign key the base already had, with no index, is not reported when the diff touches the schema elsewhere.
branch prisma/schema.prisma 'model Tag {
  id Int @id
}'
run || fail "a foreign key that existed before the diff is reported: $(cat "$work/out")"

# SQL: a new foreign key with no index fails naming file, line and column.
branch db/migrations/002_comments.sql 'CREATE TABLE comments (
  id integer PRIMARY KEY,
  post_id integer NOT NULL REFERENCES posts (id)
);'
run && fail "a SQL foreign key without an index passes: $(cat "$work/out")"
grep -q "db/migrations/002_comments.sql:3 foreign keys comments.post_id is a foreign key with no index" "$work/out" || fail "SQL file, line and column not given: $(cat "$work/out")"

# SQL: the same key with a CREATE INDEX in the diff passes; so does a FOREIGN KEY clause whose index is in an earlier migration.
branch db/migrations/002_comments.sql 'CREATE TABLE comments (
  id integer PRIMARY KEY,
  post_id integer NOT NULL,
  FOREIGN KEY (post_id) REFERENCES posts (id)
);
CREATE INDEX comments_post_id_idx ON comments (post_id);'
run || fail "a SQL foreign key with CREATE INDEX fails: $(cat "$work/out")"
git_ checkout -q main
git_ checkout -q -b t-earlier
echo 'CREATE INDEX posts_author_idx ON posts (author_id);' >>"$repo/db/migrations/001_init.sql"
git_ commit -q -a -m "chore: index"
git_ checkout -q -b t-earlier-fk
echo 'ALTER TABLE posts ADD CONSTRAINT fk_author FOREIGN KEY (author_id) REFERENCES users (id);' >"$repo/db/migrations/003_fk.sql"
git_ add -A
git_ commit -q -m "feat: fk"
run || fail "a foreign key indexed by an earlier migration fails: $(cat "$work/out")"

# A SQL ALTER TABLE ... ADD COLUMN ... REFERENCES with no index fails.
branch db/migrations/004_alter.sql 'ALTER TABLE posts ADD COLUMN editor_id integer REFERENCES users (id);'
run && fail "an added column with REFERENCES and no index passes: $(cat "$work/out")"
grep -q "db/migrations/004_alter.sql:1 foreign keys posts.editor_id is a foreign key with no index" "$work/out" || fail "ALTER TABLE column not named: $(cat "$work/out")"

# No schema or migration change: the rule does not run.
branch README.md 'two'
run || fail "a diff with no schema change fails: $(cat "$work/out")"
grep -q "foreign keys" "$work/out" && fail "the rule runs on a diff with no schema or migration change: $(cat "$work/out")"

# Migrations (#747): stub linters on the PATH log what they are given and print fixed findings.
mkdir "$work/bin"
cat >"$work/bin/squawk" <<'STUB'
#!/usr/bin/env bash
echo "squawk $*" >>"$CALLS"
rc=0
for f in "$@"; do
  if grep -q 'CREATE INDEX' "$f" && ! grep -q 'CONCURRENTLY' "$f"; then
    echo "$f:1:1: warning: require-concurrent-index-creation"
    rc=1
  fi
done
exit "$rc"
STUB
cat >"$work/bin/django-migration-linter" <<'STUB'
#!/usr/bin/env bash
echo "django-migration-linter $*" >>"$CALLS"
echo "(app, 0002_bad)... ERR (NOT_NULL)"
exit 1
STUB
chmod +x "$work/bin/squawk" "$work/bin/django-migration-linter"
export CALLS="$work/calls"
export PATH="$work/bin:$PATH"
base_config=$(cat "$repo/.claude/senior-mode.json")
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; : >"$CALLS"; }

# squawk runs on the migrations the branch adds, those only, and fails naming file, line and rule.
branch db/migrations/010_index.sql 'CREATE INDEX posts_title_idx ON posts (title);'
config '{"audit":false,"checks":[{"name":"lint","run":"true"}],"performance":{"migrations":{"linter":"squawk","paths":["db/migrations/*.sql"]}}}'
run && fail "an index created without CONCURRENTLY passes: $(cat "$work/out")"
grep -q "FAIL  migrations" "$work/out" || fail "migrations not reported as failed: $(cat "$work/out")"
grep -q "db/migrations/010_index.sql:1 migrations warning: require-concurrent-index-creation" "$work/out" || fail "file, line and rule not given: $(cat "$work/out")"
[ "$(cat "$CALLS")" = "squawk db/migrations/010_index.sql" ] || fail "squawk did not run on the changed migration only: $(cat "$CALLS")"

# A migration the linter accepts passes.
branch db/migrations/011_ok.sql 'CREATE INDEX CONCURRENTLY posts_body_idx ON posts (body);'
config '{"audit":false,"checks":[{"name":"lint","run":"true"}],"performance":{"migrations":{"linter":"squawk","paths":["db/migrations/*.sql"]}}}'
run || fail "a clean migration fails: $(cat "$work/out")"
grep -q "ok    migrations" "$work/out" || fail "the migrations step did not run: $(cat "$work/out")"

# A Django project: django-migration-linter on the changed migrations, by name.
mkdir -p "$repo/shop/migrations"
branch manage.py '#!/usr/bin/env python'
echo 'x = 1' >"$repo/shop/migrations/0002_bad.py"
git_ add -A
git_ commit -q -m "feat: django migration"
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
run && fail "a Django migration the linter rejects passes: $(cat "$work/out")"
[ "$(cat "$CALLS")" = "django-migration-linter --include-name 0002_bad ." ] || fail "django-migration-linter not run on the changed migration: $(cat "$CALLS")"

# No linter and no Django: not measured, and the step passes.
branch db/migrations/012_plain.sql 'ALTER TABLE posts DROP COLUMN title;'
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
run || fail "a migration with no linter fails: $(cat "$work/out")"
grep -q "migrations: not measured" "$work/out" || fail "not measured not reported: $(cat "$work/out")"
[ ! -s "$CALLS" ] || fail "a linter ran with none configured: $(cat "$CALLS")"

# A diff with no migration does not run the linter.
branch README.md 'three'
config '{"audit":false,"checks":[{"name":"lint","run":"true"}],"performance":{"migrations":{"linter":"squawk"}}}'
run || fail "a diff with no migration fails: $(cat "$work/out")"
grep -q "migrations" "$work/out" && fail "the migrations step runs on a diff with no migration: $(cat "$work/out")"
[ ! -s "$CALLS" ] || fail "the linter ran on a diff with no migration: $(cat "$CALLS")"
printf '%s\n' "$base_config" >"$repo/.claude/senior-mode.json"

# Hot paths (#758): a spec with a `## Hot paths` section, on main.
git_ checkout -q main
mkdir -p "$repo/docs/specs" "$repo/src/billing" "$repo/src/plain"
cat >"$repo/docs/specs/900-billing.md" <<'SPEC'
---
id: 900
title: Billing total
status: accepted
paths: ["src/billing/**"]
---

# Billing total

## Hot paths

- `src/billing/total.ts`: benchmark `invoiceTotal`, called for every invoice line.

## Open questions

None.
SPEC
cat >"$repo/docs/specs/901-plain.md" <<'SPEC'
---
id: 901
title: Plain
status: accepted
paths: ["src/plain/**"]
---

# Plain

## Open questions

None.
SPEC
git_ add -A
git_ commit -q -m "docs: specs"
bench_config='{"audit":false,"checks":[{"name":"lint","run":"true"}],"performance":{"bench":{"command":"true"}}}'

# A diff under the spec's paths with no benchmark of that name fails naming spec, path and benchmark.
branch src/billing/total.ts 'export const total = 1'
config "$bench_config"
run && fail "a hot path with no benchmark passes: $(cat "$work/out")"
grep -q "FAIL  hot paths" "$work/out" || fail "hot paths not reported as failed: $(cat "$work/out")"
grep -q "docs/specs/900-billing.md:12 hot paths hot path src/billing/total.ts has no benchmark named invoiceTotal" "$work/out" || fail "spec, path and benchmark not named: $(cat "$work/out")"

# The benchmark exists: it passes.
branch src/billing/total.ts 'export const more = 2'
mkdir -p "$repo/bench"
echo "bench('invoiceTotal', () => total)" >"$repo/bench/total.bench.ts"
git_ add -A
git_ commit -q -m "feat: bench"
config "$bench_config"
run || fail "a hot path with its benchmark fails: $(cat "$work/out")"
grep -q "ok    hot paths" "$work/out" || fail "the hot paths step did not run: $(cat "$work/out")"

# No performance.bench.command: not measured, no failure.
branch src/billing/total.ts 'export const third = 3'
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
run || fail "a hot path with no bench command fails: $(cat "$work/out")"
grep -q "bench: not measured" "$work/out" || fail "bench: not measured not reported: $(cat "$work/out")"

# A spec without a Hot paths section, and a diff outside the spec's paths: nothing is checked.
branch src/plain/a.ts 'export const a = 1'
config "$bench_config"
run || fail "a spec without hot paths fails: $(cat "$work/out")"
grep -q "hot paths" "$work/out" && fail "the hot paths step runs for a spec without a Hot paths section: $(cat "$work/out")"
branch README.md 'four'
config "$bench_config"
run || fail "a diff outside the spec paths fails: $(cat "$work/out")"
grep -q "hot paths" "$work/out" && fail "the hot paths step runs on a diff outside the spec paths: $(cat "$work/out")"
printf '%s\n' "$base_config" >"$repo/.claude/senior-mode.json"

# The spec template carries the optional section, and the presets name the benchmark tool.
tpl=$(cd "$(dirname "$0")/../.." && pwd)
grep -q '^## Hot paths' "$tpl/skills/spec/template.md" || fail "the spec template has no Hot paths section"
for pair in node:"vitest bench" python:pytest-benchmark rust:criterion go:"go test -bench with benchstat"; do
  [ "$(jq -r '.bench.tool' "$tpl/presets/${pair%%:*}/preset.json")" = "${pair#*:}" ] || fail "preset ${pair%%:*} does not name ${pair#*:}"
done

# Benchmarks of tier 3 (#761): the command prints the medians kept in bench.json of each commit.
git_ checkout -q main
echo '{"invoiceTotal": 100}' >"$repo/bench.json"
git_ add -A
git_ commit -q -m "chore: bench"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case $* in *"/pulls"*) echo 17 ;; esac
exit 0
STUB
chmod +x "$work/bin/gh"
cat >"$work/flaky.sh" <<'STUB'
#!/usr/bin/env bash
n=$(($(cat "$CALLS.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$CALLS.n"
case $n in 1 | 2) echo '{"invoiceTotal": 100}' ;; *) echo '{"invoiceTotal": 140}' ;; esac
STUB
cat_config='{"audit":false,"checks":[{"name":"lint","run":"true"}],"performance":{"bench":{"command":"cat bench.json"}}}'
# bench <median>: a branch that touches the hot path and puts the median in bench.json.
bench() {
  branch src/billing/total.ts "export const v$n = $1"
  echo "{\"invoiceTotal\": $1}" >"$repo/bench.json"
  git_ add -A
  git_ commit -q --allow-empty -m "perf: change $n"
  config "$cat_config"
}

# A benchmark more than the threshold slower than on the merge base fails naming benchmark, both medians and the change.
bench 130
run3 && fail "a 30% regression passes: $(cat "$work/out")"
grep -q "FAIL  perf" "$work/out" || fail "perf not reported as failed: $(cat "$work/out")"
grep -q "benchmark invoiceTotal is slower: median 100 on the base, 130 on the head (+30.0%, more than 10%)" "$work/out" || fail "benchmark, medians and change not named: $(cat "$work/out")"

# Within the threshold it passes; so does a speed-up.
bench 105
run3 || fail "a 5% change fails: $(cat "$work/out")"
grep -q "ok    perf" "$work/out" || fail "the perf step did not run in tier 3: $(cat "$work/out")"
bench 60
run3 || fail "a speed-up fails: $(cat "$work/out")"

# The threshold is performance.bench.threshold.
bench 105
config '{"audit":false,"checks":[{"name":"lint","run":"true"}],"performance":{"bench":{"command":"cat bench.json","threshold":2}}}'
run3 && fail "a 5% change passes a 2% threshold: $(cat "$work/out")"

# Tier 2 does not run it.
run || fail "check fails on a benchmark branch: $(cat "$work/out")"
grep -q "perf" "$work/out" && fail "the perf step runs in tier 2: $(cat "$work/out")"

# Two runs of one commit that differ by more than the threshold are unstable: needs-human, an issue, never a pass.
git_ remote add origin https://github.com/acme/fixture.git
bench 100
config '{"audit":false,"checks":[{"name":"lint","run":"true"}],"performance":{"bench":{"command":"bash '"$work"'/flaky.sh"}}}'
rm -f "$CALLS.n"
run3 && fail "an unstable benchmark passes: $(cat "$work/out")"
grep -q "benchmark invoiceTotal is unstable" "$work/out" || fail "unstable not reported: $(cat "$work/out")"
grep -q "repos/acme/fixture/issues/17/labels -f labels\[\]=needs-human" "$CALLS" || fail "the pull request did not get needs-human: $(cat "$CALLS")"
grep -q "repos/acme/fixture/issues -f title=perf: benchmark invoiceTotal is unstable" "$CALLS" || fail "no issue filed for the benchmark: $(cat "$CALLS")"
git_ remote remove origin

# No performance.bench.command: bench: not measured.
bench 130
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
run3 || fail "tier 3 with no bench command fails: $(cat "$work/out")"
grep -q "bench: not measured" "$work/out" || fail "bench: not measured not reported in tier 3: $(cat "$work/out")"

# A diff outside the hot paths runs no benchmark.
branch README.md 'five'
config "$cat_config"
run3 || fail "tier 3 on a diff outside the hot paths fails: $(cat "$work/out")"
grep -q "perf" "$work/out" && fail "the perf step runs outside the hot paths: $(cat "$work/out")"
printf '%s\n' "$base_config" >"$repo/.claude/senior-mode.json"

[ "$failures" -eq 0 ] && echo "perf: all cases pass"
exit "$failures"
