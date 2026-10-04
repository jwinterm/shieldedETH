# ShieldedETH v0.8

Executable research candidate: Solidity contracts, depth-32 Circom relations,
reference wallet primitives, adversarial tests and measured evidence.

**Production activation is closed.** The
[production design requires no trusted setup](docs/ShieldedETH_v0_8_Core_Delta.md#proof-system-requirement-and-activation).
The implemented Groth16 backend is a measured research baseline and does not meet
that requirement. Its keys are development-only and must never secure funds.
There is no production deployment command or external audit.

- [Current v0.8 specification](docs/ShieldedETH_v0_8_Core_Delta.md)
- [Paper source](docs/shieldedeth.qmd) and [rendered PDF](docs/shieldedeth.pdf)
- [Measured results](docs/_generated/benchmarks.md)
- [Raw evidence, receipts and artifact hashes](benchmarks/v0.8.json)
- [Transparent spend experiment and reproduction](experiments/transparent/README.md),
  with [separate native-proof and Prague transport evidence](benchmarks/transparent-spend.json).
  The tested candidate fails the privacy and solo gas gates; it is not a replacement backend.

The v0.7 documents are historical design context. An earlier v0.8 draft is
[archived](docs/archive/ShieldedETH_v0_8_2026-09-30.md); its numerical claims and
embedded code are superseded by executable sources and regenerated evidence.

## Reproduce

Requirements: Node 22 to 24, npm, Rust/Cargo, a C toolchain, curl, and shasum.
The recorded run uses macOS arm64, Node 24, Circom 2.1.9 and snarkjs 0.7.5.
Allow substantial disk space and memory: public parameters alone occupy about
5.1 GiB, with circuit builds and proving keys additional. Full setup and proof
tests take appreciably longer than the unit lane. Dependencies are pinned in
`package-lock.json`; no production credentials are required. Dependency audit
results depend on the advisory database at execution time. This is a development
toolchain, not a reviewed wallet SDK.

```sh
npm ci --ignore-scripts
npm run check
sh scripts/bootstrap-circom.sh
npm run build:circuits
npm run test:circuits
node scripts/download-ptau.js 19 22
node --max-old-space-size=18000 scripts/setup-dev.js --development-only \
  transfer24 transfer84 exit direct batch1 batch16 \
  transfer24h transfer84h exith directh
npm run test:integration
npm run docs
npm run docs -- --check
```

The bootstrap script builds the checksum-pinned Circom 2.1.9 source archive.
An existing compiler can be selected with `SETH_CIRCOM`. Public phase-one files
come from the [PSE ceremony mirror](https://github.com/privacy-ethereum/perpetualpowersoftau#prepared-phase-2-files).
Their SHA-256 pins identify the downloaded inputs; we have not independently
validated the ceremony transcript. Phase-two initialization is deliberately
labeled development-only. A download, setup, witness or proof failure stops its
lane; it is never treated as a passing rejection test.

`npm run check` rebuilds contracts and runs fast reference, EVM accounting and
ETH-side kernel tests. Circuit tests and integration proofs are separate explicit
lanes. `npm run test:integration -- native` or `-- hashed` runs one profile.
`npm run bench` reruns the same real-proof lifecycle workload used for gas and
proving measurements. Random notes and proofs stay ephemeral; private witnesses
and development proving artifacts are excluded from source control.

Test evidence records hashes of implementation, test and build sources. Changing
those files requires rerunning the affected evidence lanes before regenerating
the report. The generator currently uses one conservative source set for every
lane, so a test-tool change invalidates all lane receipts. It refuses to present
old results as measurements of new code.

## What the measurements mean

Transactions use `@ethereumjs/vm` 8.1.1 under Cancun with real BN254 pairings and
actual depth-32 relation proofs. Each transaction is signed and executed through
`VM.runTx`. Reports retain execution gas, intrinsic gas, refunds, total charged
gas and calldata size/hash. The ordered workload includes both fresh writes and
updates; it is not a ring-wrap steady-state benchmark. Small gas variation is
expected from randomized calldata. ERC-20 measurements use the local test token;
they are not measurements of a particular mainnet token implementation.

Proof timings include witness generation and Groth16 proving in a fresh Node
process. Setup, compilation and verification are excluded. Sample counts and
ranges are reported, without treating a few lifecycle samples as p95 latency.
Phone, browser, production-network and third-party comparison results are not
established here.

The independent note ledger checks per-asset liability and backing, while the
reference model checks queue records, accumulators and roots. E2 tests isolate
the ETH-side kernel with a pool fixture; they do not establish a Monero swap.

## Regenerate the paper

Generated files under `docs/_generated/` and `benchmarks/v0.8.json` are owned by
`scripts/update-evidence.js`. Edit sources and rerun the lanes, then generate them.
The PDF is generated from `docs/shieldedeth.qmd`, never edited directly.

Install Quarto and Tectonic locally, then run:

```sh
SETH_QUARTO=/path/to/quarto sh scripts/render-paper.sh
```

The recorded renderer is Quarto 1.10.18 and Tectonic 0.17.0. The script also
supports tools in `build/toolchain/bin/` and `build/toolchain/tectonic/`. Rendering
may download public TeX packages to its local cache. It does not publish anything.

## Limitations

The shared tree does not guarantee a uniform cross-asset anonymity set. A
broadcaster paid in a shielded output learns the transfer asset. Asset admission
and exact transfer checks cannot make a malicious token's balance reporting
honest. These boundaries are documented in the paper.

An implemented and reviewed transparent proof system, state-machine fuzzing, history-ring
wrap and reorganization drills, client-device benchmarks, and network services
are required before production use. Inboxes, memos, pending-transfer absorption
and permissionless assets remain unimplemented proposals.

## Licensing

Existing file-level licenses apply. Solidity sources identify the MIT license;
this repository makes no additional license grant for other original material.
The unmodified IEEE citation style in `docs/ieee.csl` retains its author credits
and Creative Commons Attribution-ShareAlike 3.0 license. External dependencies
retain their respective licenses.
