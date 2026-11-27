#!/usr/bin/env bash
# Tests for the performance rules of `senior-mode check` (#472): a foreign key added without an index (#744). Offline: each case is a
# branch off main in a fixture repository.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
git_() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
run() { (cd "$repo" && "$cli" check) >"$work/out" 2>&1; }

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
  git_ checkout -q main
  git_ checkout -q -b "t$n"
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

[ "$failures" -eq 0 ] && echo "perf: all cases pass"
exit "$failures"
