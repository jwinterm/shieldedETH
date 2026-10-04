"use strict";
const { test, before } = require("node:test"), assert = require("node:assert/strict"), crypto = require("node:crypto");
const { S, wallet, note, randomField } = require("../ref/transactions");
before(async () => S.init());
test("recipient and outgoing recovery validate asset, ownership, and ciphertext context", () => {
  const poolId = crypto.randomBytes(32), a = wallet(poolId), b = wallet(poolId);
  const outputs = [note(poolId, b, 9n, 1), note(poolId, a, 10n, 1), note(poolId, b, 1n, 1), note(poolId, a, 0n, 1)];
  assert.equal(S.parseAddress(b.addr.text, poolId).owner, b.addr.owner);
  assert.equal(S.open(poolId, b.keys, outputs[0].ct, outputs[0].cm, 2).value, 9n);
  assert.equal(S.open(poolId, a.keys, outputs[0].ct, outputs[0].cm, 2), null);
  const out = S.sealOutgoing(poolId, a.keys.ovk, outputs), cms = outputs.map((o) => o.cm), cts = outputs.map((o) => o.ct);
  assert.equal(out.length, 400);
  assert.deepEqual(S.openOutgoing(poolId, a.keys.ovk, cms, cts, out, 2).map((n) => n.value), outputs.map((n) => n.value));
  assert.equal(S.openOutgoing(poolId, b.keys.ovk, cms, cts, out, 2), null);
  const bad = out.slice(); bad[0] ^= 1;
  assert.equal(S.openOutgoing(poolId, a.keys.ovk, cms, cts, bad, 2), null);
  assert.equal(S.openOutgoing(poolId, a.keys.ovk, cms.toReversed(), cts, out, 2), null);
});
test("hostile delivery rejects locally and scanning continues", () => {
  const poolId = crypto.randomBytes(32), a = wallet(poolId), n = note(poolId, a, 1n, 0);
  const malformed = [new Uint8Array(0), new Uint8Array(109), new Uint8Array(109).fill(255), n.ct.slice(1)];
  const bad = n.ct.slice(); bad[50] ^= 1; malformed.push(bad);
  for (const ct of malformed) assert.equal(S.open(poolId, a.keys, ct, n.cm, 2), null);
  assert.equal(S.open(poolId, a.keys, n.ct, n.cm, 2).value, 1n);
  assert.throws(() => S.parseAddress(a.addr.text + "=", poolId));
  assert.throws(() => S.parseAddress(a.addr.text, crypto.randomBytes(32)));
});
test("gift sweep outgoing recovery uses independently selected recipient capability", () => {
  const poolId = crypto.randomBytes(32), gift = wallet(poolId), recipient = wallet(poolId);
  const outputs = [7n, 0n, 0n, 0n].map((v) => note(poolId, recipient, v, 0));
  const ct = S.sealOutgoing(poolId, recipient.keys.ovk, outputs), cms = outputs.map((o) => o.cm), cts = outputs.map((o) => o.ct);
  assert(S.openOutgoing(poolId, recipient.keys.ovk, cms, cts, ct, 2));
  assert.equal(S.openOutgoing(poolId, gift.keys.ovk, cms, cts, ct, 2), null);
  for (const n of outputs) assert.equal(S.open(poolId, gift.keys, n.ct, n.cm, 2), null);
});
test("tree paths preserve unsigned positions across all 32 bits", () => {
  const tree = new S.Tree();
  for (const e of [0, 1, 2 ** 29 - 1, 2 ** 29, 2 ** 30 - 1]) {
    const leaves = Array.from({ length: 4 }, randomField); tree.insertEntry(e, leaves);
    for (let j = 0; j < 4; j++) {
      const pos = 4 * e + j, { sib, bits } = tree.path(pos);
      assert.equal(S.fold(leaves[j], sib, bits), tree.root());
      assert.equal(bits.reduce((n, b, i) => n + b * 2 ** i, 0), pos);
    }
  }
});
test("queue scheduler always chooses an authenticated available endpoint", () => {
  for (let start = 0; start < 64; start++) for (const backlog of [1, 15, 16, 17, 1023, 1024, 1040, 4097]) {
    const n = start + backlog, step = S.nextBatch(start, n);
    assert(step.k >= 1 && step.k <= 16);
    assert(step.end === n || step.end % 16 === 0);
    assert.equal(step.end, step.start + step.k);
  }
  let cursor = 1;
  while (cursor < 1041) cursor = S.nextBatch(cursor, 1041).end;
  assert.equal(cursor, 1041);
});
test("queue byte encoding agrees with an independently assembled SHA-256 preimage", () => {
  const acc = 123n, kind = 1, words = [99n, 1000n, 1n, 0n], ext = 456n, tip = 7n;
  const b = Buffer.alloc(209);
  const put = (offset, size, value) => { const hex = value.toString(16).padStart(size * 2, "0"); Buffer.from(hex, "hex").copy(b, offset); };
  put(0, 32, acc); b[32] = kind; words.forEach((v, i) => put(33 + i * 32, 32, v)); put(161, 32, ext); put(193, 16, tip);
  const expected = BigInt("0x" + crypto.createHash("sha256").update(b).digest("hex")) & ((1n << 253n) - 1n);
  assert.equal(S.accStep(acc, kind, words, ext, tip), expected);
});
