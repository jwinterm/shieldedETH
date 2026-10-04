# ShieldedETH v0.8: implemented research candidate

Production activation: closed.

The source in `contracts/`, `circuits/` and `ref/` owns the implementation. The
[paper](shieldedeth.qmd) explains the design; [generated measurements](_generated/benchmarks.md)
and [raw evidence](../benchmarks/v0.8.json) record what the tests actually establish.
Build instructions live in the [project README](../README.md).

v0.7 is inherited design context, not the current executable release. Unchanged
note, queue, tree, delivery and canonical-encoding rules come from
[v0.7 Core](ShieldedETH_v0_7_Core.md). v0.8 is not wire-compatible with v0.7:
`VERSION = 8`, domain strings use `SETH/v8/`, and addresses use `seth8:`.
An [earlier candidate](archive/ShieldedETH_v0_8_2026-09-30.md) is retained as
historical context. Its embedded code and stand-in-proof measurements are
superseded by the executable implementation and generated evidence.

## Implemented scope

| Component | Source | Scope |
|---|---|---|
| Immutable pool | [ShieldedETHPool.sol](../contracts/ShieldedETHPool.sol) | Allowlisted ETH/ERC-20 assets, liabilities, queue, roots, spends and insertion credits |
| Generic Groth16 verifier | [SethGroth16Verifier.sol](../contracts/SethGroth16Verifier.sol) | Single verification and randomized batch verification |
| Spend relations | [transfer.circom](../circuits/transfer.circom) | Depth 32, 2-to-4, 8-to-4, exit and direct mode |
| Insertion relations | [batch.circom](../circuits/batch.circom) | One entry and up to sixteen entries, including full maxK=16 |
| Hashed statements | [hashed.circom](../circuits/hashed.circom) | Alias-checked canonical words, SHA-256, one public input |
| Reference wallet primitives | [seth8.js](../ref/seth8.js) | Keys, addresses, recipient/outgoing recovery, encodings, trees and scheduler |
| Witness construction | [transactions.js](../ref/transactions.js) | Real note ownership, conservation, membership and insertion witnesses |
| E2 ETH-side kernel | [XmrSwapKernel.sol](../contracts/XmrSwapKernel.sol) | v8 signing domain and pool pin; isolated lifecycle tests |

No network wallet, indexer, broadcaster service, production batcher, permissionless
asset profile or Monero swap service is included. Reference JavaScript is not a
reviewed constant-time wallet implementation.

## Proof-system requirement and activation

**No trusted setup is a production design requirement.**
Soundness must not depend on any party destroying secret setup material. Public,
reproducible parameter derivation is permitted. This requirement covers every
spend, exit, direct and insertion proof, plus any recursive or aggregation layer
that Ethereum relies on. A universal ceremony or a trusted-setup proof wrapper
does not satisfy it. Zero knowledge, conservation, permissionless submission and
Ethereum L1 enforcement remain requirements.

The current Groth16 implementation is retained as a tested research baseline;
it does not meet this production requirement. No qualifying replacement backend
has been implemented. Its verifier, proof format, batching equation and
gas measurements cannot be carried over as evidence for a transparent design.

The isolated [transparent spend experiment](../experiments/transparent/README.md)
implements native Spartan/WHIR proofs for a one-input, two-output depth-32 relation.
Its [separate evidence](../benchmarks/transparent-spend.json) records a reproduced
generic zero-knowledge counterexample and proof-transport gas above the ceiling
below for every tested profile. These are native proof and Prague transport tests,
not Solidity proof verification or complete-payment benchmarks. The candidate is
rejected at this gate; a full verifier port and pool integration are not implemented.

**Solo-payment gas target:** prefer 500,000 gas or less,
with 1,000,000 gas as the provisional prototype ceiling. Measure a complete
payment, including proof calldata, verification, nullifier and pool state
updates, encrypted delivery data, and insertion of its output commitments.
Deferred insertion costs belong to that payment. Batch amortization does not
establish the solo target, and a verifier-only benchmark is insufficient.

Prototype comparisons must name the Ethereum fork and apply its transaction
pricing rules, including the calldata floor where active. The existing Cancun
receipts remain historical baseline evidence. Compare matching input/output
counts, tree capacity and storage conditions; disclose any changes to security
parameters or privacy. Smaller common-payment relations may be explored, but
their results must not be presented as measurements of the existing 2-to-4 or
8-to-4 relations. These targets do not establish that a qualifying backend exists.

Groth16 requires trusted setup. Local tests use public PSE phase-one parameters
and uncontributed phase-two development keys for the actual circuits. Downloads
are pinned by SHA-256 for repeatability; this work has not independently verified
the phase-one transcript. Development keys must never secure funds.

Production remains closed pending an implemented transparent proof system,
independent circuit, contract and cryptographic review, frozen artifact hashes,
and operational testing. A ceremony cannot qualify the Groth16 baseline for
release under the requirement above. The repository has no production deployment
command.

## Aggregator lane

`transactBatch(proofs, bodies)` accepts 1 to 16 independent `TRANSFER_2_4`
proofs, with public withdrawal `W = 0`. The canonical body and its hash are
identical to the single-transfer lane. A user's proof can therefore be submitted
through either lane without re-proving.

