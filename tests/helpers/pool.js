"use strict";
const assert = require("node:assert/strict"), path = require("node:path"), crypto = require("node:crypto");
const { ethers } = require("ethers");
const { BUILD, json, sha256 } = require("../../scripts/artifacts");
const { EVM, good, rejected, vkArgs } = require("./evm");
const { prove } = require("./proofs");
const T = require("../../ref/transactions"), { S } = T;
class Pool {
  static async create(profile) {
    const p = new Pool(); p.e = await EVM.create(); p.profile = profile; p.proofs = []; p.checks = [];
    p.numAssets = 3; p.records = []; p.accs = []; p.tree = new S.Tree(); p.inserted = 0; p.notes = []; p.topups = new Map();
    const suffix = profile === "hashed" ? "h" : "", verifierNames = ["transfer24" + suffix, "transfer84" + suffix, "exit" + suffix, "batch1", "batch16", "direct" + suffix];
    p.verifiers = {};
    for (const name of verifierNames) p.verifiers[name] = await p.e.deploy("SethGroth16Verifier", vkArgs(json(path.join(BUILD, `development-keys/${name}.vk.json`))), `deploy verifier ${name}`);
    p.tokens = [null, await p.e.deploy("TestToken"), await p.e.deploy("TestToken")];
    p.pool = await p.e.deploy("ShieldedETHPool", [[ethers.utils.hexlify(crypto.randomBytes(32)), 86400, 200000,
      [[T.ZERO, 10n ** 24n, 10n ** 24n, 0, 0], ...p.tokens.slice(1).map((t) => [t.address, 10n ** 24n, 10n ** 24n, 100000, 30000])],
      ...verifierNames.map((n) => p.verifiers[n].address), profile === "hashed" ? 78 : 0]], "deploy pool");
    p.poolId = ethers.utils.arrayify(await p.e.read(p.pool, "poolId")); p.accs = [S.acc0Of(p.poolId)];
    p.alice = T.wallet(p.poolId); p.bob = T.wallet(p.poolId); p.fee = T.wallet(p.poolId);
    for (const token of p.tokens.slice(1)) { good(await p.e.call(token, "mint", [p.e.address, 10n ** 20n])); good(await p.e.call(token, "approve", [p.pool.address, ethers.constants.MaxUint256])); }
    assert.equal(BigInt(await p.e.read(p.pool, "EMPTY_ROOT")), S.zeros()[32]);
    return p;
  }
  circuit(name) { return this.profile === "hashed" && !name.startsWith("batch") ? name + "h" : name; }
  note(owner, value, asset = 1) { return T.note(this.poolId, owner, value, asset); }
  async prove(name, input, expected) {
    const result = await prove(name, input, expected); this.proofs.push(result.stats);
    console.log(`[${this.profile}] ${name}: proof ${(result.stats.witnessSeconds + result.stats.provingSeconds).toFixed(2)} s`);
    return result.proof;
  }
  record(rec, event) {
    assert.equal(Number(event.args.entry), this.records.length);
    assert.equal(event.args.extHash.toBigInt(), rec.extHash);
    assert.deepEqual(event.args.words.map((x) => x.toBigInt()), rec.w);
    this.records.push({ ...rec, entry: this.records.length });
    this.accs.push(S.accStep(this.accs.at(-1), rec.kind, rec.w, rec.extHash, rec.tip));
  }
  async deposit(n, tip = 0n, label = "single token deposit") {
    const entry = this.records.length;
    const r = good(await this.e.call(this.pool, "deposit", [n.asset, n.partial, n.value, n.ct], tip + (n.asset === 0 ? n.value : 0n), label));
    this.record(T.depositRecord(this.poolId, n, tip, entry), r.events.find((x) => x.name === "EntryPublished"));
    n.pos = entry * 4; this.notes.push(n); await this.invariants(); return r;
  }
  async depositMany(notes, tip = 0n) {
    const first = this.records.length, pulls = BigInt(await this.e.read(this.tokens[1], "pulls"));
    const items = notes.map((n) => [n.asset, n.partial, n.value, tip, n.ct]);
    const value = notes.reduce((v, n) => v + tip + (n.asset === 0 ? n.value : 0n), 0n);
    const r = good(await this.e.call(this.pool, "depositMany", [items], value, `depositMany ${notes.length}`));
    const events = r.events.filter((x) => x.name === "EntryPublished");
    notes.forEach((n, i) => { this.record(T.depositRecord(this.poolId, n, tip, first + i), events[i]); n.pos = (first + i) * 4; this.notes.push(n); });
    if (notes.some((n) => n.asset === 1)) assert.equal(BigInt(await this.e.read(this.tokens[1], "pulls")), pulls + 1n);
    await this.invariants(); return r;
  }
  async spend(inputs, outputs, options = {}) {
    const circuit = this.circuit(options.name || "transfer24");
    const tx = T.spend({ poolId: this.poolId, numAssets: this.numAssets, inputs, outputs, tree: this.tree, rootSeq: BigInt(await this.e.read(this.pool, "rootSeq")), ...options, circuit });
    tx.inputs = inputs; tx.proof = await this.prove(circuit, tx.input, tx.publicSignals); return tx;
  }
  apply(tx, r, direct) {
    const entry = this.records.length, exit = tx.cid === 3;
    this.record({ kind: exit ? 3 : 2, w: exit ? [0n, 0n, 0n, 0n] : tx.body.commitments, extHash: tx.extHash, tip: tx.body.tip }, r.events.find((x) => x.name === "EntryPublished"));
    tx.inputs.forEach((n) => { assert(!n.spent, "ledger double spend"); n.spent = true; });
    tx.outputs.forEach((n, i) => { n.pos = entry * 4 + i; this.notes.push(n); });
    if (direct) { this.tree = direct.resultTree; this.inserted = this.records.length; }
    else if (exit && this.inserted === entry && tx.body.tip === 0n) this.inserted++;
  }
  async send(tx, label = "single queued transfer") {
    const r = good(await this.e.call(this.pool, tx.cid === 3 ? "exit" : "transact", tx.cid === 3 ? [tx.proof, tx.body] : [tx.cid, tx.proof, tx.body], tx.body.tip, label));
    this.apply(tx, r); await this.invariants(); return r;
  }
  direct(outputs) {
    return T.directContext({ poolId: this.poolId, tree: this.tree, records: this.records.slice(this.inserted), accStart: this.accs[this.inserted], inserted: this.inserted, ownIndex: this.records.length, outputs, beneficiary: this.e.address });
  }
  async sendDirect(tx, direct) {
    const r = good(await this.e.call(this.pool, "transactDirect", [tx.proof, tx.body, direct.context, direct.pending], 0n, "direct first deposit"));
    this.apply(tx, r, direct); await this.invariants(); return r;
  }
  async insert(k = 1, maxK = 1, mutate = false) {
    const b = T.batch({ poolId: this.poolId, tree: this.tree, records: this.records.slice(this.inserted, this.inserted + k), start: this.inserted, accStart: this.accs[this.inserted], beneficiary: this.e.address, maxK });
    const name = maxK === 1 ? "batch1" : "batch16", pf = await this.prove(name, b.input, b.publicSignals), f = b.fields;
    const args = [Number(f.circuitId), f.start, f.oldRoot, f.accStart, k, f.newRoot, f.baseTipSum, this.e.address, pf];
    if (mutate) { const bad = args.slice(); bad[7] = this.tokens[1].address; rejected(await this.e.call(this.pool, "insertBatch", bad), "BadProof"); await this.invariants(); }
    const r = good(await this.e.call(this.pool, "insertBatch", args, 0n, `insert ${k} via ${name}`));
    this.tree = b.tree; this.inserted += k; await this.invariants(); return r;
  }
  async invariants() {
    assert.equal(Number(await this.e.read(this.pool, "nextEntry")), this.records.length);
    assert.equal(Number(await this.e.read(this.pool, "insertedEntries")), this.inserted);
    assert.equal(BigInt(await this.e.read(this.pool, "currentRoot")), this.tree.root());
    assert.equal(BigInt(await this.e.read(this.pool, "knownAcc", [this.records.length])), this.accs.at(-1));
    assert.equal(BigInt(await this.e.read(this.pool, "insertedAcc")), this.accs[this.inserted]);
    let ethLiability;
    for (let a = 0; a < this.numAssets; a++) {
      const expected = this.notes.filter((n) => !n.spent && n.asset === a).reduce((v, n) => v + n.value, 0n);
      const liability = BigInt(await this.e.read(this.pool, "liability", [a]));
      assert.equal(liability, expected, `plaintext note ledger for asset ${a}`);
      if (a === 0) ethLiability = liability;
      else assert(BigInt(await this.e.read(this.tokens[a], "balanceOf", [this.pool.address])) >= liability);
    }
    const tips = this.records.slice(this.inserted).reduce((v, r) => v + r.tip + (this.topups.get(r.entry) || 0n), 0n);
    assert.equal(BigInt(await this.e.read(this.pool, "T")), tips);
    const credit = BigInt(await this.e.read(this.pool, "C"));
    assert.equal(credit, BigInt(await this.e.read(this.pool, "credit", [this.e.address])));
    assert(await this.e.balance(this.pool.address) >= ethLiability + tips + credit);
  }
}
module.exports = { Pool, T, S, good, rejected };
