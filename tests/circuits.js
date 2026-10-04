"use strict";
const assert = require("node:assert/strict"), crypto = require("node:crypto"), path = require("node:path");
const { S, wallet, note, spend, directContext, depositRecord, batch } = require("../ref/transactions");
const { expectWitness } = require("../ref/circuit_expectations");
const { BUILD, ROOT, save, sourceFiles } = require("../scripts/artifacts");
(async () => {
  const sourceHashes = sourceFiles();
  await S.init();
  const poolId = crypto.randomBytes(32), alice = wallet(poolId), bob = wallet(poolId), tree = new S.Tree();
  const deposit = note(poolId, alice, 100n, 1); deposit.pos = 0;
  tree.insertEntry(0, [deposit.cm, 0n, 0n, 0n]);
  const outputs = [note(poolId, bob, 30n, 1), note(poolId, alice, 69n, 1), note(poolId, alice, 1n, 1), note(poolId, alice, 0n, 1)];
  const tx = spend({ poolId, inputs: [deposit], outputs, tree, rootSeq: 1 });
  const acc0 = S.acc0Of(poolId), rec = depositRecord(poolId, deposit, 7n, 0);
  const d = directContext({ poolId, tree: new S.Tree(), records: [rec], accStart: acc0, inserted: 0, ownIndex: 1, outputs, beneficiary: "0x0000000000000000000000000000000000001234" });
  const direct = spend({ poolId, inputs: [deposit], outputs, tree: new S.Tree(), rootSeq: 0, circuit: "direct", direct: d });
  const clone = (x) => structuredClone(x);
  const mutations = [
    ["inflation", (x) => x.outValue[0]++],
    ["cross-asset relabel", (x) => x.asset = 0],
    ["unregistered asset", (x) => x.asset = 2],
    ["foreign ownership", (x) => x.sk = bob.keys.sk],
    ["forged nullifier", (x) => x.nf[0]++],
    ["wrong leaf position", (x) => x.inBits[0][31] = 1],
    ["nonboolean enable", (x) => x.inEnabled[0] = 2],
    ["disabled value", (x) => x.inValue[1] = 1n],
    ["value overflow", (x) => x.inValue[0] = 1n << 128n],
    ["empty spend", (x) => x.inEnabled[0] = 0],
    ["forged root", (x) => x.root++],
    ["output asset conservation", (x) => x.publicAmount = S.r - 1n]
  ];
  const cases = [["transfer24", "valid native transfer", tx.input, true], ["direct", "first pending token deposit is spendable under intermediate root", direct.input, true]];
  for (const [label, change] of mutations) { const input = clone(tx.input); change(input); cases.push(["transfer24", label, input, false]); }
  const badDirect = clone(direct.input); badDirect.root = tree.root(); cases.push(["direct", "cannot overwrite absorbed slot", badDirect, false]);
  for (const name of ["transfer24h", "directh"]) {
    const args = name === "directh" ? { tree: new S.Tree(), rootSeq: 0, direct: d } : { tree, rootSeq: 1 };
    const t = spend({ poolId, inputs: [deposit], outputs, circuit: name, ...args });
    cases.push([name, "valid hashed relation", t.input, true]);
    const bad = clone(t.input); bad.stmt++; cases.push([name, "changed statement", bad, false]);
  }
  for (const maxK of [1, 16]) {
    const name = maxK === 1 ? "batch1" : "batch16";
    const b = batch({ poolId, tree: new S.Tree(), records: [rec], start: 0, accStart: acc0, beneficiary: d.context.rewardBeneficiary, maxK });
    cases.push([name, "authenticated deposit insertion", b.input, true]);
    const bad = clone(b.input); bad.w[0][1]++; cases.push([name, "changed funded amount", bad, false]);
    if (maxK === 16) { const inactive = clone(b.input); inactive.tip[15] = 1n; cases.push([name, "inactive slot must be canonical", inactive, false]); }
  }
  const outcomes = [];
  for (const [name, label, input, shouldAccept] of cases) {
    await expectWitness({ name, buildDir: path.join(BUILD, "circuits"), input: JSON.parse(JSON.stringify(input, (_, v) => typeof v === "bigint" ? String(v) : v)), shouldAccept, snarkjsCli: path.join(ROOT, "node_modules/snarkjs/build/cli.cjs") });
    outcomes.push({ circuit: name, label, expected: shouldAccept ? "accept" : "reject", passed: true });
    console.log(`PASS ${name}: ${label}`);
  }
  await assert.rejects(expectWitness({ name: "missing", buildDir: path.join(BUILD, "circuits"), input: {}, shouldAccept: false, snarkjsCli: path.join(ROOT, "node_modules/snarkjs/build/cli.cjs") }));
  await assert.rejects(expectWitness({ name: "transfer24", buildDir: path.join(BUILD, "circuits"), input: JSON.parse(JSON.stringify(tx.input, (_, v) => typeof v === "bigint" ? String(v) : v)), shouldAccept: false, snarkjsCli: path.join(ROOT, "node_modules/snarkjs/build/cli.cjs") }));
  const inverted = clone(tx.input); inverted.nf[0]++;
  await assert.rejects(expectWitness({ name: "transfer24", buildDir: path.join(BUILD, "circuits"), input: JSON.parse(JSON.stringify(inverted, (_, v) => typeof v === "bigint" ? String(v) : v)), shouldAccept: true, snarkjsCli: path.join(ROOT, "node_modules/snarkjs/build/cli.cjs") }));
  outcomes.push({ label: "missing artifacts and inverted positive and negative expectations fail", passed: true });
  assert.deepEqual(sourceFiles(), sourceHashes, "sources changed during circuit tests");
  save(path.join(BUILD, "circuit-tests.json"), { sourceHashes, outcomes });
  console.log(`${outcomes.length} circuit and harness cases passed`);
})().then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
