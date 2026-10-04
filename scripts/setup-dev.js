"use strict";
// Local test keys only. No phase-2 ceremony, no deployment authorization.
const fs = require("node:fs"), path = require("node:path"), snarkjs = require("snarkjs");
const { BUILD, json, save, fileHash } = require("./artifacts");
async function main() {
  if (!process.argv.includes("--development-only")) throw Error("Refusing setup without --development-only: these keys are never suitable for accepting funds.");
  const names = process.argv.slice(2).filter((x) => x !== "--development-only");
  if (!names.length) throw Error("Name at least one compiled circuit.");
  const manifest = json(path.join(BUILD, "circuits/manifest.json"));
  const directory = path.join(BUILD, "development-keys"); fs.mkdirSync(directory, { recursive: true });
  for (const name of names) {
    const m = manifest[name]; if (!m) throw Error(`${name} has not been compiled`);
    const power = m.constraints + m.publicInputs + 1 <= 2 ** 19 ? 19 : 22;
    const ptau = path.join(BUILD, `ptau/ppot_0080_${power}.ptau`);
    const verified = json(ptau + ".integrity.json");
    if (verified.bytes !== fs.statSync(ptau).size || verified.sha256 !== await fileHash(ptau)) throw Error("Powers-of-tau digest mismatch");
    const r1cs = path.join(BUILD, `circuits/main_${name}.r1cs`);
    if (m.r1csSha256 !== await fileHash(r1cs)) throw Error(`${name}: compiled R1CS digest mismatch`);
    const key = path.join(directory, `${name}.zkey`), record = key + ".json";
    if (fs.existsSync(record) && fs.existsSync(key) && json(record).r1csSha256 === m.r1csSha256 && json(record).ptauSha256 === verified.sha256 && json(record).zkeySha256 === await fileHash(key)) {
      console.log(`${name}: cached development key`); continue;
    }
    console.log(`${name}: generating DEVELOPMENT ONLY Groth16 key`);
    const start = performance.now();
    const result = await snarkjs.zKey.newZKey(r1cs, ptau, key, { info() {}, debug() {}, error(msg) { throw Error(msg); } });
    if (result === -1) throw Error(`${name}: Groth16 setup refused`);
    const vk = await snarkjs.zKey.exportVerificationKey(key);
    if (vk.nPublic !== m.publicInputs) throw Error(`${name}: verifier arity mismatch`);
    save(path.join(directory, `${name}.vk.json`), vk);
    save(record, { developmentOnly: true, ceremony: "uncontributed phase-2 initialization; never production", r1csSha256: m.r1csSha256, ptauSha256: verified.sha256, zkeySha256: await fileHash(key), setupSeconds: (performance.now() - start) / 1000 });
    console.log(`${name}: key ready (${((performance.now() - start) / 1000).toFixed(1)} seconds)`);
  }
}
main().then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
