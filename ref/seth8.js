// ShieldedETH v0.8 reference model (non-constant-time; for vectors and tests only).
// Deps: circomlibjs@0.1.7, @noble/curves@1.6.0, @noble/hashes@1.5.0, @noble/ciphers@1.0.0, ethers@5
"use strict";
const { buildPoseidonReference } = require("circomlibjs");
const { RistrettoPoint } = require("@noble/curves/ed25519");
const { sha256 } = require("@noble/hashes/sha256");
const { sha512 } = require("@noble/hashes/sha512");
const { hkdf, extract, expand } = require("@noble/hashes/hkdf");
const { chacha20poly1305 } = require("@noble/ciphers/chacha");
const { ethers } = require("ethers");

const r = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const L25519 = 2n ** 252n + 27742317777372353535851937790883648493n; // ristretto255 group order
const MASK253 = (1n << 253n) - 1n;
const VERSION = 8;
const T = { AK: 1n, NK: 2n, OWNER: 3n, PART: 4n, CM: 5n, NF: 6n, DUMMY: 7n, NODE: 8n };
const KIND = { DEPOSIT: 1, TRANSFER: 2, EXIT: 3 }; // record kind == operation code
const CIRCUIT = { TRANSFER_2_4: 1, TRANSFER_8_4: 2, EXIT_2_0: 3, BATCH_1: 4, BATCH_UPTO_16: 5, TRANSFER_2_4_DIRECT: 6 };

const utf8 = (s) => new TextEncoder().encode(s);
const cat = (...a) => { const n = a.reduce((s, x) => s + x.length, 0); const o = new Uint8Array(n); let i = 0; for (const x of a) { o.set(x, i); i += x.length; } return o; };
const beN = (x, n) => { if (BigInt(x) < 0n || !Number.isSafeInteger(n) || n < 1) throw Error("bad unsigned integer"); const o = new Uint8Array(n); let v = BigInt(x); for (let i = n - 1; i >= 0; i--) { o[i] = Number(v & 0xffn); v >>= 8n; } if (v) throw Error("overflow"); return o; };
const toBig = (b) => BigInt("0x" + (Buffer.from(b).toString("hex") || "0"));
const toBigLE = (b) => toBig(Uint8Array.from(b).reverse());
const H253 = (digest) => toBig(digest) & MASK253;
const hex = (b) => "0x" + Buffer.from(b).toString("hex");
const b64u = (b) => Buffer.from(b).toString("base64url");

let _P;
async function init() { const p = await buildPoseidonReference(); _P = (tag, xs) => p.F.toObject(p(xs, tag)); }
const P = (tag, ...xs) => _P(tag, xs); // PoseidonEx(n,1).out[0] with initialState = tag

// ---------- keys (HKDF-SHA256) ----------
function walletKeys(seed) {
  if (!(seed instanceof Uint8Array) || seed.length !== 32) throw Error("seed length");
  const prk = extract(sha256, seed, sha256(utf8("ShieldedETH/v0.8/wallet")));
  let sk, ivk;
  for (let c = 0; ; c++) { sk = toBig(expand(sha256, prk, cat(utf8("sk/"), beN(c, 4)), 32)); if (sk >= 1n && sk < r) break; }
  for (let c = 0; ; c++) { ivk = toBigLE(expand(sha256, prk, cat(utf8("ivk/"), beN(c, 4)), 64)) % L25519; if (ivk !== 0n) break; }
  const ovk = expand(sha256, prk, utf8("ovk"), 32);
  return { sk, ak: P(T.AK, sk), nk: P(T.NK, sk), ivk, ovk };
}
const baseFor = (d) => RistrettoPoint.hashToCurve(sha512(cat(utf8("SETH/v8/div"), d)));
function address(keys, d, poolId) {
  if (d.length !== 11 || poolId.length !== 32) throw Error("address inputs");
  const Hd = baseFor(d), pkd = Hd.multiply(keys.ivk);
  if (Hd.equals(RistrettoPoint.ZERO) || pkd.equals(RistrettoPoint.ZERO)) throw Error("identity point");
  const owner = P(T.OWNER, keys.ak, toBig(d));
  const payload = cat(Uint8Array.of(VERSION), poolId.slice(0, 8), d, beN(owner, 32), pkd.toRawBytes());
  const check = sha256(cat(utf8("SETH/v8/address"), payload)).slice(0, 8);
  return { d, owner, pkd, Hd, text: "seth8:" + b64u(cat(payload, check)) };
}

