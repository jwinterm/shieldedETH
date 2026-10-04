"use strict";
const assert = require("node:assert/strict"), { ethers } = require("ethers"), { Address } = require("@ethereumjs/util");
const { good, rejected } = require("./evm");
async function accountingEdges(p, fresh, stale) {
  const { e, pool } = p, sm = e.vm.stateManager;
  await sm.checkpoint();
  try {
    // Artificial balance only for the uint128 boundary regression, never benchmarked.
    const account = await sm.getAccount(e.sender); account.balance = 1n << 132n; await sm.putAccount(e.sender, account);
    const maximum = (1n << 128n) - 1n, oldC = BigInt(await e.read(pool, "C"));
    const body = { ...stale.body, tip: maximum };
    good(await e.call(pool, "transactBatch", [[fresh.proof, stale.proof, stale.proof], [fresh.body, body, body]], fresh.body.tip + 2n * maximum));
    assert.equal(BigInt(await e.read(pool, "C")), oldC + 2n * maximum, "sum of skipped tips must not truncate to uint128");
    assert.equal(BigInt(await e.read(pool, "credit", [e.address])), oldC + 2n * maximum);
  } finally { await sm.revert(); }
  await p.invariants();

  await sm.checkpoint();
  try {
    const field = e.artifacts.ShieldedETHPool.storageLayout.storage.find((s) => s.label === "nextEntry");
    const address = Address.fromString(pool.address), slot = ethers.utils.zeroPad(ethers.utils.arrayify(ethers.BigNumber.from(field.slot)), 32);
    const old = await sm.getContractStorage(address, slot), word = old.length ? BigInt(ethers.utils.hexlify(old)) : 0n;
    const shift = BigInt(field.offset * 8), mask = ((1n << 40n) - 1n) << shift;
    const full = (word & ~mask) | ((1n << 30n) << shift);
    await sm.putContractStorage(address, slot, ethers.utils.zeroPad(ethers.utils.arrayify(ethers.BigNumber.from(full)), 32));
    // An unrelated canonical proof would fail pairing verification if capacity were checked late.
    rejected(await e.call(pool, "transact", [1, stale.proof, fresh.body], fresh.body.tip), "Full");
    rejected(await e.call(pool, "transactBatch", [[stale.proof], [fresh.body]], fresh.body.tip), "Full");
  } finally { await sm.revert(); }
  await p.invariants();
}
module.exports = { accountingEdges };