The pool performs static validation, then skips entries made stale by an expired
deadline, an evicted root, a spent nullifier or a nullifier already included earlier
in this batch. Malformed entries fail the entire transaction. An invalid included
proof also fails the entire transaction. All-stale batches fail `NothingIncluded`.

`msg.value` equals all submitted tips. Included tips enter pending insertion
liability `T`; skipped tips become pull credit for the submitter. Their aggregate
uses `uint256` throughout, including when several individually valid `uint128`
tips sum above that range. Tree-capacity refusal precedes proof verification.

The verifier hashes chain ID, verifier address, every proof and every public
input into its Fiat-Shamir transcript. For coefficients `r_i`, it checks:

```text
product_i e(-r_i A_i, B_i)
  * e(sum_i r_i alpha, beta)
  * e(sum_i r_i IC_0 + sum_j (sum_i r_i x_ij) IC_j, gamma)
  * e(sum_i r_i C_i, delta) = 1
```

This uses `n + 3` pairings. The coefficient for the first proof is one; later
coefficients are Keccak-derived field elements, with zero mapped to one.
Soundness depends on the random-oracle argument and the precompiles' curve and
subgroup validation. Tests of malformed inputs do not replace that review.

## Statement profiles

`hashedMask` is immutable. Bits 1, 2, 3 and 6 select the hashed versions of
2-to-4 transfer, 8-to-4 transfer, exit and direct mode. Native public-input counts
are 12, 18, 8 and 18; hashed versions each have one input:

```text
stmt = H253(SHA256(u256be(word_0) || ... || u256be(word_k-1)))
```

The constructor checks verifier arity. Insertion circuits always have one public
input. The evaluation runs an all-native profile (`hashedMask = 0`) and an
all-hashed spend profile (`hashedMask = 78`); this is not a production profile
selection. Desktop proof samples do not establish mobile or browser latency.

## Multi-deposit and insertion

`depositMany` accepts 1 to 64 items. Each carries an asset, hiding partial
commitment, amount, tip and 109-byte ciphertext. Token totals are pulled once per
asset; exact sender debit and pool credit are checked. Each item produces the
same canonical record as a corresponding single deposit, including its individual
ETH amount and tip in the body header. All items share one public payer.

Batch insertion authenticates consecutive queue records, computes deposit
commitments, checks empty destination slots and updates the depth-32 tree.
The reward beneficiary is part of the proven statement. Direct mode inserts its
own outputs and may absorb one pending deposit among at most four pending
records; pending transfers cannot be absorbed. Zero-leaf exits can advance the
queue without changing the root.

## Evidence and measurement method

`npm run check` compiles contracts and runs reference, transaction-accounting and
E2 kernel tests. `npm run test:circuits` checks accepted and rejected witnesses,
including deliberately inverted expectations and missing-artifact failures.
`npm run test:integration` proves the actual relations and submits signed
transactions through `VM.runTx` under Cancun rules. It compares contract
liabilities with an independent plaintext note ledger after lifecycle transitions
and rejected operations.

The integration workload covers first-note direct spends, onward transfers,
withdrawals, exits, eight-input consolidation, full and partial sixteen-entry
insertion, aggregate transfers with stale skips, malformed proofs, exact token
movement, payout refusal, reentrancy, top-ups, zero-entry skipping and credits.
Integer-boundary cases use artificial VM state and are excluded from gas tables.
E2 tests use a pool fixture and establish only the kernel's ETH-side behavior.

Every measured operation is a complete transaction. Reports retain execution gas,
intrinsic gas, refunds, total charged gas, calldata size/hash and receipt status.
Fresh access warmth and original-storage accounting are regression-tested. The
ordered lifecycle changes storage state, so it must not be described as a uniform
fresh-state or ring-wrap steady-state benchmark. Proofs use randomized test notes;
small calldata-gas variation between runs is expected.

`npm run docs` generates the JSON evidence and paper tables from successful test
reports. It refuses stale source hashes or missing real-proof coverage. Generated
files are never edited directly. There are no inherited numerical claims about
Tornado Cash, Nova or RAILGUN in the current evaluation.

## Privacy and asset-failure boundaries

A shared note tree hides the asset in a pure transfer's public fields. It does
not establish a uniform anonymity set across every unspent note. Timing,
deposits, withdrawals and participant knowledge narrow candidates. A broadcaster
that receives a shielded fee output learns its asset and value, and therefore
the transfer's asset under the single-asset relation.

Exact balance-change checks reject observable short delivery and surcharge
behavior. They do not make an arbitrary token honest: malicious `balanceOf`,
issuer confiscation, rebasing and upgrade behavior remain asset risks. A paused
token's failed payout rolls back its transaction; local tests also show that the
pause does not prevent an unrelated ETH exit.

## E2 compatibility and limitations

The E2 migration changes all three version commitments: `VERSION`, the required
pool version, and EIP-712 domain version `"8"`. Tests reject signatures under
version `"7"`, preserve credit across failed delivery, prohibit same-block
delivery after claim, and exercise refunds and withdrawals. They do not establish
Monero-side correctness or end-to-end atomicity.

Production requires implemented and reviewed transparent proofs, long-run
state-machine fuzzing, history-ring wrap, backlog and reorganization tests,
mobile/browser benchmarks, and network service operation. Inboxes, memos,
pending-transfer absorption and permissionless assets remain unimplemented. The
pool's EIP-170 headroom is reported by the generated build evidence; adding an
extension requires a separate architecture and storage-layout review.
