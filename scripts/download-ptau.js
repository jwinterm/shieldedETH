"use strict";
const fs = require("node:fs"), path = require("node:path"), { spawnSync } = require("node:child_process");
const { BUILD, save, fileHash } = require("./artifacts");
// SHA-256 pins observed from the official PSE HTTPS mirror on 2026-10-03.
// These identify reproducible test inputs, not an independent ceremony validation.
const expected = {
  19: { sha256: "d0cadfb7d5bad6c5e0b012fb1c4bbaa3cc98fe249988f9f99d1818175e4c2015", bytes: 604073106 },
  22: { sha256: "9f50df02e370796098cecbb025d46a44c7165cac8bc5ebedd76d97f1129d9653", bytes: 4831931538 }
};
(async () => {
  if (!process.argv.slice(2).length) throw Error("Usage: node scripts/download-ptau.js 19 22");
  for (const power of process.argv.slice(2)) {
    if (!expected[power]) throw Error("Supported powers are 19 and 22");
    const file = path.join(BUILD, `ptau/ppot_0080_${power}.ptau`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const url = `https://pse-trusted-setup-ppot.s3.eu-central-1.amazonaws.com/pot28_0080/ppot_0080_${power}.ptau`;
    if (!fs.existsSync(file)) {
      console.log(`Downloading public power-${power} parameters...`);
      const p = spawnSync("curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "2", "--continue-at", "-", "--output", file + ".partial", url], { stdio: "inherit" });
      if (p.error || p.status !== 0) throw p.error || Error(`Download failed for power ${power}`);
    }
    const candidate = fs.existsSync(file) ? file : file + ".partial";
    if (fs.statSync(candidate).size !== expected[power].bytes || await fileHash(candidate) !== expected[power].sha256) throw Error(`Parameter integrity mismatch for power ${power}; remove the invalid download before retrying`);
    if (candidate !== file) fs.renameSync(candidate, file);
    save(file + ".integrity.json", { url, ...expected[power], developmentOnly: true, integrity: "SHA-256 of official HTTPS download, pinned 2026-10-03; ceremony transcript not independently verified" });
    console.log(`Power ${power}: pinned file integrity verified; development only`);
  }
})().catch((e) => { console.error(e.message); process.exit(1); });
