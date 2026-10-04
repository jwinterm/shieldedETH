"use strict";
const fs = require("node:fs"), path = require("node:path"), solc = require("solc");
const { ROOT, BUILD, save, sha256 } = require("./artifacts");
const sources = {};
for (const dir of ["contracts", "tests/contracts"]) {
  if (!fs.existsSync(path.join(ROOT, dir))) continue;
  for (const f of fs.readdirSync(path.join(ROOT, dir)).filter((x) => x.endsWith(".sol")).sort()) {
    sources[`${dir}/${f}`] = { content: fs.readFileSync(path.join(ROOT, dir, f), "utf8") };
  }
}
const settings = { viaIR: true, optimizer: { enabled: true, runs: 10 }, evmVersion: "cancun",
  outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "storageLayout"] } } };
const out = JSON.parse(solc.compile(JSON.stringify({ language: "Solidity", sources, settings })));
for (const e of out.errors || []) if (e.severity === "error") console.error(e.formattedMessage);
if ((out.errors || []).some((e) => e.severity === "error")) process.exit(1);
const contracts = {};
for (const [file, list] of Object.entries(out.contracts)) for (const [name, c] of Object.entries(list)) {
  if (!c.evm.bytecode.object) continue;
  const runtimeBytes = c.evm.deployedBytecode.object.length / 2;
  if (runtimeBytes > 24576) throw Error(`${name} exceeds EIP-170: ${runtimeBytes} bytes`);
  contracts[name] = { source: file, abi: c.abi, bytecode: "0x" + c.evm.bytecode.object,
    runtimeBytes, runtimeTemplateSha256: sha256(Buffer.from(c.evm.deployedBytecode.object, "hex")), storageLayout: c.storageLayout };
  console.log(`${name}: ${runtimeBytes} runtime bytes`);
}
save(path.join(BUILD, "contracts.json"), { compiler: solc.version(), settings, sourceHashes: Object.fromEntries(Object.entries(sources).map(([f, s]) => [f, sha256(s.content)])), contracts });
