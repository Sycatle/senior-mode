// The project's import sorter: `--check` fails on unsorted imports, otherwise it rewrites them.
// A file whose first line is `// keep-order` is left alone.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";

const check = process.argv.includes("--check");
let bad = 0;
for (const name of readdirSync("src").filter((f) => f.endsWith(".js") && !f.endsWith(".test.js"))) {
  const file = `src/${name}`;
  const lines = readFileSync(file, "utf8").split("\n");
  if (lines[0] === "// keep-order") continue;
  const head = lines.filter((l) => l.startsWith("import "));
  const sorted = [...head].sort();
  if (head.join("\n") === sorted.join("\n")) continue;
  bad++;
  if (!check) writeFileSync(file, [...sorted, ...lines.filter((l) => !l.startsWith("import "))].join("\n"));
}
process.exit(check && bad ? 1 : 0);
