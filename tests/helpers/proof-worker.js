"use strict";
const path = require("node:path"), snarkjs = require("snarkjs");
const { BUILD, json } = require("../../scripts/artifacts");
process.once("message", async ({ name, input }) => {
  try {
    const start = performance.now(), witness = { type: "mem" };
    await snarkjs.wtns.calculate(input, path.join(BUILD, `circuits/main_${name}_js/main_${name}.wasm`), witness);
    const witnessSeconds = (performance.now() - start) / 1000, provingStart = performance.now();
    const { proof, publicSignals } = await snarkjs.groth16.prove(path.join(BUILD, `development-keys/${name}.zkey`), witness);
    const provingSeconds = (performance.now() - provingStart) / 1000;
    const valid = await snarkjs.groth16.verify(json(path.join(BUILD, `development-keys/${name}.vk.json`)), publicSignals, proof);
    if (!valid) throw Error("Generated proof failed independent snarkjs verification");
    const cd = JSON.parse("[" + await snarkjs.groth16.exportSolidityCallData(proof, publicSignals) + "]");
    process.send({ ok: true, proof: cd.slice(0, 3), publicSignals, stats: { circuit: name, witnessSeconds, provingSeconds, maxRssKiB: process.resourceUsage().maxRSS, workers: require("node:os").cpus().length } }, () => process.exit(0));
  } catch (e) { process.send({ ok: false, error: e.message }, () => process.exit(1)); }
});
