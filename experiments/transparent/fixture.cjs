"use strict";
const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
const assert = require("node:assert/strict"), { spawnSync } = require("node:child_process");
const { ethers } = require("ethers"), { S, wallet, note, randomField } = require("../../ref/transactions");
const { r1csHeader, sha256, save } = require("../../scripts/artifacts");
const ROOT = path.resolve(__dirname, "../.."), BUILD = path.join(ROOT, "build/transparent");
const serialize = x => JSON.stringify(x, (_, v) => typeof v === "bigint" ? String(v) : v);

async function main() {
  fs.mkdirSync(BUILD, { recursive: true });
  const compiler = path.join(ROOT, "build/toolchain/circom-2.1.9/target/release/circom");
  const version = spawnSync(compiler, ["--version"], { encoding: "utf8" });
  assert(version.status === 0 && version.stdout.includes("2.1.9"), "Circom 2.1.9 is required");
  const compile = spawnSync(compiler, ["experiments/transparent/spend12.circom", "--O2", "--r1cs", "--wasm", "--sym", "-o", BUILD], { cwd: ROOT, encoding: "utf8" });
  fs.writeFileSync(path.join(BUILD, "compile.log"), (compile.stdout || "") + (compile.stderr || ""));
  assert.equal(compile.status, 0, "Circom compilation failed; inspect build/transparent/compile.log");
  await S.init();
  const poolId = crypto.randomBytes(32), alice = wallet(poolId), bob = wallet(poolId), tree = new S.Tree();
  const source = note(poolId, alice, 100n, 1);
  tree.insertEntry(0, [source.cm, 0n, 0n, 0n]);
  const outputs = [note(poolId, bob, 30n, 1), note(poolId, alice, 70n, 1)];
  for (const output of outputs) {
    const recovered = S.open(poolId, output.keys, output.ct, output.cm, 2);
    assert.equal(recovered.value, output.value); assert.equal(recovered.asset, output.asset);
  }
  const delivery = Buffer.concat(outputs.map(n => Buffer.from(n.ct)));
  const extHash = S.toBig(ethers.utils.arrayify(ethers.utils.keccak256(S.cat(S.utf8("SETH/transparent-experiment/1"), poolId, delivery)))) & ((1n << 253n) - 1n);
  const membership = tree.path(0), domain = S.noteDomainOf(poolId);
  const input = { noteDomain: domain, numAssets: 2, root: tree.root(), publicAmount: 0, publicAsset: 0, extHash,
    nf: [S.nfReal(domain, alice.keys.nk, source.cm, 0)], cm: outputs.map(n => n.cm),
    sk: alice.keys.sk, asset: 1, inEnabled: [1], inValue: [source.value], inD: [S.toBig(alice.addr.d)],
    inRseed: [source.rseed], inPath: [membership.sib], inBits: [membership.bits], inDummySeed: [randomField()],
    outOwner: outputs.map(n => n.addr.owner), outValue: outputs.map(n => n.value), outRseed: outputs.map(n => n.rseed) };
  const wc = await require(path.join(BUILD, "spend12_js/witness_calculator.js"))(fs.readFileSync(path.join(BUILD, "spend12_js/spend12.wasm")));
  const calculate = x => wc.calculateWTNSBin(JSON.parse(serialize(x)), true);
  fs.writeFileSync(path.join(BUILD, "spend12.wtns"), Buffer.from(await calculate(input)), { mode: 0o600 });
  const cases = [{ label: "valid one-input two-output full-depth spend", passed: true }];
  for (const [label, mutate] of [
    ["inflation", x => x.outValue[0]++],
    ["wrong owner", x => x.sk = bob.keys.sk],
    ["wrong asset", x => x.asset = 0],
    ["unregistered asset", x => x.asset = 2],
    ["forged nullifier", x => x.nf[0]++],
    ["forged root", x => x.root++],
    ["wrong membership path", x => x.inPath[0][19]++],
    ["wrong high position bit", x => x.inBits[0][31] = 1],
    ["nonboolean path", x => x.inBits[0][0] = 2],
    ["disabled only input", x => x.inEnabled[0] = 0],
    ["input value overflow", x => x.inValue[0] = 1n << 128n],
    ["output value overflow", x => x.outValue[0] = 1n << 128n],
    ["zero output randomness", x => x.outRseed[0] = 0],
    ["forged output commitment", x => x.cm[1]++]
  ]) {
    const bad = structuredClone(input); mutate(bad);
    await assert.rejects(calculate(bad), /Assert Failed|Error in template/);
    cases.push({ label, passed: true });
  }
  const publicValues = [domain, 2, input.root, 0, 0, extHash, ...input.nf, ...input.cm].map(String);
  save(path.join(BUILD, "fixture.json"), { publicValues, deliveryHex: delivery.toString("hex"),
    sourceCommitment: String(source.cm), commitments: input.cm.map(String), poolId: S.hex(poolId),
    compiler: version.stdout.trim(), compilerSha256: sha256(fs.readFileSync(compiler)),
    constraints: r1csHeader(path.join(BUILD, "spend12.r1cs")), circuitTests: cases,
    recipientRecoveryTested: true, outgoingRecoveryIncluded: false,
    r1csSha256: sha256(fs.readFileSync(path.join(BUILD, "spend12.r1cs"))) });
  console.log(`Compiled ${r1csHeader(path.join(BUILD, "spend12.r1cs")).constraints} constraints; ${cases.length} circuit cases passed; both recipient ciphertexts recovered.`);
}
main().catch(e => { console.error(e.message); process.exitCode = 1; });
