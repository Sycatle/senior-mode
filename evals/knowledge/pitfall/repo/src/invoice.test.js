import assert from "node:assert/strict";
import { test } from "node:test";
import { totalLabel } from "./invoice.js";

test("totalLabel shows euros with a comma", () => {
  assert.equal(totalLabel(123456).replace(/\s/g, ""), "1234,56EUR");
});
