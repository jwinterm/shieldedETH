"use strict";
// Candidate fail-closed witness harness. Pin snarkjs/compiler versions and review diagnostic matching.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

async function expectWitness({ name, buildDir, input, shouldAccept, snarkjsCli }) {
  assert.match(name, /^[a-zA-Z0-9_-]+$/);
  assert.equal(typeof shouldAccept, "boolean");
  // Missing artifacts are infrastructure errors, never proof of rejection.
  const wasm = path.join(buildDir, `main_${name}_js/main_${name}.wasm`);
  const calc = path.join(buildDir, `main_${name}_js/witness_calculator.js`);
  const r1cs = path.join(buildDir, `main_${name}.r1cs`);
  for (const file of [wasm, calc, r1cs, snarkjsCli]) fs.accessSync(file, fs.constants.R_OK);
  const builder = require(path.resolve(calc));
  const wc = await builder(fs.readFileSync(wasm));
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "seth8-witness-"));
  let accepted = false;
  let reason = "";
  try {
    let bin;
    try { bin = await wc.calculateWTNSBin(input, 0); }
    catch (err) {
      if (!/Assert Failed/i.test(String(err))) throw err;
      reason = "constraint assertion";
    }
    if (!bin && !reason) throw Error("witness generator returned no witness or constraint rejection");
    if (bin) {
      const file = path.join(tmp, "candidate.wtns");
      fs.writeFileSync(file, bin);
      const result = spawnSync(process.execPath, [snarkjsCli, "wtns", "check", r1cs, file],
        { encoding: "utf8", timeout: 180000, maxBuffer: 8 * 1024 * 1024 });
      if (result.error || result.signal || result.status === null) {
        throw result.error || Error(`infrastructure failure: ${result.signal}`);
      }
      const text = `${result.stdout}\n${result.stderr}`;
      if (result.status === 0 && /WITNESS IS CORRECT/.test(text)) accepted = true;
      else if (/WITNESS IS NOT CORRECT|Constraint doesn't match/i.test(text)) reason = "unsatisfied constraint";
      else throw Error(`unclassified checker failure (${result.status}): ${text}`);
    }
    assert.equal(accepted, shouldAccept, `${name}: expected ${shouldAccept ? "acceptance" : "rejection"}; ${reason}`);
    return { name, accepted, checked: true };
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}
module.exports = { expectWitness };
// A caller must await every case and set a failing process exit code on any exception.
// Check both directions: deliberately invert a known honest and a known invalid fixture in CI.
