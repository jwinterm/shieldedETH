"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict");
const { EVM, good } = require("./helpers/evm");
test("benchmark transactions reset storage accounting and view access warmth", async () => {
  const e = await EVM.create(), p = await e.deploy("StorageProbe");
  const first = good(await e.call(p, "increment"));
  const second = good(await e.call(p, "increment"));
  await e.read(p, "value");
  const third = good(await e.call(p, "increment"));
  assert(first.row.totalGas > second.row.totalGas + 15000);
  assert.equal(second.row.totalGas, third.row.totalGas);
  assert.equal((await e.read(p, "value")).toNumber(), 3);
  assert.equal(second.row.totalGas, second.row.executionGas + second.row.intrinsicGas);
});
