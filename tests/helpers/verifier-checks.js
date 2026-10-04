"use strict";
const assert = require("node:assert/strict");
const { good } = require("./evm");
const R = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583n;
async function verifierChecks(e, verifier, transactions) {
  const ps = transactions.map((t) => t.proof), pubs = transactions.map((t) => t.publicSignals);
  // snarkjs has independently verified every proof in proof-worker.js.
  assert.equal(good(await e.call(verifier, "verify", [ps[0], pubs[0]], 0n, "verifier single")).ret[0], true);
  for (const n of [1, 2, 4, 8, 16]) {
    const proofs = Array.from({ length: n }, (_, i) => ps[i % ps.length]);
    const inputs = Array.from({ length: n }, (_, i) => pubs[i % pubs.length]).flat();
    assert.equal(good(await e.call(verifier, "verifyBatch", [proofs, inputs], 0n, `verifier batch ${n}`)).ret[0], true);
  }
  const pair = [ps[0], ps[1]], input = [...pubs[0], ...pubs[1]], changed = input.slice();
  changed[0] = (BigInt(changed[0]) + 1n) % R;
  const coordinate = structuredClone(pair); coordinate[0][0][0] = Q;
  const point = structuredClone(pair); point[0][2] = ps[1][2];
  const noncanonical = input.slice(); noncanonical[0] = R;
  for (const args of [[pair, changed], [pair, [...pubs[1], ...pubs[0]]], [point, input], [coordinate, input], [pair, noncanonical], [pair, input.slice(1)], [[], []]]) {
    assert.equal(good(await e.call(verifier, "verifyBatch", args)).ret[0], false);
  }
}
module.exports = { verifierChecks };
