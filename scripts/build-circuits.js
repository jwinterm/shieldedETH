"use strict";
const fs = require("node:fs"), path = require("node:path"), { spawnSync } = require("node:child_process");
const { ROOT, BUILD, sha256, json, save, r1csHeader } = require("./artifacts");
const names = ["transfer24", "transfer84", "exit", "direct", "batch1", "transfer24h", "transfer84h", "exith", "directh", "batch16"];
const selected = process.argv.slice(2).length ? process.argv.slice(2) : names;
for (const name of selected) if (!names.includes(name)) throw Error(`Unknown circuit: ${name}`);
const compiler = process.env.SETH_CIRCOM || path.join(BUILD, "toolchain/circom-2.1.9/target/release/circom");
const version = spawnSync(compiler, ["--version"], { encoding: "utf8" });
if (version.error || version.status !== 0 || !version.stdout.includes("2.1.9")) throw Error("Circom 2.1.9 is required. Run scripts/bootstrap-circom.sh or set SETH_CIRCOM.");
const out = path.join(BUILD, "circuits"); fs.mkdirSync(out, { recursive: true });
const manifestFile = path.join(out, "manifest.json");
const manifest = fs.existsSync(manifestFile) ? json(manifestFile) : {};
for (const name of selected) {
  const deps = ["lib", name.startsWith("batch") ? "batch" : "transfer", ...(name.endsWith("h") ? ["hashed"] : []), `main_${name}`];
  const inputHash = sha256("circom-2.1.9-O2:" + JSON.stringify(deps.map((f) => fs.readFileSync(path.join(ROOT, `circuits/${f}.circom`), "utf8"))) + fs.readFileSync(path.join(ROOT, "package-lock.json"), "utf8"));
  const r1cs = path.join(out, `main_${name}.r1cs`);
  if (manifest[name]?.inputHash === inputHash && fs.existsSync(r1cs) && fs.existsSync(path.join(out, `main_${name}_js/main_${name}.wasm`))) { console.log(`${name}: cached compiled artifacts`); continue; }
  const start = performance.now();
  console.log(`Compiling ${name} at depth 32...`);
  const result = spawnSync(compiler, [`circuits/main_${name}.circom`, "--O2", "--r1cs", "--wasm", "--sym", "-o", out], { cwd: ROOT, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  fs.writeFileSync(path.join(out, `${name}.compile.log`), (result.stdout || "") + (result.stderr || ""));
  if (result.error || result.status !== 0) throw result.error || Error(`${name} compile failed: ${result.stderr}`);
  manifest[name] = { inputHash, compiler: version.stdout.trim(), optimization: "O2", ...r1csHeader(r1cs), compileSeconds: (performance.now() - start) / 1000, r1csSha256: sha256(fs.readFileSync(r1cs)), wasmSha256: sha256(fs.readFileSync(path.join(out, `main_${name}_js/main_${name}.wasm`))) };
  save(manifestFile, manifest);
  console.log(`${name}: ${manifest[name].constraints} constraints, ${manifest[name].publicInputs} public inputs, ${manifest[name].compileSeconds.toFixed(1)} seconds`);
}