function parseAddress(text, poolId) {
  if (typeof text !== "string" || !/^seth8:[A-Za-z0-9_-]{123}$/.test(text) || poolId.length !== 32) throw Error("noncanonical address");
  const encoded = text.slice(6), raw = new Uint8Array(Buffer.from(encoded, "base64url"));
  if (raw.length !== 92 || b64u(raw) !== encoded || raw[0] !== VERSION) throw Error("address encoding");
  const payload = raw.slice(0, 84), check = sha256(cat(utf8("SETH/v8/address"), payload)).slice(0, 8);
  if (hex(check) !== hex(raw.slice(84)) || hex(raw.slice(1, 9)) !== hex(poolId.slice(0, 8))) throw Error("address checksum or pool tag");
  const d = raw.slice(9, 20), owner = toBig(raw.slice(20, 52));
  if (owner >= r) throw Error("noncanonical owner");
  const Hd = baseFor(d), pkd = RistrettoPoint.fromHex(raw.slice(52, 84));
  if (Hd.equals(RistrettoPoint.ZERO) || pkd.equals(RistrettoPoint.ZERO)) throw Error("identity address key");
  return { d, owner, pkd, Hd, text };
}

// ---------- notes ----------
const partialOf = (owner, rseed) => P(T.PART, owner, rseed);
const cmOf = (partial, value, asset) => P(T.CM, partial, value, BigInt(asset));
const nfReal = (noteDomain, nk, cm, pos) => P(T.NF, noteDomain, nk, cm, BigInt(pos));
const nfDummy = (noteDomain, seed, slot) => P(T.DUMMY, noteDomain, seed, BigInt(slot));

// ---------- delivery (109-byte recipient ciphertext) ----------
function eskOf(poolId, rseed) {
  for (let c = 0; ; c++) { const e = toBigLE(sha512(cat(utf8("SETH/v8/esk"), poolId, beN(rseed, 32), beN(c, 4)))) % L25519; if (e) return e; }
}
function seal(poolId, addr, value, asset, rseed, cm) {
  if (value < 0n || value >= (1n << 128n) || !Number.isInteger(asset) || asset < 0 || asset >= 8 || rseed <= 0n || rseed >= r || cm <= 0n || cm >= r) throw Error("note range");
  if (cmOf(partialOf(addr.owner, rseed), value, asset) !== cm) throw Error("note commitment mismatch");
  const esk = eskOf(poolId, rseed), epk = addr.Hd.multiply(esk), ss = RistrettoPoint.fromHex(addr.pkd.toRawBytes()).multiply(esk);
  const ctx = cat(Uint8Array.of(VERSION), poolId, beN(cm, 32), epk.toRawBytes());
  const m = expand(sha256, extract(sha256, ss.toRawBytes(), sha256(utf8("SETH/v8/note"))), ctx, 44);
  const pt = cat(Uint8Array.of(VERSION), beN(value, 16), Uint8Array.of(asset), addr.d, beN(rseed, 32));
  return { esk, ct: cat(epk.toRawBytes(), chacha20poly1305(m.slice(0, 32), m.slice(32, 44), ctx).encrypt(pt)) };
}
function open(poolId, keys, ct, cm, numAssets) {
  if (!_P) throw Error("reference model not initialized");
  if (!Number.isInteger(numAssets) || numAssets < 2 || numAssets > 8) throw Error("manifest asset count");
  if (!keys || keys.ivk <= 0n || keys.ivk >= L25519) throw Error("invalid local viewing key");
  if (!(ct instanceof Uint8Array) || ct.length !== 109 || poolId.length !== 32 || cm <= 0n || cm >= r) return null;
  // All attacker-controlled point parsing and cryptography stay inside the rejection boundary.
  try {
    const epkB = ct.slice(0, 32), epk = RistrettoPoint.fromHex(epkB);
    if (epk.equals(RistrettoPoint.ZERO)) return null;
    const ss = epk.multiply(keys.ivk);
    const ctx = cat(Uint8Array.of(VERSION), poolId, beN(cm, 32), epkB);
    const m = expand(sha256, extract(sha256, ss.toRawBytes(), sha256(utf8("SETH/v8/note"))), ctx, 44);
    const pt = chacha20poly1305(m.slice(0, 32), m.slice(32, 44), ctx).decrypt(ct.slice(32));
    if (pt.length !== 61 || pt[0] !== VERSION) return null;
    const value = toBig(pt.slice(1, 17)), asset = pt[17], d = pt.slice(18, 29), rseed = toBig(pt.slice(29, 61));
    if (asset >= numAssets || rseed === 0n || rseed >= r) return null;
    const Hd = baseFor(d);
    if (Hd.equals(RistrettoPoint.ZERO) || !Hd.multiply(eskOf(poolId, rseed)).equals(epk)) return null;
    const owner = P(T.OWNER, keys.ak, toBig(d));
    return cmOf(partialOf(owner, rseed), value, asset) === cm ? { value, asset, d, rseed, owner } : null;
  } catch { return null; }
}

