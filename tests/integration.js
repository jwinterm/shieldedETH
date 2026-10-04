"use strict";
const assert = require("node:assert/strict"), path = require("node:path"), os = require("node:os");
const { ethers } = require("ethers");
const { Pool, T, S, good, rejected } = require("./helpers/pool");
const { BUILD, save, sourceFiles, json } = require("../scripts/artifacts");
const { verifierChecks } = require("./helpers/verifier-checks");
const { accountingEdges } = require("./helpers/accounting-edges");

async function run(profile) {
  const p = await Pool.create(profile), { e, pool, alice, bob, fee } = p;
  const checks = [], check = (name) => { checks.push(name); console.log(`[${profile}] PASS ${name}`); };
  const outputs = (owner, amount, asset = 1) => [p.note(owner, amount, asset), ...[0, 0, 0].map(() => p.note(alice, 0n, asset))];

  // First-deposit spending, including tip races and body binding.
  const first = p.note(alice, 1000n); await p.deposit(first, 7n, "first token deposit");
  good(await e.call(pool, "addInsertionTip", [0], 3n)); p.topups.set(0, 3n);
  const initialOutputs = [p.note(bob, 400n), p.note(alice, 590n), p.note(fee, 10n), p.note(alice, 0n)];
  const direct = p.direct(initialOutputs), dt = await p.spend([first], initialOutputs, { name: "direct", direct });
  rejected(await e.call(pool, "transactDirect", [dt.proof, dt.body, { ...direct.context, rewardBeneficiary: p.tokens[1].address }, direct.pending]), "BadProof");
  await p.invariants(); await p.sendDirect(dt, direct);
  assert.equal(BigInt(await e.read(pool, "credit", [e.address])), 10n);
  check("first token deposit spent under intermediate root; reward recipient bound");
  rejected(await e.call(pool, "transactDirect", [dt.proof, dt.body, direct.context, direct.pending]), "Stale");
  await p.invariants();

  const paymentOutputs = [p.note(alice, 250n), p.note(bob, 140n), p.note(fee, 10n), p.note(alice, 0n)];
  const payment = await p.spend([initialOutputs[0]], paymentOutputs, { tip: 5n });
  const changed = { ...payment.body, nonce: ethers.utils.hexlify(require("node:crypto").randomBytes(32)) };
  rejected(await e.call(pool, "transact", [1, payment.proof, changed], 5n), "BadProof");
  await p.invariants(); await p.send(payment);
  rejected(await e.call(pool, "transact", [1, payment.proof, payment.body], 5n), "NullifierUsed");
  await p.invariants(); await p.insert(1, 1, true);
  check("onward payment, envelope binding, double-spend refusal, authenticated insertion");

  const withdrawalOutputs = outputs(alice, 150n);
  const withdraw = await p.spend([paymentOutputs[0]], withdrawalOutputs, { W: 100n, recipient: e.address });
  for (const mode of [1, 2, 3, 4, 5, 7, 8]) {
    good(await e.call(p.tokens[1], "setMode", [mode]));
    rejected(await e.call(pool, "transact", [1, withdraw.proof, withdraw.body]), "TokenTransferFailed");
    await p.invariants();
  }
  good(await e.call(p.tokens[1], "setMode", [0]));
  await p.send(withdraw, "token withdrawal with change"); await p.insert();
  check("token pause, false, no-op, tax, surcharge and malformed return roll back spend");
  const rootBeforeExit = BigInt(await e.read(pool, "rootSeq"));
  const exit = await p.spend([withdrawalOutputs[0], initialOutputs[1]], [], { name: "exit", W: 740n, recipient: e.address });
  await p.send(exit, "two-note token exit");
  assert.equal(BigInt(await e.read(pool, "rootSeq")), rootBeforeExit);
  check("two-note complete exit advances idle queue without rotating note root");

  // A failed asset does not require balance calls during an unrelated ETH exit.
  const ethNote = p.note(alice, 10000n, 0); await p.deposit(ethNote, 0n, "ETH deposit");
  const ethOutputs = outputs(alice, 10000n, 0), ethDirect = p.direct(ethOutputs);
  const et = await p.spend([ethNote], ethOutputs, { name: "direct", direct: ethDirect });
  await p.sendDirect(et, ethDirect);
  const refuse = await e.deploy("RejectETH");
  const failedExit = await p.spend([ethOutputs[0]], [], { name: "exit", W: 10000n, recipient: refuse.address, payoutGas: 50000 });
  rejected(await e.call(pool, "exit", [failedExit.proof, failedExit.body]), "PayoutFailed"); await p.invariants();
  const ethExit = await p.spend([ethOutputs[0]], [], { name: "exit", W: 10000n, recipient: e.address, payoutGas: 50000 });
  good(await e.call(p.tokens[1], "setMode", [1])); await p.send(ethExit, "ETH exit");
  good(await e.call(p.tokens[1], "setMode", [0]));
  check("ETH first-deposit spending; recipient refusal restores spend; unrelated token pause does not block exit");

  // Twenty independently recoverable deposits. Both full and partial BATCH_UPTO_16 proofs.
  const many = Array.from({ length: 20 }, (_, i) => p.note(alice, 100n, i < 2 ? 0 : 1));
  await p.depositMany(many, 2n);
  await p.insert(16, 16, true); await p.insert(4, 16);
  check("multi-deposit exact records and one token pull; real full and partial 16-entry insertion");

  // Fourteen independent real user proofs and two stale entries, submitted together.
  const sends = [];
  for (const n of many.slice(0, 14)) {
    sends.push(await p.spend([n], [p.note(alice, 90n, n.asset), p.note(fee, 10n, n.asset), p.note(alice, 0n, n.asset), p.note(alice, 0n, n.asset)], { tip: 1n }));
  }
  await verifierChecks(e, p.verifiers[p.circuit("transfer24")], sends);
  check("standalone verifier batches 1/2/4/8/16; altered statements, swapped inputs, foreign points and noncanonical encodings rejected");
  await accountingEdges(p, sends[0], payment);
  check("skipped-tip sum above uint128 retains exact credit; full-tree guards precede proof verification");
  const lane = [...sends, sends[0], payment], tips = lane.reduce((v, t) => v + t.body.tip, 0n);
  const badProofs = lane.map((t) => t.proof); badProofs[3] = sends[4].proof;
  rejected(await e.call(pool, "transactBatch", [badProofs, lane.map((t) => t.body)], tips), "BadProof"); await p.invariants();
  const r = good(await e.call(pool, "transactBatch", [lane.map((t) => t.proof), lane.map((t) => t.body)], tips, "aggregate 14 included 2 stale"));
  const batchEvent = r.events.find((x) => x.name === "BatchTransacted");
  assert.equal(batchEvent.args.includedMask.toNumber(), (1 << sends.length) - 1);
  assert.equal(batchEvent.args.refundedTips.toBigInt(), sends[0].body.tip + payment.body.tip);
  const published = r.events.filter((x) => x.name === "EntryPublished");
  sends.forEach((tx, i) => p.apply(tx, { events: [published[i]] }));
  await p.invariants();
  rejected(await e.call(pool, "transactBatch", [[sends[0].proof], [sends[0].body]], 1n), "NothingIncluded");
  await p.invariants(); await p.insert(14, 16);
  check("real Groth16 aggregation, stale skips and refunds, atomic invalid-proof rollback, subsequent insertion");

  // Eight genuine owned inputs, not eight arbitrary public words.
  const consolidationInputs = sends.slice(2, 10).map((tx) => tx.outputs[0]);
  const consolidated = outputs(alice, 720n);
  const con = await p.spend(consolidationInputs, consolidated, { name: "transfer84" });
  await p.send(con, "eight-input consolidation"); await p.insert();
  const finalExit = await p.spend([consolidated[0]], [], { name: "exit", W: 720n, recipient: e.address });
  await p.send(finalExit, "consolidation exit");
  check("eight-input conservation followed by insertion and complete withdrawal");

  // Zero-entry advancement, top-up collection, and pull-credit failure isolation.
  const tailNotes = many.slice(14);
  const queueOutputs = outputs(alice, 100n), queued = await p.spend([tailNotes[0]], queueOutputs);
  await p.send(queued);
  const queuedExit = await p.spend([tailNotes[1]], [], { name: "exit", W: 100n, recipient: e.address, tip: 4n });
  await p.send(queuedExit, "queued exit"); await p.insert();
  const exitRecord = p.records[p.inserted], oldRootSeq = BigInt(await e.read(pool, "rootSeq"));
  good(await e.call(pool, "addInsertionTip", [exitRecord.entry], 6n)); p.topups.set(exitRecord.entry, 6n);
  const recs = [{ kind: exitRecord.kind, w: exitRecord.w, extHash: exitRecord.extHash, tip: exitRecord.tip }];
  good(await e.call(pool, "skipZeroEntries", [p.inserted, p.accs[p.inserted], e.address, recs], 0n, "skip zero entry")); p.inserted++;
  assert.equal(BigInt(await e.read(pool, "rootSeq")), oldRootSeq); await p.invariants();
  const credit = BigInt(await e.read(pool, "credit", [e.address]));
  rejected(await e.call(pool, "claimInsertionFees", [refuse.address, credit]), "PayoutFailed"); await p.invariants();
  const reentry = await e.deploy("ReentryReceiver");
  good(await e.call(pool, "claimInsertionFees", [reentry.address, credit], 0n, "claim insertion credit"));
  assert.equal(await e.read(reentry, "blocked"), true); await p.invariants();
  check("zero-entry skip, top-ups, credit rollback and reentrancy protection");

  // Every supported empty/no-return transfer convention is exercised at admission too.
  const unused = p.note(alice, 3n);
  for (const mode of [1, 2, 3, 4, 5, 7, 8]) {
    good(await e.call(p.tokens[1], "setMode", [mode]));
    rejected(await e.call(pool, "deposit", [1, unused.partial, unused.value, unused.ct]), "TokenTransferFailed"); await p.invariants();
  }
  good(await e.call(p.tokens[1], "setMode", [6])); await p.deposit(unused, 0n, "no-return token deposit");
  good(await e.call(p.tokens[1], "setMode", [0]));
  check("token admission exact debit/credit and no-return compatibility");
  return { profile, checks, proving: p.proofs, transactions: e.measurements, finalLedger: { entries: p.records.length, inserted: p.inserted, notes: p.notes.length } };
}
(async () => {
  await S.init();
  const profiles = process.argv.slice(2).length ? process.argv.slice(2) : ["native", "hashed"];
  for (const profile of profiles) {
    if (!["native", "hashed"].includes(profile)) throw Error("Profiles are native and hashed");
    const sourceHashes = sourceFiles(), result = await run(profile);
    assert.deepEqual(sourceFiles(), sourceHashes, "sources changed during integration tests");
    save(path.join(BUILD, `integration-${profile}.json`), { schema: 1, developmentOnly: true, chain: "local EVM", hardfork: "cancun", transactionRunner: "VM.runTx", sourceHashes, circuits: json(path.join(BUILD, "circuits/manifest.json")), hardware: { arch: os.arch(), cpu: os.cpus()[0].model, logicalCpus: os.cpus().length, memoryBytes: os.totalmem(), node: process.version }, result });
    console.log(`${profile}: full integration passed`);
  }
})().then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
