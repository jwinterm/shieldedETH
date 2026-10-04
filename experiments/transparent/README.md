# Transparent spend feasibility experiment

Status: research only; production closed. Measurements and source digests are
recorded in the [generated evidence](../../benchmarks/transparent-spend.json).

This experiment tests a one-input, two-output, depth-32 spend using the existing
BN254/Poseidon note relation and the pinned ProveKit Spartan/WHIR implementation.
It evaluates proof transport against the solo-payment gas target before
contract verification and state-transition costs are included.

The measured scope is native proof generation and verification, adversarial
checks, and signed Prague transactions carrying proof bytes. The transport
transactions do not verify proofs, spend notes, check nullifiers or insert outputs.
Their gas is a lower bound for this encoding, not a complete-payment benchmark.
They carry both transcript bytes and required out-of-band authentication hints.

## Reproduce

Prerequisites: root `npm ci`, the repository's Circom 2.1.9 bootstrap, and Rust
1.98.0. No ceremony, Groth16 key or production credential is used by this
experiment. All notes and wallets are newly generated synthetic test data.

```sh
sh experiments/transparent/bootstrap.sh
node experiments/transparent/run.cjs
node experiments/transparent/run.cjs --check
npm run docs -- --check
```

Bootstrap downloads pinned public dependencies. Subsequent runs compile Rust
offline with the lockfile. ProveKit lives under `build/transparent/vendor` and
must have the recorded revision and no local changes. Rust dependencies, build
outputs and private synthetic witnesses remain under `build/transparent`.
The separate npm manifest leaves the v0.8 baseline's VM and dependency lock
unchanged. `run.cjs` owns the benchmark JSON and paper excerpt; regenerate them
with that command rather than editing generated files.

## Relation and binding

`spend12.circom` instantiates the existing `Transfer(1, 2, 32)` template. The
measured fixture is a pure transfer with a recipient output and change. It
retains 128-bit amounts, hidden asset selection, full-depth membership,
ownership, output commitments and the position-bound nullifier. All nine public
inputs are bound by the proof transcript. Recipient ciphertexts use the existing
109-byte encoding, and both are decrypted in the test.

The experiment uses a separate delivery-binding domain. It is not a new v0.8
wire profile. Outgoing recovery, fee delivery, withdrawal admission and pool
state transitions are not implemented here. The generic relation still exposes
public-amount fields; a future pool must enforce their operation-specific rules.

The Rust adapter strictly imports the Circom R1CS and witness field encodings,
checks `A*w * B*w = C*w` independently, and calls the unchanged upstream prover
and verifier. Its field adapter selects BN254 and upstream Keccak conventions.
It uses direct sparse matrix verification on the host; that host verification
cost is not an Ethereum gas estimate.

## Privacy finding

Both Spartan sumcheck blinding and the zero-knowledge witness commitment mode
are enabled. Upstream nevertheless sends witness-dependent alpha evaluations in
the clear. The source explicitly documents that a hiding witness commitment
alone does not establish full proof zero knowledge.

The executable counterexample has two identical constraints `x * 1 = x`. Here
`x` is a private witness unconstrained by the public input. After verifying the
valid proof, a transcript reader recovers `x` from the first alpha evaluation.
This disproves generic zero knowledge for the tested construction. It does not
establish extraction of payment keys or notes from the payment fixture. No
synthetic private value is printed or stored in the evidence.

## Cost experiment

The default upstream profile and twelve witness-commitment tuning profiles use
the same upstream 128-bit Johnson-bound target and 10-bit per-slot proof-of-work
budget. Tuned profiles vary folding factors 1 through 4 and initial log inverse
rates 2, 4 and 6, with the adaptive planner biased toward smaller proofs. The
separate Spartan blinding commitment retains its upstream parameters. This is
a bounded parameter search, not a claim of global optimality or an independent
security analysis of upstream parameter formulas.

Each profile verifies the real spend proof and rejects changed public inputs,
corrupted/truncated proof and authentication data, trailing transcript bytes,
wrong circuits and a proof generated from an invalid private witness. The
privacy counterexample is reproduced for each profile. Circuit witness tests
also reject inflation, wrong ownership, membership, assets, ranges, commitments
and nullifiers.

The selected profile minimizes the exact calldata floor in this run. A signed
transaction in EthereumJS under Prague confirms that floor independently of the
byte-count calculation. A second transport transaction adds public inputs, ABI
framing and the two recipient ciphertexts. No claim is made that another encoding,
another WHIR implementation or another transparent proof system shares this cost.

## Evaluation status

| Property | Result |
|---|---|
| Ceremony-free native proofs | Verified with pinned dependencies |
| Full-depth spend constraints | Acceptance and adversarial rejection tests pass |
| Complete proof transport | Includes required authentication data and Prague receipts |
| Full proof zero knowledge | Rejected by an executable counterexample |
| Solidity verification and complete solo payment | Not implemented |
| Pool state, insertion and full wallet delivery | Not integrated |
| Independent cryptographic and implementation review | Not established |

Failure of either the privacy check or the proof-transport gas ceiling keeps
the candidate closed. A cheaper prover or a smaller circuit cannot by itself
clear either condition.