const outgoingContext = (poolId, cms, cts) => sha256(cat(utf8("SETH/v8/out-context"), poolId, ...cms.map((x) => beN(x, 32)), ...cts));
function sealOutgoing(poolId, recoveryKey, outputs) {
  if (recoveryKey.length !== 32 || outputs.length !== 4) throw Error("outgoing recovery inputs");
  const ctx = outgoingContext(poolId, outputs.map((o) => o.cm), outputs.map((o) => o.ct));
  const key = expand(sha256, extract(sha256, recoveryKey, sha256(utf8("SETH/v8/out"))), ctx, 44);
  const records = cat(...outputs.map((o) => cat(beN(o.addr.owner, 32), o.addr.pkd.toRawBytes(), beN(o.esk, 32))));
  return chacha20poly1305(key.slice(0, 32), key.slice(32), ctx).encrypt(records);
}
function openOutgoing(poolId, recoveryKey, cms, cts, ciphertext, numAssets) {
  if (!_P || recoveryKey.length !== 32 || !Number.isInteger(numAssets) || numAssets < 2 || numAssets > 8) throw Error("outgoing recovery configuration");
  try {
    if (poolId.length !== 32 || cms.length !== 4 || cts.length !== 4 || ciphertext.length !== 400 || cts.some((ct) => ct.length !== 109)) return null;
    const ctx = outgoingContext(poolId, cms, cts);
    const key = expand(sha256, extract(sha256, recoveryKey, sha256(utf8("SETH/v8/out"))), ctx, 44);
    const records = chacha20poly1305(key.slice(0, 32), key.slice(32), ctx).decrypt(ciphertext);
    return cms.map((cm, i) => {
      const rec = records.slice(i * 96, (i + 1) * 96), owner = toBig(rec.slice(0, 32)), pkd = RistrettoPoint.fromHex(rec.slice(32, 64)), esk = toBig(rec.slice(64));
      if (owner >= r || esk === 0n || esk >= L25519 || pkd.equals(RistrettoPoint.ZERO)) throw Error("outgoing record range");
      const ct = cts[i], epk = RistrettoPoint.fromHex(ct.slice(0, 32));
      if (epk.equals(RistrettoPoint.ZERO)) throw Error("identity ephemeral key");
      const noteCtx = cat(Uint8Array.of(VERSION), poolId, beN(cm, 32), epk.toRawBytes());
      const m = expand(sha256, extract(sha256, pkd.multiply(esk).toRawBytes(), sha256(utf8("SETH/v8/note"))), noteCtx, 44);
      const pt = chacha20poly1305(m.slice(0, 32), m.slice(32), noteCtx).decrypt(ct.slice(32));
      if (pt.length !== 61 || pt[0] !== VERSION) throw Error("outgoing plaintext");
      const value = toBig(pt.slice(1, 17)), asset = pt[17], d = pt.slice(18, 29), rseed = toBig(pt.slice(29));
      if (asset >= numAssets || rseed === 0n || rseed >= r || eskOf(poolId, rseed) !== esk || !baseFor(d).multiply(esk).equals(epk) || cmOf(partialOf(owner, rseed), value, asset) !== cm) throw Error("outgoing opening mismatch");
      return { value, asset, d, rseed, owner };
    });
  } catch { return null; }
}


