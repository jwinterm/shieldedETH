"use strict";
const path = require("node:path"), { fork } = require("node:child_process"), assert = require("node:assert/strict");
const { BUILD, json, fileHash } = require("../../scripts/artifacts");
const checked = new Map();
async function prove(name, input, expected) {
  if (!checked.has(name)) {
    const manifest = json(path.join(BUILD, "circuits/manifest.json"))[name];
    const key = path.join(BUILD, `development-keys/${name}.zkey`), metadata = json(key + ".json");
    assert(metadata.developmentOnly && metadata.r1csSha256 === manifest.r1csSha256, `${name}: stale setup`);
    assert.equal(await fileHash(key), metadata.zkeySha256, `${name}: key hash mismatch`);
    assert.equal(await fileHash(path.join(BUILD, `circuits/main_${name}.r1cs`)), manifest.r1csSha256, `${name}: R1CS hash mismatch`);
    assert.equal(await fileHash(path.join(BUILD, `circuits/main_${name}_js/main_${name}.wasm`)), manifest.wasmSha256, `${name}: witness generator hash mismatch`);
    checked.set(name, true);
  }
  return new Promise((resolve, reject) => {
    const child = fork(path.join(__dirname, "proof-worker.js"), [], { serialization: "advanced", stdio: ["ignore", "ignore", "pipe", "ipc"], execArgv: ["--max-old-space-size=18000"] });
    let returned = false;
    child.on("message", (result) => {
      returned = true;
      if (!result.ok) { reject(Error(`${name}: ${result.error}`)); return; }
      try { if (expected) assert.deepEqual(result.publicSignals, expected.map(String), `${name}: public input order mismatch`); resolve(result); } catch (e) { reject(e); }
    });
    child.on("error", reject);
    child.on("exit", (code, signal) => { if (!returned) reject(Error(`${name}: prover exited before returning a proof (${signal || code})`)); });
    // Diagnostics must never include witness inputs or wallet secrets.
    child.stderr.resume();
    child.send({ name, input });
  });
}
module.exports = { prove };
