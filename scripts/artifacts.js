"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const ROOT = path.resolve(__dirname, "..");
const BUILD = path.join(ROOT, "build");
const sha256 = (data) => crypto.createHash("sha256").update(data).digest("hex");
const json = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
function save(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file + ".tmp", JSON.stringify(value, (_, v) => typeof v === "bigint" ? v.toString() : v, 2) + "\n");
  fs.renameSync(file + ".tmp", file);
}
function sourceFiles(dirs = ["contracts", "circuits", "ref", "scripts", "tests"]) {
  const result = {};
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const e of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else result[path.relative(ROOT, p)] = sha256(fs.readFileSync(p));
    }
  };
  dirs.forEach((d) => walk(path.join(ROOT, d)));
  for (const file of ["package.json", "package-lock.json"]) result[file] = sha256(fs.readFileSync(path.join(ROOT, file)));
  return result;
}
async function fileHash(file) {
  const h = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) h.update(chunk);
  return h.digest("hex");
}
function r1csHeader(file) {
  const fd = fs.openSync(file, "r");
  const read = (n, pos) => { const b = Buffer.alloc(n); if (fs.readSync(fd, b, 0, n, pos) !== n) throw Error("Truncated R1CS"); return b; };
  try {
    const head = read(12, 0);
    if (head.toString("ascii", 0, 4) !== "r1cs" || head.readUInt32LE(4) !== 1) throw Error("Unsupported R1CS");
    let pos = 12;
    for (let i = 0; i < head.readUInt32LE(8); i++) {
      const section = read(12, pos), size = Number(section.readBigUInt64LE(4)); pos += 12;
      if (section.readUInt32LE(0) === 1) {
        const b = read(size, pos), offset = 4 + b.readUInt32LE(0);
        return { wires: b.readUInt32LE(offset), publicOutputs: b.readUInt32LE(offset + 4), publicInputs: b.readUInt32LE(offset + 8), privateInputs: b.readUInt32LE(offset + 12), constraints: b.readUInt32LE(offset + 24) };
      }
      pos += size;
    }
    throw Error("R1CS header missing");
  } finally { fs.closeSync(fd); }
}
module.exports = { ROOT, BUILD, sha256, fileHash, json, save, sourceFiles, r1csHeader };