// ---------- pool identity, queue, tree ----------
function poolIdOf(chainId, poolAddr, salt) {
  return ethers.utils.arrayify(ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(
    ["bytes32", "uint16", "uint256", "address", "bytes32"],
    [ethers.utils.keccak256(utf8("ShieldedETH")), VERSION, chainId, poolAddr, salt])));
}
const noteDomainOf = (poolId) => toBig(poolId) & MASK253;
const acc0Of = (poolId) => H253(sha256(cat(utf8("SETH/v8/acc"), poolId)));
function recordBytes(acc, kind, w, extHash, tip) { // 209 bytes
  return cat(beN(acc, 32), Uint8Array.of(kind), ...w.map((x) => beN(x, 32)), beN(extHash, 32), beN(tip, 16));
}
const accStep = (acc, kind, w, extHash, tip) => H253(sha256(recordBytes(acc, kind, w, extHash, tip)));
function leavesOf(kind, w) { return kind === KIND.DEPOSIT ? [cmOf(w[0], w[1], w[2]), 0n, 0n, 0n] : w.slice(); }

let Z;
function zeros() { if (!Z) { Z = [0n]; for (let h = 0; h < 32; h++) Z.push(P(T.NODE, Z[h], Z[h])); } return Z; }
class Tree { // sparse depth-32 tree, entries = aligned 4-leaf subtrees
  constructor() { this.nodes = new Map(); zeros(); }
  get(h, i) { return this.nodes.get(h + ":" + i) ?? Z[h]; }
  set(h, i, v) { this.nodes.set(h + ":" + i, v); }
  insertEntry(e, leaves) {
    if (!Number.isSafeInteger(e) || e < 0 || e >= 2 ** 30 || leaves.length !== 4) throw Error("entry bounds");
    leaves.forEach((x, j) => this.set(0, 4 * e + j, x));
    this.set(1, 2 * e, P(T.NODE, leaves[0], leaves[1]));
    this.set(1, 2 * e + 1, P(T.NODE, leaves[2], leaves[3]));
    let q = 2 * e;
    for (let h = 1; h < 32; h++) { q = Math.floor(q / 2); this.set(h + 1, q, P(T.NODE, this.get(h, 2 * q), this.get(h, 2 * q + 1))); }
  }
  root() { return this.get(32, 0); }
  entryPath(e) { const sib = []; for (let h = 2; h < 32; h++) sib.push(this.get(h, (Math.floor(e / 2 ** (h - 2)) % 2 === 0 ? Math.floor(e / 2 ** (h - 2)) + 1 : Math.floor(e / 2 ** (h - 2)) - 1))); return sib; }
  path(pos) { if (!Number.isSafeInteger(pos) || pos < 0 || pos >= 2 ** 32) throw Error("position bounds"); const sib = [], bits = []; let i = pos; for (let h = 0; h < 32; h++) { sib.push(this.get(h, (i % 2 === 0 ? i + 1 : i - 1))); bits.push(i % 2); i = Math.floor(i / 2); } return { sib, bits }; }
}
function fold(leaf, sib, bits) { let x = leaf; for (let h = 0; h < sib.length; h++) x = bits[h] ? P(T.NODE, sib[h], x) : P(T.NODE, x, sib[h]); return x; }

