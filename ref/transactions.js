"use strict";
// Local construction utilities. No network submission or production activation.
const crypto = require("node:crypto"), assert = require("node:assert/strict");
const { ethers } = require("ethers"), S = require("./seth8");
const ZERO = ethers.constants.AddressZero;
function randomField() { let n; do { n = S.toBig(crypto.randomBytes(32)); } while (n === 0n || n >= S.r); return n; }
function wallet(poolId) {
  const keys = S.walletKeys(crypto.randomBytes(32));
  return { keys, addr: S.address(keys, crypto.randomBytes(11), poolId) };
}
function note(poolId, owner, value, asset) {
  const rseed = randomField(), partial = S.partialOf(owner.addr.owner, rseed), cm = S.cmOf(partial, BigInt(value), asset);
  const { ct, esk } = S.seal(poolId, owner.addr, BigInt(value), asset, rseed, cm);
  return { ...owner, value: BigInt(value), asset, rseed, partial, cm, ct, esk };
}
function cloneTree(tree) { const t = new S.Tree(); t.nodes = new Map(tree.nodes); return t; }
function depositRecord(poolId, item, tip = 0n, entry = 0) {
  const body = { asset: item.asset, partial: item.partial, amount: item.value, tip, ciphertext: item.ct };
  const extHash = S.extHashOf(S.canonicalBody(1, 0, poolId, 1n, (item.asset === 0 ? item.value : 0n) + tip, S.DEPOSIT_BODY, body));
  return { kind: 1, w: [item.partial, item.value, BigInt(item.asset), 0n], extHash, tip, entry };
}
function spend({ poolId, numAssets = 2, inputs, outputs = [], tree, rootSeq, circuit = "transfer24", tip = 0n, W = 0n,
  recipient = ZERO, payoutGas = 0, executor = ZERO, deadline = 2n ** 63n, recoveryKey, direct }) {
  const name = circuit.replace(/h$/, ""), hashed = circuit.endsWith("h"), nIn = name === "transfer84" ? 8 : 2, exit = name === "exit";
  assert(inputs.length > 0 && inputs.length <= nIn);
  assert.equal(outputs.length, exit ? 0 : 4);
  const keys = inputs[0].keys, asset = inputs[0].asset;
  assert(inputs.every((n) => n.asset === asset && n.keys.sk === keys.sk), "inputs must have one asset and owner");
  assert(outputs.every((n) => n.asset === asset), "outputs must use the input asset");
  assert.equal(inputs.reduce((a, n) => a + n.value, 0n), outputs.reduce((a, n) => a + n.value, W));
  const membership = direct ? direct.membershipTree : tree;
  const input = { noteDomain: S.noteDomainOf(poolId), numAssets, root: tree.root(), publicAmount: W ? S.r - W : 0n,
    publicAsset: W ? asset : 0, sk: keys.sk, asset,
    inEnabled: [], inValue: [], inD: [], inRseed: [], inPath: [], inBits: [], inDummySeed: [], nf: [] };
  for (let i = 0; i < nIn; i++) {
    const n = inputs[i], dummy = randomField();
    const path = n ? membership.path(n.pos) : { sib: Array(32).fill(0n), bits: Array(32).fill(0) };
    input.inEnabled.push(n ? 1 : 0); input.inValue.push(n?.value || 0n); input.inD.push(n ? S.toBig(n.addr.d) : 0n);
    input.inRseed.push(n?.rseed || 0n); input.inPath.push(path.sib); input.inBits.push(path.bits); input.inDummySeed.push(dummy);
    input.nf.push(n ? S.nfReal(input.noteDomain, keys.nk, n.cm, n.pos) : S.nfDummy(input.noteDomain, dummy, i));
  }
  const common = { rootSeq, root: tree.root(), nullifiers: input.nf, W, publicAsset: W ? asset : 0,
    tip, recipient, payoutGas, executor, deadline, nonce: ethers.utils.hexlify(crypto.randomBytes(32)) };
  let body, extHash, words, cid;
  if (exit) {
    body = common; cid = 3;
    extHash = S.extHashOf(S.canonicalBody(3, cid, poolId, 1n, tip, S.EXIT_BODY, body));
    words = [input.noteDomain, BigInt(numAssets), input.root, input.publicAmount, BigInt(input.publicAsset), extHash, ...input.nf];
  } else {
    input.cm = outputs.map((n) => n.cm); input.outOwner = outputs.map((n) => n.addr.owner);
    input.outValue = outputs.map((n) => n.value); input.outRseed = outputs.map((n) => n.rseed);
    body = { ...common, commitments: input.cm, recipientCiphertexts: S.cat(...outputs.map((n) => n.ct)), recoveryCiphertext: S.sealOutgoing(poolId, recoveryKey || keys.ovk, outputs) };
    cid = direct ? 6 : nIn === 8 ? 2 : 1;
    extHash = S.extHashOf(direct ? S.canonicalDirectBody(poolId, 1n, body, direct.context) : S.canonicalBody(2, cid, poolId, 1n, tip, S.TRANSFER_BODY, body));
    words = S.transferPub(input.noteDomain, numAssets, body, extHash);
    if (direct) {
      Object.assign(input, { newRoot: direct.context.newRoot, ownIndex: direct.context.expectedNext,
        absorbIndex: direct.deposit?.entry || 0, absorbPartial: direct.deposit?.w[0] || 0n,
        absorbValue: direct.deposit?.w[1] || 0n, absorbAsset: direct.deposit?.w[2] || 0n,
        absorbSib: direct.deposit ? tree.entryPath(direct.deposit.entry) : Array(30).fill(0n),
        ownSib: membership.entryPath(Number(direct.context.expectedNext)) });
      words.push(input.newRoot, BigInt(input.ownIndex), BigInt(input.absorbIndex), input.absorbPartial, input.absorbValue, input.absorbAsset);
    }
  }
  input.extHash = extHash;
  if (hashed) input.stmt = S.statementOf(words);
  return { input, body, cid, words, publicSignals: (hashed ? [input.stmt] : words).map(String), outputs, extHash };
}
function directContext({ poolId, tree, records, accStart, inserted, ownIndex, outputs, beneficiary }) {
  assert(records.length <= 4);
  const deposits = records.filter((r) => r.kind === 1); assert(deposits.length <= 1);
  assert(records.every((r) => r.kind === 1 || r.kind === 3));
  const membershipTree = cloneTree(tree);
  const deposit = deposits[0];
  if (deposit) membershipTree.insertEntry(deposit.entry, S.leavesOf(deposit.kind, deposit.w));
  const resultTree = cloneTree(membershipTree); resultTree.insertEntry(ownIndex, outputs.map((n) => n.cm));
  const acc = records.reduce((a, r) => S.accStep(a, r.kind, r.w, r.extHash, r.tip), accStart);
  const pending = records.map(({ kind, w, extHash, tip }) => ({ kind, w, extHash, tip }));
  return { membershipTree, resultTree, deposit, pending, context: { expectedInserted: inserted, expectedNext: ownIndex,
    expectedInsertedAcc: accStart, expectedQueueAcc: acc, newRoot: resultTree.root(), rewardBeneficiary: beneficiary, pendingHash: S.pendingHash(pending) } };
}
function batch({ poolId, tree, records, start, accStart, beneficiary, maxK = 16 }) {
  assert(records.length > 0 && records.length <= maxK);
  const t = cloneTree(tree), k = records.length;
  const fields = { poolId, chainId: 1n, circuitId: maxK === 1 ? 4n : 5n, oldRoot: tree.root(), start: BigInt(start), k: BigInt(k), accStart, beneficiary: BigInt(beneficiary) };
  const input = { kind: [], w: [], extHash: [], tip: [], sib: [] };
  let acc = accStart, tips = 0n;
  for (let i = 0; i < maxK; i++) {
    const rec = records[i];
    if (rec) {
      input.kind.push(rec.kind); input.w.push(rec.w); input.extHash.push(rec.extHash); input.tip.push(rec.tip); input.sib.push(t.entryPath(start + i));
      t.insertEntry(start + i, S.leavesOf(rec.kind, rec.w));
      acc = S.accStep(acc, rec.kind, rec.w, rec.extHash, rec.tip); tips += rec.tip;
    } else { input.kind.push(3); input.w.push([0n, 0n, 0n, 0n]); input.extHash.push(0n); input.tip.push(0n); input.sib.push(Array(30).fill(0n)); }
  }
  Object.assign(fields, { newRoot: t.root(), accEnd: acc, baseTipSum: tips });
  const bits = (bytes) => [...bytes].flatMap((b) => Array.from({ length: 8 }, (_, j) => (b >> (7 - j)) & 1));
  Object.assign(input, fields, { statement: S.batchStatement(fields), poolIdBits: bits(poolId), chainIdBits: bits(S.beN(1n, 32)) });
  delete input.poolId; delete input.chainId;
  return { input, fields, tree: t, publicSignals: [String(input.statement)] };
}
module.exports = { S, ZERO, randomField, wallet, note, cloneTree, depositRecord, spend, directContext, batch };