// ---------- batch statement ----------
function batchStatement(s) {
  const enc = ethers.utils.defaultAbiCoder.encode(
    ["bytes32", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
    [s.poolId, s.chainId, s.circuitId, s.oldRoot, s.newRoot, s.start, s.k, s.accStart, s.accEnd, s.baseTipSum, s.beneficiary]);
  return H253(sha256(ethers.utils.arrayify(enc)));
}

// ---------- canonical bodies ----------
const BODY_TAG = ethers.utils.keccak256(utf8("SETH/v8/BODY"));
const HDR = ["bytes32", "uint16", "uint8", "uint8", "bytes32", "uint256", "uint128"];
const TRANSFER_BODY = "tuple(uint64 rootSeq,uint256 root,uint256[] nullifiers,uint256[4] commitments,uint128 W,uint8 publicAsset,uint128 tip,address recipient,uint32 payoutGas,address executor,uint64 deadline,bytes32 nonce,bytes recipientCiphertexts,bytes recoveryCiphertext)";
const EXIT_BODY = "tuple(uint64 rootSeq,uint256 root,uint256[2] nullifiers,uint128 W,uint8 publicAsset,uint128 tip,address recipient,uint32 payoutGas,address executor,uint64 deadline,bytes32 nonce)";
const DEPOSIT_BODY = "tuple(uint8 asset,uint256 partial,uint128 amount,uint128 tip,bytes ciphertext)";
function canonicalBody(op, circuitId, poolId, chainId, V, schema, body) {
  return ethers.utils.defaultAbiCoder.encode([...HDR, schema], [BODY_TAG, VERSION, op, circuitId, poolId, chainId, V, body]);
}
const DIRECT_CONTEXT = "tuple(uint40 expectedInserted,uint40 expectedNext,uint256 expectedInsertedAcc,uint256 expectedQueueAcc,uint256 newRoot,address rewardBeneficiary,bytes32 pendingHash)";
const PENDING_RECORD = "tuple(uint8 kind,uint256[4] w,uint256 extHash,uint128 tip)";
function pendingHash(records) { return ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([PENDING_RECORD + "[]"], [records])); }
function canonicalDirectBody(poolId, chainId, b, d) {
  return ethers.utils.defaultAbiCoder.encode([...HDR, TRANSFER_BODY, DIRECT_CONTEXT], [BODY_TAG, VERSION, KIND.TRANSFER, CIRCUIT.TRANSFER_2_4_DIRECT, poolId, chainId, 0n, b, d]);
}
const extHashOf = (bodyBytes) => H253(ethers.utils.arrayify(ethers.utils.keccak256(bodyBytes)));

// ---------- insertion scheduling ----------
function nextBatch(inserted, queued, stride = 16) {
  if (![inserted, queued, stride].every(Number.isSafeInteger) || inserted < 0 || queued < inserted || queued > 2 ** 30 || stride !== 16) throw Error("scheduler bounds");
  if (inserted >= queued) return null;
  const end = Math.min(queued, stride * (Math.floor(inserted / stride) + 1));
  return { start: inserted, k: end - inserted, end };
}

// ---------- v0.8 statements ----------
/** Native public-input vector for a queued TRANSFER_2_4 (v0.7 order). */
function transferPub(noteDomain, numAssets, b, extHash) {
  const pubAmt = BigInt(b.W) === 0n ? 0n : r - BigInt(b.W);
  return [noteDomain, BigInt(numAssets), BigInt(b.root), pubAmt, BigInt(b.publicAsset), extHash, ...b.nullifiers.map(BigInt), ...b.commitments.map(BigInt)];
}
/** v0.8 hashed profile: H253(SHA256(u256be(w0) || ... )). */
function statementOf(words) { return H253(sha256(cat(...words.map((w) => beN(BigInt(w), 32))))); }
module.exports = { parseAddress, sealOutgoing, openOutgoing, transferPub, statementOf, init, r, L25519, T, KIND, CIRCUIT, VERSION, P, walletKeys, address, partialOf, cmOf, nfReal, nfDummy, seal, open,
  poolIdOf, noteDomainOf, acc0Of, recordBytes, accStep, leavesOf, zeros, Tree, fold, batchStatement, canonicalBody,
  extHashOf, nextBatch, canonicalDirectBody, pendingHash, DIRECT_CONTEXT, PENDING_RECORD, TRANSFER_BODY, EXIT_BODY, DEPOSIT_BODY, beN, toBig, hex, cat, utf8, H253 };
