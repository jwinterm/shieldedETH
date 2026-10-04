> Historical draft. See [current v0.8](../ShieldedETH_v0_8_Core_Delta.md). Embedded code and gas figures are not current build inputs or evidence.

# ShieldedETH v0.8: Core Delta: Aggregator Lane, Statement Profiles, Multi-Deposit

**Date:** 30 September 2026
**Status:** Implementation candidate with compiled code and executed tests (see §0). Not audited, no production setup, not authorization to accept funds.
**Applies on top of:** `ShieldedETH_v0_7_Core.md` (with its E1 and E2 companions). Everything not changed here is as in v0.7. v0.8 is not wire-compatible with v0.7: protocol `VERSION = 8`, every `SETH/v7/…` domain string becomes `SETH/v8/…`, and addresses use the `seth8:` prefix.
**Scope:** proposed protocol changes and historical prototype measurements. The current v0.8 specification supersedes this draft's release plan and trusted-setup assumptions.

---

## 0. Evidence for this candidate

The draft reports the following checks. Their original receipts are not part of the current evidence package. Rows marked *derived* combine reported measurements with arithmetic.

| Artifact | Check | Result |
|---|---|---|
| v0.7 batch circuit | Compile | The v0.7 source **does not compile** (circom rejects a conditional component type and a mixed-template component array). Fixed with `BEBitsField()` and separate components (Appendix C). BATCH_1: 320,128 constraints |
| `SethGroth16Verifier` (new, Appendix B) | Real BN254 pairings in ethereumjs VM (Cancun), against snarkjs-generated verifiers for the same keys, k = 1 and k = 3 | Agrees with snarkjs on valid and invalid proofs. Batch verification accepts n = 1…16 valid proofs and rejects all 6 malformed variants per k (input off by one, swapped inputs, foreign C point, noncanonical coordinate, input ≥ r, wrong input count). 46 assertions |
| Hashed-statement circuits (Appendix C) | circom 2.1.9 compile | TRANSFER_2_4_H: 238,587 constraints. EXIT_2_0_H: 173,355. TRANSFER_2_4_DIRECT_H: 363,386. TRANSFER_8_4_H: 388,293. Each has 1 public input |
| Hashed circuits ↔ reference | Fail-closed witness checks (v0.7 `expectWitness`) | 8/8 behave as expected. Accepted: the first-note direct transaction sequence, a spend with public withdrawal, an exit. Rejected: statement off by one; a hashed word changed with the statement kept (newRoot, extHash, publicAsset, amount) |
| Pool v0.8 (Appendix A) | solc 0.8.26, viaIR, optimizer runs = 10, Cancun | **24,343-byte runtime, 233 bytes under EIP-170** (see §7) |
| Pool ↔ reference ↔ verifier, **real pairings** | Both profiles (native and hashed), using development stand-in circuits with production public-input counts, so verification gas equals production | `depositMany` of 20 items pulls tokens once, and its records are byte-identical to single deposits. `insertBatch` k = 16 passes. A single transfer passes. `transactBatch`: 14 included, 2 stale entries skipped (duplicate nullifier, already spent), and a batch containing one wrong proof reverts `BadProof`. Each batch entry's `extHash` equals its single-lane `extHash` (lane-agnostic proofs) |
| E2 kernel (v0.7 source) | Compile after changing its version pin from 7 to 8 | 8,140-byte runtime; not re-run |

**Not established:**
- proving times for the production circuits (full setup was not completed);
- real spend-relation proofs through the pool at production depth (the stand-in circuits exercise the verifier and statement interface, not the spend relation);
- BATCH_UPTO_16 compilation at maxK = 16 (memory);
- audits;
- the production ceremony.

---

## 1. Decisions

| Topic | Decision |
|---|---|
| Efficiency roadmap | Stays on Ethereum L1. Cheaper execution under weaker trust assumptions is not counted as protocol efficiency. |
| Aggregator | **On-chain Groth16 batch verification** of independent user proofs. No recursion, no new proof system, no trusted aggregator, no change to user proofs. |
| Public-input hashing | A **per-circuit, immutable deployment flag** (`hashedMask`), decided by testnet proving benchmarks (§4). |
| Multi-deposit | `depositMany`, up to 64 items, token totals pulled once per asset. |
| Verifier | One small generic contract (`SethGroth16Verifier`) for every circuit, replacing four generated interfaces. |
| Queued for v0.9 | Inbox addresses, encrypted memos, absorbing one pending TRANSFER in direct mode, and a permissionless-token tier decision (§10). |

---

## 2. Verifier: `SethGroth16Verifier` (Appendix B)

One contract per circuit, deployed with that circuit's verifying key: alpha, beta, gamma and delta as immutables, and the IC points in an immutable data contract created by the constructor (SSTORE2 pattern). `nPublic = k`.

**Single verification** is the snarkjs check:

```text
e(-A, B) · e(alpha, beta) · e(IC0 + Σ_j x_j·IC_{j+1}, gamma) · e(C, delta) == 1
```

**Batch verification** of n proofs of the same circuit:

```text
seed = keccak256(abi.encode(chainid, verifier, proofs, inputs))
r_0 = 1,  r_i = keccak256(seed, i) mod r  (0 → 1)
Π_i e(-r_i·A_i, B_i) · e(S·alpha, beta) · e(S·IC0 + Σ_j T_j·IC_{j+1}, gamma) · e(Σ_i r_i·C_i, delta) == 1
S = Σ_i r_i,   T_j = Σ_i r_i·x_ij   (mod r)
```

This takes n + 3 pairings instead of 4n. The public-input work is k + 1 scalar multiplications per *batch*, not k per proof.

**Soundness.** The randomizers are fixed by a hash over every proof and input, so a prover cannot choose proofs after seeing them. A batch containing an invalid proof passes with probability at most about n/r.

**Review items (VER-01):**
- Confirm the EIP-197 precompile rejects G2 points outside the prime-order subgroup; batch soundness relies on it.
- Confirm the G1 on-curve checks in EIP-196.
- Confirm the Fiat–Shamir transcript covers every value the batch equation uses.

**Scope rules:**
- A batch is all-or-nothing and single-circuit.
- Duplicate proofs verify; replay protection is the pool's job (nullifiers).
- Inputs ≥ r and proof coordinates ≥ q are rejected.

**Measured gas** (real pairings, execution gas):

| | k = 1 | k = 3 |
|---|---:|---:|
| Single verification | 194,533 (snarkjs: 188,457) | 210,107 (snarkjs: 201,648) |
| Batch, n = 2 | 137,603 per proof | 146,452 per proof |
| Batch, n = 4 | 94,295 per proof | 99,319 per proof |
| Batch, n = 8 | 72,648 per proof | 75,759 per proof |
| Batch, n = 16 | 61,838 per proof | 63,995 per proof |

The measured marginal cost is about 7.8k gas per extra public input (k = 1 → 3). The generic verifier costs about 6–8k more than snarkjs's fully unrolled output on a single verification (IC fetch, memory). That's acceptable for one reviewable contract, and G3 can optimize it.

---

## 3. Aggregator lane: `transactBatch(proofs[], bodies[])`

**Who:** anyone. In practice a broadcaster that collects several users' ordinary queued TRANSFER_2_4 transactions and submits them together. The aggregator is paid exactly as a broadcaster is: by each user's shielded fee output. It gains no key, no custody and no pool privilege.

**Scope:**
- 1–16 entries, TRANSFER_2_4 only, **pure transfers only** (`W = 0`). Withdrawals and exits stay single-lane, so that no public payout can make a batch revert.
- Each entry's `executor` must be zero or the submitting aggregator.

**Lane-agnostic proofs.** Each entry's canonical body is exactly what `transact` hashes, with header `V` equal to the entry's tip. The user proves once, and the same proof and body are valid in either lane (tested). Whichever lands first wins; the other is skipped (batch) or reverts (single).

**Order of effects:**
1. **Static validation of every entry.** Lengths, canonical fields, zero public asset, recipient and payout gas, executor, and proof encoding. Any failure reverts the whole call; that is the aggregator's fault.
2. **Staleness, evaluated per entry against current state:**
   - the deadline has passed;
   - the root is not recognized;
   - a nullifier is already spent;
   - a nullifier was used by an earlier *included* entry in the same batch.

   A stale entry is **skipped, not reverted**, so front-running one user can't grief the other users or the aggregator.
3. **`msg.value` must equal the sum of all entry tips.** Tips of skipped entries are credited to the submitter (`credit`, claimable as insertion fees).
4. **Build each included entry's statement** (native 12 words, or the one-word hash per `hashedMask`) and call `verifyBatch` once. An invalid proof reverts everything, so aggregators MUST pre-verify each proof off-chain, which is cheap.
5. **Apply each included entry:** nullifiers, tip into `T`, then enqueue. This is exactly the per-entry effect of `transact`.
6. Emit `BatchTransacted(submitter, includedMask, refundedTips)`.

**Measured** (real pairings, fresh pool, execution gas):

| Profile | Single `transact` | Batch, n = 2 | Batch, 14 included + 2 skipped |
|---|---:|---:|---:|
| Native (k = 12) | 409,615 | 307,282 per transfer | **209,376 per transfer** |
| Hashed (k = 1) | 324,398 | 254,630 per transfer | **193,034 per transfer** |

Add intrinsic calldata of about 1.9 KB per transfer (about 24k gas) plus the 21k base amortized over the batch. End to end, a full batch cuts the per-transfer cost roughly in half.

In a batch, what remains per transfer is:
- about 62–66k of verification share;
- 44.2k for two fresh nullifier slots;
- accumulator and ring writes;
- the entry event carrying the full body (about 1.7 KB of log data).

Nullifier storage is the next floor. v0.9+ could only lower it with an aggregated nullifier structure, which this lane intentionally doesn't do.

**Privacy.** Entries in one batch are visibly co-submitted by one account. This is the same metadata a broadcaster already sees and publishes. The skip mask reveals only facts that are already public (spent nullifiers, expired deadlines).

---

## 4. Statement profiles (`hashedMask`)

For each spend circuit c ∈ {TRANSFER_2_4 = 1, TRANSFER_8_4 = 2, EXIT_2_0 = 3, DIRECT = 6}, the immutable bit `hashedMask[c]` selects:
- **native:** the v0.7 public-input vector, verified with k = 12/18/8/18;
- **hashed:** one public input, `stmt = H253(SHA256(u256be(w_0) ‖ … ‖ u256be(w_{k−1})))`, over the same vector in the same order.

The constructor checks every verifier's `nPublic` against the selected profile. The batch circuits are always one input.

**Hashed-profile circuits** wrap the unchanged v0.7 relations. Each word goes through the alias-checked field decomposition (`Num2Bits_strict`), then SHA-256 and H253 (Appendix C).

| Circuit | Native constraints | Hashed constraints | Single-lane gas saved by hashing | Batch-lane saving |
|---|---:|---:|---:|---:|
| TRANSFER_2_4 | 21,522 | 238,587 (11.1×) | **85,217 measured** | 16k per transfer measured |
| EXIT_2_0 | 18,994 | 173,355 (9.1×) | ≈55k (derived: 7 inputs × 7.8k) | n/a (single-lane) |
| TRANSFER_2_4_DIRECT | 52,265 | 363,386 (7.0×) | ≈130k (derived: 17 inputs × 7.8k) | n/a (state-dependent) |
| TRANSFER_8_4 | 77,172 | 388,293 (5.0×) | ≈130k (derived) | n/a (single-lane in v0.8) |

**Decision rule for testnet round R2.** Measure p50/p95 proving time and peak memory for both profiles on:
- the reference phone, with a native prover (rapidsnark/mopro class);
- a desktop with a native prover;
- a browser with WASM.

Set the bit for a circuit only if its hashed version meets the round's UX budget on the phone *and* the browser. Proposed placeholders: phone p95 ≤ 5 s, browser p95 ≤ 20 s. Two expectations to test:
- **DIRECT** is the strongest candidate: it can't be batched, and hashing saves about 130k on every call.
- **TRANSFER_2_4** likely stays native: the aggregator lane captures most of the saving (hashing buys only 16k in a batch), and its native circuit is by far the fastest to prove.

---

## 5. `depositMany(items[])`

- **Limits:** 1–64 items, each `(asset, partialCommitment, amount, tip, ciphertext[109])`, with `msg.value = Σ ETH amounts + Σ tips`.
- **Validation:** every item is validated exactly as a single deposit. Per-asset totals must fit `uint128` and pass the ramp and cap.
- **Token pull:** each token asset is pulled **once**, for its total, with v0.7's exact sender and pool balance-change checks.
- **Records:** each item becomes an ordinary DEPOSIT entry whose canonical body uses `V = (asset == 0 ? amount : 0) + tip`. That is the `msg.value` the same deposit would have had alone, so records, insertion and direct absorption are unchanged. Byte-identity is tested.
- **Measured:** 20 items (2 ETH, 18 token) cost 937,373 execution gas, **46,869 per deposit**, against 70,327 for a single token deposit, before counting the 21k base saved per extra item. These are fresh-pool numbers; steady state is lower once ring slots are rewritten.
- **Privacy:** every item shares one public payer. Payees' shielded addresses are not revealed.

---

## 6. Other contract changes

- **Single verifier interface** (`ISethVerifier`): `verify(proof, pub[])`, `verifyBatch(proofs[], pubFlat[])`, `nPublic()`. The `insertBatch` statement check uses `verify` with k = 1.
- **`Params.hashedMask`:** only bits 1, 2, 3 and 6 are allowed; an arity mismatch reverts the constructor.
- **`nextBatchWindow()` removed** to save code size. Wallets compute the same always-representable step from the public counters, as in v0.7 §7.4 and the reference `nextBatch`.
- **Deposit code shared** between `deposit` and `depositMany` (`_validateDeposit`, `_recordDeposit`). Behaviour is identical to v0.7.

---

## 7. Code-size constraint

The pool is **24,343 bytes against the 24,576 limit** (runs = 10). Keeping the v0.7 `memory-safe` assembly annotations let the compiler spill the stack into memory and grew the code to about 26 KB, so v0.8 omits them. The blocks themselves are unchanged and still memory-safe.

Any v0.9 feature (inbox addresses, memos) will not fit. **v0.9 MUST adopt a module split.** Proposed design:
- The pool constructor deploys one immutable extension contract, passing the pool's already-computed immutables.
- The pool's fallback `DELEGATECALL`s unknown selectors to it.
- Both contracts inherit one abstract storage layout.
- The extension rejects direct calls with `address(this) != pool`.

This keeps "no owner, no upgrade" intact, but adds a storage-layout review item.

---

## 8. Updated gas picture (execution gas, fresh pool, real verification)

| Operation | Native | Hashed |
|---|---:|---:|
| Deposit, single token | 70,327 | same |
| Deposit via `depositMany`, per item | 46,869 | same |
| Batch insertion, k = 16 | 287,571 (≈18k per entry) | same |
| Transfer, single lane | 409,615 | 324,398 |
| Transfer, aggregator lane, n = 14 | 209,376 | 193,034 |
| Direct (first note, absorb), *derived* | ≈510k | ≈380k |

Calldata (about 1.9 KB per transfer) and the 21k base come on top. Steady-state figures are lower than fresh-pool figures by about 17k per rewritten ring slot.

---

## 9. Historical validation plan

| Round | Scope | Exit criteria |
|---|---|---|
| **R1: functional** | v0.8 on a public testnet (Sepolia or Hoodi) with development keys for every production circuit at full depth; reference wallet CLI; one batcher; one aggregator | Every lifecycle path, run through real spend proofs: deposit, `depositMany`, direct first note, queued transfer, batch lane, withdrawal, exit, idle exit, skip, top-up, credit claim. v0.7 §16 regression families automated and fail-closed |
| **R2: performance** | Proving benchmarks (phone, desktop, browser) for both profiles; BATCH_UPTO_16 build and proof on server hardware; receipts for every §8 row | `hashedMask` decided per §4; gas receipts replace every derived number; verifier gas optimization pass |
| **R3: services and adversarial** | Independent operators (batcher, aggregator, broadcaster); fuzzing and state-machine tests with a plaintext ledger; front-run, stale-batch, reorg and backlog drills; E2 kernel on testnet with a Monero stagenet | No unexplained failures across a long soak; griefing costs measured; E2-G1 prerequisites |
| **R4: freeze** | v0.9 features (with the module split) land in R1–R3 form; independent circuit, contract and cryptography reviews; frozen circuits | No open critical or high findings; public phase-2 ceremonies; release manifest → **v1.0** |

---

## 10. Unimplemented extension proposals

- **Inbox addresses:** a deposit kind carrying `(owner_d, public rseed)`, with the partial derived in the batch or direct circuit, plus a counterfactual CREATE2 forwarder that any relayer can flush. It lets any sender, including an exchange, pay a normal `0x` address that auto-shields.
- **Encrypted memos:** a uniform 64-byte memo slot in every output ciphertext (about +5k gas per transfer).
- **Direct absorption of one pending TRANSFER entry:** four more public inputs, so a recipient can spend immediately while the pool is quiet.
- **Permissionless-token tier:** asset ID = token address. This requires revised asset constraints, liability indexing and token-admission rules.

---

## Appendix A: Pool contract (`contracts/ShieldedETHPool.sol`, v0.8)

solc 0.8.26, `viaIR: true`, optimizer runs 10, `evmVersion: cancun`: 24,343-byte runtime.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SethGroth16Verifier.sol";

/// @title ShieldedETH v0.7 core pool: multi-asset, shared commitment tree, direct mode for idle-compatible queues.
/// Immutable: no owner, pause, upgrade, delegatecall, fee or sweep.
contract ShieldedETHPool {
    // ------------------------------------------------------------------ constants
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 internal constant MASK253 = (uint256(1) << 253) - 1;
    uint16  public constant VERSION = 8;
    uint256 public constant EMPTY_ROOT = 0x1bef23e9a4249514364aad066477b69165bfca8323517caac310800b7838ff3a;
    uint40  public constant MAX_ENTRIES = uint40(1) << 30;
    uint256 internal constant RING = 1024;
    uint40  internal constant STRIDE = 16;
    uint256 internal constant MAX_ASSETS = 8;
    uint256 internal constant MAX_PENDING_DIRECT = 4;

    uint8 public constant OP_DEPOSIT = 1;
    uint8 public constant OP_TRANSFER = 2;
    uint8 public constant OP_EXIT = 3;
    uint8 public constant C_TRANSFER_2_4 = 1;
    uint8 public constant C_TRANSFER_8_4 = 2;
    uint8 public constant C_EXIT_2_0 = 3;
    uint8 public constant C_BATCH_1 = 4;
    uint8 public constant C_BATCH_UPTO_16 = 5;
    uint8 public constant C_TRANSFER_2_4_DIRECT = 6;
    bytes32 public constant BODY_TAG = keccak256("SETH/v8/BODY");

    // ------------------------------------------------------------------ types
    /// One payee of `depositMany`; each becomes an ordinary DEPOSIT entry with its own canonical body.
    struct DepositItem { uint8 asset; uint256 partialCommitment; uint128 amount; uint128 tip; bytes ciphertext; }
    struct DepositBody { uint8 asset; uint256 partialCommitment; uint128 amount; uint128 tip; bytes ciphertext; }
    struct TransferBody {
        uint64 rootSeq; uint256 root; uint256[] nullifiers; uint256[4] commitments;
        uint128 W; uint8 publicAsset; uint128 tip; address recipient; uint32 payoutGas;
        address executor; uint64 deadline; bytes32 nonce;
        bytes recipientCiphertexts; bytes recoveryCiphertext;
    }
    struct ExitBody {
        uint64 rootSeq; uint256 root; uint256[2] nullifiers;
        uint128 W; uint8 publicAsset; uint128 tip; address recipient; uint32 payoutGas;
        address executor; uint64 deadline; bytes32 nonce;
    }
    /// A queued record, re-supplied in calldata and re-hashed against the accumulator.
    struct PendingRecord { uint8 kind; uint256[4] w; uint256 extHash; uint128 tip; }
    struct Asset { address token; uint128 rampC0; uint128 capCeiling; uint32 callGasCap; uint32 balanceGasCap; }   // token == address(0) only for asset 0 (native ETH)
    struct DirectContext {
        uint40 expectedInserted; uint40 expectedNext; uint256 expectedInsertedAcc; uint256 expectedQueueAcc;
        uint256 newRoot; address rewardBeneficiary; bytes32 pendingHash;
    }
    struct Params {
        bytes32 instanceSalt; uint64 rampPeriod; uint32 payoutGasCap; Asset[] assets;
        address vTransfer24; address vTransfer84; address vExit; address vBatch1; address vBatch16; address vDirect;
        uint8 hashedMask;   // bit c set: spend circuit c uses the one-input statement-hash profile
    }

    // ------------------------------------------------------------------ immutables
    bytes32 public immutable poolId;
    uint8 public immutable hashedMask;
    uint256 public immutable noteDomain;
    uint256 public immutable acc0;
    uint64  public immutable t0;
    uint64  public immutable rampPeriod;
    uint32  public immutable payoutGasCap;
    uint8   public immutable numAssets;
    address public immutable vTransfer24;
    address public immutable vTransfer84;
    address public immutable vExit;
    address public immutable vBatch1;
    address public immutable vBatch16;
    address public immutable vDirect;

    // ------------------------------------------------------------------ storage (asset table written once, in the constructor)
    address[8] public assetToken;
    uint128[8] public assetRampC0;
    uint128[8] public assetCapCeiling;
    uint32[8] public assetCallGasCap;
    uint32[8] public assetBalanceGasCap;
    uint256[8] public liability;           // per-asset shielded-note liability, in token units

    uint40 public nextEntry;
    uint40 public insertedEntries;
    uint64 public rootSeq;
    uint64 public terminalExitCount;
    uint40 public pendingTopUps;
    uint256 public T;                      // ETH tips owed to future inserters
    uint256 public C;                      // earned, unclaimed ETH insertion credit
    uint256 public insertedAcc;
    uint256 public terminalExitAcc;
    uint256[1024] internal accRing;
    uint256[1024] internal rootRing;
    mapping(uint40 => uint256) internal checkpoints;
    mapping(uint256 => bool) public nullifierSpent;
    mapping(address => uint256) public credit;
    mapping(uint40 => uint128) public extraTip;

    // ------------------------------------------------------------------ events
    event EntryPublished(uint40 indexed entry, uint8 kind, uint256[4] words, uint256 extHash, uint128 baseTip, bytes canonicalBody);
    /// mode: 0 batch proof, 1 direct transfer, 2 idle exit, 3 zero-entry skip
    event Inserted(uint40 indexed start, uint40 end, uint256 root, uint64 rootSeq, uint256 insertedAcc, address indexed beneficiary, uint256 reward, uint8 mode);
    event InsertionTipAdded(uint40 indexed entry, address indexed payer, uint128 amount);
    event InsertionFeesClaimed(address indexed beneficiary, address indexed to, uint256 amount);
    /// Aggregator lane: bit i of includedMask set if entry i was verified and applied; others were stale and skipped.
    event BatchTransacted(address indexed submitter, uint256 includedMask, uint256 refundedTips);
    event TerminalExitPublished(uint64 indexed sequence, uint256 extHash, bytes canonicalBody);

    // ------------------------------------------------------------------ errors
    error Reentrancy(); error BadLength(); error BadField(); error BadAmount(); error BadCircuit(); error BadAsset();
    error Expired(); error NotExecutor(); error BadRecipient(); error BadPayoutGas(); error NonCanonical();
    error UnknownRoot(); error NullifierUsed(); error DuplicateNullifier(); error BadProof(); error CapExceeded();
    error Full(); error Stale(); error BadK(); error UnknownAccumulator(); error TipAccounting(); error NotPending();
    error PayoutFailed(); error TokenTransferFailed(); error InsufficientGas(); error Backing(); error Liability();
    error BadParams(); error NotAbsorbable(); error NothingIncluded();

    modifier nonReentrant() {
        uint256 locked;
        assembly { locked := tload(0) }
        if (locked != 0) revert Reentrancy();
        assembly { tstore(0, 1) }
        _;
        assembly { tstore(0, 0) }
    }

    constructor(Params memory p) {
        uint256 n = p.assets.length;
        if (n < 2 || n > MAX_ASSETS || p.rampPeriod == 0 || p.payoutGasCap < 2300 || p.payoutGasCap > 1_000_000) revert BadParams();
        if (p.assets[0].token != address(0)) revert BadParams();
        for (uint256 i = 0; i < n; i++) {
            if (p.assets[i].rampC0 == 0 || p.assets[i].capCeiling < p.assets[i].rampC0) revert BadParams();
            if (i == 0 && (p.assets[i].callGasCap != 0 || p.assets[i].balanceGasCap != 0)) revert BadParams();
            if (i > 0 && (p.assets[i].callGasCap < 25000 || p.assets[i].callGasCap > 1000000
                || p.assets[i].balanceGasCap < 5000 || p.assets[i].balanceGasCap > 200000)) revert BadParams();
            if (i > 0) {
                if (p.assets[i].token.code.length == 0) revert BadParams();
                for (uint256 j = 1; j < i; j++) if (p.assets[j].token == p.assets[i].token) revert BadParams();
            }
            assetToken[i] = p.assets[i].token;
            assetRampC0[i] = p.assets[i].rampC0;
            assetCapCeiling[i] = p.assets[i].capCeiling;
            assetCallGasCap[i] = p.assets[i].callGasCap;
            assetBalanceGasCap[i] = p.assets[i].balanceGasCap;
        }
        if (p.vTransfer24.code.length == 0 || p.vTransfer84.code.length == 0 || p.vExit.code.length == 0
            || p.vBatch1.code.length == 0 || p.vBatch16.code.length == 0 || p.vDirect.code.length == 0) revert BadParams();
        bytes32 id = keccak256(abi.encode(keccak256("ShieldedETH"), VERSION, block.chainid, address(this), p.instanceSalt));
        uint256 dom = uint256(id) & MASK253;
        if (dom == 0) revert BadParams();
        uint256 a0 = _h253(sha256(abi.encodePacked("SETH/v8/acc", id)));
        poolId = id; noteDomain = dom; acc0 = a0; numAssets = uint8(n);
        insertedAcc = a0;
        terminalExitAcc = _h253(sha256(abi.encodePacked("SETH/v8/terminal-exits", id)));
        rootRing[0] = EMPTY_ROOT;
        t0 = uint64(block.timestamp);
        rampPeriod = p.rampPeriod; payoutGasCap = p.payoutGasCap;
        vTransfer24 = p.vTransfer24; vTransfer84 = p.vTransfer84; vExit = p.vExit;
        vBatch1 = p.vBatch1; vBatch16 = p.vBatch16; vDirect = p.vDirect;
        if (p.hashedMask & ~uint8((1 << C_TRANSFER_2_4) | (1 << C_TRANSFER_8_4) | (1 << C_EXIT_2_0) | (1 << C_TRANSFER_2_4_DIRECT)) != 0) revert BadParams();
        hashedMask = p.hashedMask;
        _checkArity(p.vTransfer24, p.hashedMask, C_TRANSFER_2_4, 12);
        _checkArity(p.vTransfer84, p.hashedMask, C_TRANSFER_8_4, 18);
        _checkArity(p.vExit, p.hashedMask, C_EXIT_2_0, 8);
        _checkArity(p.vDirect, p.hashedMask, C_TRANSFER_2_4_DIRECT, 18);
        if (ISethVerifier(p.vBatch1).nPublic() != 1 || ISethVerifier(p.vBatch16).nPublic() != 1) revert BadParams();
    }

    // ================================================================== deposit (no proof, no on-chain Poseidon)
    /// asset 0: msg.value = amount + tip. ERC-20 assets: exactly `amount` pulled via transferFrom; msg.value = tip (ETH).
    function deposit(uint8 asset, uint256 partialCommitment, uint128 amount, bytes calldata ciphertext)
        external payable nonReentrant returns (uint40 entry)
    {
        _validateDeposit(asset, partialCommitment, amount, ciphertext);
        if (nextEntry >= MAX_ENTRIES) revert Full();
        if (msg.value >= (uint256(1) << 128)) revert BadAmount();
        if (liability[asset] + amount > rampCap(asset)) revert CapExceeded();
        uint128 tip;
        if (asset == 0) {
            if (msg.value < amount) revert BadAmount();
            tip = uint128(msg.value) - amount;
        } else {
            tip = uint128(msg.value);
            _pullToken(asset, amount);
        }
        entry = _recordDeposit(asset, partialCommitment, amount, tip, ciphertext);
        _checkBacking(asset);
    }

    function _validateDeposit(uint8 asset, uint256 partialCommitment, uint128 amount, bytes calldata ciphertext) internal view {
        if (asset >= numAssets) revert BadAsset();
        if (ciphertext.length != 109) revert BadLength();
        if (partialCommitment == 0 || partialCommitment >= R) revert BadField();
        if (amount == 0) revert BadAmount();
    }

    /// Canonical body with V = (asset == 0 ? amount : 0) + tip, i.e. exactly msg.value of the equivalent single deposit.
    function _recordDeposit(uint8 asset, uint256 partialCommitment, uint128 amount, uint128 tip, bytes calldata ciphertext) internal returns (uint40) {
        uint128 v = tip + (asset == 0 ? amount : 0);
        bytes memory body = abi.encode(BODY_TAG, VERSION, OP_DEPOSIT, uint8(0), poolId, block.chainid, v,
            DepositBody(asset, partialCommitment, amount, tip, ciphertext));
        liability[asset] += amount;
        T += tip;
        return _enqueue(OP_DEPOSIT, [partialCommitment, uint256(amount), uint256(asset), 0], _h253(keccak256(body)), tip, body);
    }

    // ================================================================== queued private transfer
    function transact(uint8 circuitId, Groth16Proof calldata proof, TransferBody calldata b) external payable nonReentrant {
        uint256 n = b.nullifiers.length;
        if (circuitId == C_TRANSFER_2_4) { if (n != 2) revert BadLength(); }
        else if (circuitId == C_TRANSFER_8_4) { if (n != 8) revert BadLength(); }
        else revert BadCircuit();
        if (msg.value != b.tip) revert BadAmount();
        _checkTransferBody(b);
        if (!isKnownRoot(b.rootSeq, b.root)) revert UnknownRoot();
        _checkNullifiers(b.nullifiers);
        _checkProofEncoding(proof);
        bytes memory body = abi.encode(BODY_TAG, VERSION, OP_TRANSFER, circuitId, poolId, block.chainid, uint128(msg.value), b);
        uint256 extHash = _h253(keccak256(body));
        uint256 pubAmt = b.W == 0 ? 0 : R - uint256(b.W);
        bool ok;
        if (circuitId == C_TRANSFER_2_4) {
            uint256[12] memory pub = [noteDomain, uint256(numAssets), b.root, pubAmt, uint256(b.publicAsset), extHash, b.nullifiers[0], b.nullifiers[1],
                b.commitments[0], b.commitments[1], b.commitments[2], b.commitments[3]];
            ok = _verifySpend(C_TRANSFER_2_4, vTransfer24, proof, _dyn12(pub));
        } else {
            uint256[18] memory pub;
            pub[0] = noteDomain; pub[1] = numAssets; pub[2] = b.root; pub[3] = pubAmt; pub[4] = b.publicAsset; pub[5] = extHash;
            for (uint256 i = 0; i < 8; i++) pub[6 + i] = b.nullifiers[i];
            for (uint256 j = 0; j < 4; j++) pub[14 + j] = b.commitments[j];
            ok = _verifySpend(C_TRANSFER_8_4, vTransfer84, proof, _dyn18(pub));
        }
        if (!ok) revert BadProof();
        for (uint256 i = 0; i < n; i++) nullifierSpent[b.nullifiers[i]] = true;
        _debitLiability(b.publicAsset, b.W);
        T += b.tip;
        _enqueue(OP_TRANSFER, b.commitments, extHash, b.tip, body);
        if (b.W > 0) _payout(b.publicAsset, b.recipient, b.W, b.payoutGas);
        _checkBacking(b.publicAsset);
    }

    // ================================================================== direct mode: spend + immediate self-insertion
    /// Anchor must be the current root. `pending` must be exactly the not-yet-inserted entries (at most 4):
    /// any number of exits (zero leaves, root unchanged) and at most one deposit, which the proof inserts first.
    function transactDirect(Groth16Proof calldata proof, TransferBody calldata b, DirectContext calldata d, PendingRecord[] calldata pending)
        external nonReentrant
    {
        if (b.nullifiers.length != 2) revert BadLength();
        if (b.tip != 0) revert NonCanonical();
        _checkTransferBody(b);
        if (b.rootSeq != rootSeq || b.root != currentRoot()) revert Stale();
        uint40 start = insertedEntries;
        uint40 ownIndex = nextEntry;
        if (ownIndex >= MAX_ENTRIES) revert Full();
        if (d.expectedInserted != start || d.expectedNext != ownIndex || d.expectedInsertedAcc != insertedAcc
            || d.expectedQueueAcc != knownAcc(ownIndex)) revert Stale();
        if (uint256(ownIndex - start) != pending.length || pending.length > MAX_PENDING_DIRECT) revert Stale();
        if (keccak256(abi.encode(pending)) != d.pendingHash) revert Stale();
        if (d.newRoot >= R) revert BadField();
        if (d.rewardBeneficiary == address(0) || d.rewardBeneficiary == address(this)) revert BadRecipient();
        // Read-only before proof verification. Top-ups are collected only after verification.
        (uint256[4] memory absorb, uint256 baseReward) = _absorbPending(start, pending);
        _checkNullifiers(b.nullifiers);
        _checkProofEncoding(proof);
        bytes memory body = abi.encode(BODY_TAG, VERSION, OP_TRANSFER, C_TRANSFER_2_4_DIRECT, poolId,
            block.chainid, uint128(0), b, d);
        uint256 extHash = _h253(keccak256(body));
        {
            uint256[18] memory pub = [noteDomain, uint256(numAssets), b.root, b.W == 0 ? 0 : R - uint256(b.W),
                uint256(b.publicAsset), extHash, b.nullifiers[0], b.nullifiers[1],
                b.commitments[0], b.commitments[1], b.commitments[2], b.commitments[3],
                d.newRoot, uint256(ownIndex), absorb[0], absorb[1], absorb[2], absorb[3]];
            if (!_verifySpend(C_TRANSFER_2_4_DIRECT, vDirect, proof, _dyn18(pub))) revert BadProof();
        }
        nullifierSpent[b.nullifiers[0]] = true;
        nullifierSpent[b.nullifiers[1]] = true;
        _debitLiability(b.publicAsset, b.W);
        uint256 reward = baseReward + _collectTopUps(start, ownIndex);
        _enqueue(OP_TRANSFER, b.commitments, extHash, 0, body);
        uint40 end = nextEntry;
        _markInserted(end, knownAcc(end), d.newRoot, true, reward, d.rewardBeneficiary, 1);
        if (b.W > 0) _payout(b.publicAsset, b.recipient, b.W, b.payoutGas);
        _checkBacking(b.publicAsset);
    }

    // ================================================================== minimal exit (EXIT_2_0)
    function exit(Groth16Proof calldata proof, ExitBody calldata b) external payable nonReentrant {
        if (b.W == 0 || msg.value != b.tip) revert BadAmount();
        _checkCommon(b.deadline, b.executor, b.W, b.publicAsset, b.recipient, b.payoutGas);
        if (!isKnownRoot(b.rootSeq, b.root)) revert UnknownRoot();
        uint256[] memory nfs = new uint256[](2);
        nfs[0] = b.nullifiers[0]; nfs[1] = b.nullifiers[1];
        _checkNullifiersMem(nfs);
        _checkProofEncoding(proof);
        bool terminal = nextEntry >= MAX_ENTRIES;
        if (terminal && b.tip != 0) revert BadAmount();
        bytes memory body = abi.encode(BODY_TAG, VERSION, OP_EXIT, C_EXIT_2_0, poolId, block.chainid, uint128(msg.value), b);
        uint256 extHash = _h253(keccak256(body));
        uint256[8] memory pub = [noteDomain, uint256(numAssets), b.root, R - uint256(b.W), uint256(b.publicAsset), extHash, b.nullifiers[0], b.nullifiers[1]];
        if (!_verifySpend(C_EXIT_2_0, vExit, proof, _dyn8(pub))) revert BadProof();
        nullifierSpent[b.nullifiers[0]] = true;
        nullifierSpent[b.nullifiers[1]] = true;
        _debitLiability(b.publicAsset, b.W);
        if (terminal) {
            uint64 s = terminalExitCount;
            terminalExitAcc = _h253(sha256(abi.encodePacked(terminalExitAcc, s, extHash)));
            terminalExitCount = s + 1;
            emit TerminalExitPublished(s, extHash, body);
        } else {
            bool idle = insertedEntries == nextEntry && b.tip == 0;
            T += b.tip;
            _enqueue(OP_EXIT, [uint256(0), 0, 0, 0], extHash, b.tip, body);
            if (idle) { uint40 end = nextEntry; _markInserted(end, knownAcc(end), 0, false, 0, address(0), 2); }  // zero subtree: root unchanged
        }
        _payout(b.publicAsset, b.recipient, b.W, b.payoutGas);
        _checkBacking(b.publicAsset);
    }

    // ================================================================== proved batch insertion
    function insertBatch(
        uint8 circuitId, uint40 expectedStart, uint256 expectedOldRoot, uint256 expectedAccStart,
        uint8 k, uint256 newRoot, uint256 baseTipSum, address beneficiary, Groth16Proof calldata proof
    ) external nonReentrant {
        if (circuitId == C_BATCH_1) { if (k != 1) revert BadK(); }
        else if (circuitId == C_BATCH_UPTO_16) { if (k == 0 || k > 16) revert BadK(); }
        else revert BadCircuit();
        uint40 start = insertedEntries;
        uint256 oldRoot = rootRing[rootSeq % RING];
        if (expectedStart != start || expectedOldRoot != oldRoot || expectedAccStart != insertedAcc) revert Stale();
        if (beneficiary == address(0) || beneficiary == address(this)) revert BadRecipient();
        if (newRoot >= R || baseTipSum >= (uint256(1) << 132)) revert BadField();
        uint40 end = start + k;
        if (end > nextEntry) revert BadK();
        _checkProofEncoding(proof);
        uint256 accEnd = knownAcc(end);
        uint256 stmt = _h253(sha256(abi.encode(poolId, block.chainid, uint256(circuitId), oldRoot, newRoot,
            uint256(start), uint256(k), expectedAccStart, accEnd, uint256(baseTipSum), uint256(uint160(beneficiary)))));
        address v = circuitId == C_BATCH_1 ? vBatch1 : vBatch16;
        { uint256[] memory one = new uint256[](1); one[0] = stmt; if (!ISethVerifier(v).verify(proof, one)) revert BadProof(); }
        uint256 reward = uint256(baseTipSum) + _collectTopUps(start, end);
        _markInserted(end, accEnd, newRoot, true, reward, beneficiary, 0);
    }

    /// Advance insertion over a run of queued exits (zero leaves) without a proof. Root unchanged.
    function skipZeroEntries(uint40 expectedStart, uint256 expectedAccStart, address beneficiary, PendingRecord[] calldata recs) external nonReentrant {
        uint40 start = insertedEntries;
        if (expectedStart != start || expectedAccStart != insertedAcc) revert Stale();
        if (beneficiary == address(0) || beneficiary == address(this)) revert BadRecipient();
        uint256 n = recs.length;
        if (n == 0 || n > 16 || uint256(start) + n > nextEntry) revert BadK();
        uint256 acc = insertedAcc;
        uint256 reward;
        for (uint256 i = 0; i < n; i++) {
            PendingRecord calldata p = recs[i];
            if (p.kind != OP_EXIT || p.w[0] != 0 || p.w[1] != 0 || p.w[2] != 0 || p.w[3] != 0) revert NotAbsorbable();
            acc = _accStep(acc, p);
            reward += p.tip;
        }
        uint40 end = start + uint40(n);
        if (acc != knownAcc(end)) revert Stale();
        reward += _collectTopUps(start, end);
        _markInserted(end, acc, 0, false, reward, beneficiary, 3);
    }

    function addInsertionTip(uint40 entry) external payable nonReentrant {
        if (entry < insertedEntries || entry >= nextEntry) revert NotPending();
        uint128 cur = extraTip[entry];
        if (msg.value == 0 || uint256(cur) + msg.value >= (uint256(1) << 128)) revert BadAmount();
        if (cur == 0) pendingTopUps += 1;
        extraTip[entry] = cur + uint128(msg.value);
        T += uint128(msg.value);
        emit InsertionTipAdded(entry, msg.sender, uint128(msg.value));
        _checkBacking(0);
    }

    function claimInsertionFees(address payable to, uint256 amount) external nonReentrant {
        if (to == address(0) || to == address(this)) revert BadRecipient();
        uint256 c = credit[msg.sender];
        if (amount == 0 || amount > c) revert BadAmount();
        credit[msg.sender] = c - amount;
        C -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
        emit InsertionFeesClaimed(msg.sender, to, amount);
        _checkBacking(0);
    }

    // ================================================================== v0.8: multi-deposit (payroll / airdrop)
    /// Up to 64 deposits in one call. Token totals are pulled once per asset with exact balance-change checks.
    /// msg.value = sum(ETH amounts) + sum(tips). Each item's canonical body uses V = (asset == 0 ? amount : 0) + tip,
    /// so every queue record is byte-identical to the same deposit made alone.
    function depositMany(DepositItem[] calldata items) external payable nonReentrant returns (uint40 firstEntry) {
        uint256 n = items.length;
        if (n == 0 || n > 64) revert BadLength();
        if (uint256(nextEntry) + n > MAX_ENTRIES) revert Full();
        uint256[8] memory totals; uint256 ethNeeded;
        for (uint256 i = 0; i < n; i++) {
            DepositItem calldata it = items[i];
            _validateDeposit(it.asset, it.partialCommitment, it.amount, it.ciphertext);
            totals[it.asset] += it.amount;
            ethNeeded += uint256(it.tip) + (it.asset == 0 ? uint256(it.amount) : 0);
        }
        if (msg.value != ethNeeded) revert BadAmount();
        for (uint8 a = 0; a < numAssets; a++) {
            if (totals[a] == 0) continue;
            if (totals[a] >= (uint256(1) << 128) || liability[a] + totals[a] > rampCap(a)) revert CapExceeded();
            if (a != 0) _pullToken(a, uint128(totals[a]));
        }
        firstEntry = nextEntry;
        for (uint256 i = 0; i < n; i++) {
            DepositItem calldata it = items[i];
            _recordDeposit(it.asset, it.partialCommitment, it.amount, it.tip, it.ciphertext);
        }
        _checkBacking(0);
        for (uint8 a = 1; a < numAssets; a++) if (totals[a] != 0) _checkBacking(a);
    }

    // ================================================================== v0.8: aggregator lane (Groth16 batch verification)
    /// Submits up to 16 independent queued TRANSFER_2_4 pure transfers (W = 0) under one multi-pairing check.
    /// Each entry's canonical body is exactly what `transact` would hash (header V = entry tip), so a user's proof is
    /// lane-agnostic. Entries made stale by other transactions (spent nullifier, evicted root, expired deadline,
    /// duplicate nullifier earlier in the batch) are skipped; any other malformation or an invalid proof reverts the call.
    /// msg.value = sum of all entry tips; tips of skipped entries are credited to the submitter.
    function transactBatch(Groth16Proof[] calldata proofs, TransferBody[] calldata bodies) external payable nonReentrant {
        uint256 n = proofs.length;
        if (n == 0 || n > 16 || bodies.length != n) revert BadLength();
        BatchScratch memory S;
        S.k = (hashedMask & (uint8(1) << C_TRANSFER_2_4)) != 0 ? 1 : 12;
        S.flat = new uint256[](n * S.k);
        S.encoded = new bytes[](n);
        S.extHashes = new uint256[](n);
        for (uint256 i = 0; i < n; i++) _batchPrepare(proofs[i], bodies, i, S);
        if (msg.value != S.tipsAll) revert BadAmount();
        if (S.m == 0) revert NothingIncluded();
        _batchVerify(proofs, S);
        for (uint256 i = 0; i < n; i++) if (S.mask & (uint256(1) << i) != 0) _batchApply(bodies[i], S.extHashes[i], S.encoded[i]);
        if (S.tipsSkipped != 0) { C += uint128(S.tipsSkipped); credit[msg.sender] += S.tipsSkipped; }
        emit BatchTransacted(msg.sender, S.mask, S.tipsSkipped);
        _checkBacking(0);
    }

    struct BatchScratch { uint256 k; uint256 m; uint256 mask; uint256 tipsAll; uint256 tipsSkipped; uint256[] flat; bytes[] encoded; uint256[] extHashes; }

    function _batchPrepare(Groth16Proof calldata pr, TransferBody[] calldata bodies, uint256 i, BatchScratch memory S) internal view {
        TransferBody calldata b = bodies[i];
        if (b.nullifiers.length != 2 || b.W != 0) revert NonCanonical();
        if (b.recipientCiphertexts.length != 436 || b.recoveryCiphertext.length != 400) revert BadLength();
        if (b.publicAsset != 0 || b.recipient != address(0) || b.payoutGas != 0) revert NonCanonical();
        if (b.executor != address(0) && b.executor != msg.sender) revert NotExecutor();
        for (uint256 j = 0; j < 4; j++) if (b.commitments[j] == 0 || b.commitments[j] >= R) revert BadField();
        if (b.nullifiers[0] == 0 || b.nullifiers[0] >= R || b.nullifiers[1] == 0 || b.nullifiers[1] >= R) revert BadField();
        if (b.nullifiers[0] == b.nullifiers[1]) revert DuplicateNullifier();
        _checkProofEncoding(pr);
        S.tipsAll += b.tip;
        if (_batchStale(b, bodies, i, S.mask)) { S.tipsSkipped += b.tip; return; }
        bytes memory body = abi.encode(BODY_TAG, VERSION, OP_TRANSFER, C_TRANSFER_2_4, poolId, block.chainid, b.tip, b);
        uint256 extHash = _h253(keccak256(body));
        S.encoded[i] = body; S.extHashes[i] = extHash;
        uint256[] memory pub = _dyn12([noteDomain, uint256(numAssets), b.root, 0, 0, extHash, b.nullifiers[0], b.nullifiers[1],
            b.commitments[0], b.commitments[1], b.commitments[2], b.commitments[3]]);
        if (S.k == 1) S.flat[S.m] = _h253(sha256(abi.encodePacked(pub)));
        else for (uint256 j = 0; j < 12; j++) S.flat[S.m * 12 + j] = pub[j];
        S.mask |= (uint256(1) << i);
        S.m += 1;
    }

    function _batchVerify(Groth16Proof[] calldata proofs, BatchScratch memory S) internal view {
        Groth16Proof[] memory inc = new Groth16Proof[](S.m);
        uint256 c;
        for (uint256 i = 0; i < proofs.length; i++) if (S.mask & (uint256(1) << i) != 0) inc[c++] = proofs[i];
        uint256[] memory flat = S.flat; uint256 len = S.m * S.k;
        assembly { mstore(flat, len) }   // shrink length in place to the included entries
        if (!ISethVerifier(vTransfer24).verifyBatch(inc, flat)) revert BadProof();
    }

    function _batchApply(TransferBody calldata b, uint256 extHash, bytes memory body) internal {
        nullifierSpent[b.nullifiers[0]] = true;
        nullifierSpent[b.nullifiers[1]] = true;
        T += b.tip;
        _enqueue(OP_TRANSFER, b.commitments, extHash, b.tip, body);
    }

    /// State-dependent staleness only; everything static was already validated.
    function _batchStale(TransferBody calldata b, TransferBody[] calldata bodies, uint256 i, uint256 mask) internal view returns (bool) {
        if (block.timestamp > b.deadline || !isKnownRoot(b.rootSeq, b.root)) return true;
        if (nullifierSpent[b.nullifiers[0]] || nullifierSpent[b.nullifiers[1]]) return true;
        for (uint256 j = 0; j < i; j++) {
            if (mask & (uint256(1) << j) == 0) continue;
            TransferBody calldata o = bodies[j];
            if (o.nullifiers[0] == b.nullifiers[0] || o.nullifiers[0] == b.nullifiers[1]
                || o.nullifiers[1] == b.nullifiers[0] || o.nullifiers[1] == b.nullifiers[1]) return true;
        }
        return false;
    }

    /// Profile dispatch: native k-input statement, or the one-input statement hash H253(SHA256(u256be words)).
    function _verifySpend(uint8 cid, address v, Groth16Proof calldata p, uint256[] memory pub) internal view returns (bool) {
        if (hashedMask & (uint8(1) << cid) != 0) {
            uint256[] memory one = new uint256[](1);
            one[0] = _h253(sha256(abi.encodePacked(pub)));
            return ISethVerifier(v).verify(p, one);
        }
        return ISethVerifier(v).verify(p, pub);
    }

    function _checkArity(address v, uint8 mask, uint8 cid, uint256 nativeK) internal view {
        uint256 want = (mask & (uint8(1) << cid)) != 0 ? 1 : nativeK;
        if (ISethVerifier(v).nPublic() != want) revert BadParams();
    }

    function _dyn8(uint256[8] memory a) internal pure returns (uint256[] memory d) { d = new uint256[](8); for (uint256 i = 0; i < 8; i++) d[i] = a[i]; }
    function _dyn12(uint256[12] memory a) internal pure returns (uint256[] memory d) { d = new uint256[](12); for (uint256 i = 0; i < 12; i++) d[i] = a[i]; }
    function _dyn18(uint256[18] memory a) internal pure returns (uint256[] memory d) { d = new uint256[](18); for (uint256 i = 0; i < 18; i++) d[i] = a[i]; }

    // ================================================================== views
    function currentRoot() public view returns (uint256) { return rootRing[rootSeq % RING]; }

    function isKnownRoot(uint64 seq, uint256 root) public view returns (bool) {
        uint64 cur = rootSeq;
        if (seq > cur || cur - seq >= RING) return false;
        return rootRing[seq % RING] == root;
    }

    function knownAcc(uint40 n) public view returns (uint256) {
        if (n == 0) return acc0;
        if (n == insertedEntries) return insertedAcc;
        uint40 ne = nextEntry;
        if (n > ne) revert UnknownAccumulator();
        if (n % STRIDE == 0) return checkpoints[n];
        if (uint256(n) + RING > ne) return accRing[n % RING];
        revert UnknownAccumulator();
    }


    function rampCap(uint8 asset) public view returns (uint256) {
        if (asset >= numAssets) revert BadAsset();
        uint256 ceiling = assetCapCeiling[asset];
        uint256 periods = (block.timestamp - t0) / rampPeriod;
        if (periods >= 128) return ceiling;
        uint256 scheduled = uint256(assetRampC0[asset]) << periods;
        return scheduled < ceiling ? scheduled : ceiling;
    }

    // ================================================================== internals
    function _enqueue(uint8 kind, uint256[4] memory w, uint256 extHash, uint128 tip, bytes memory body) internal returns (uint40 e) {
        e = nextEntry;
        if (e >= MAX_ENTRIES) revert Full();
        uint256 prev = e == 0 ? acc0 : accRing[e % RING];
        uint256 acc = _h253(sha256(abi.encodePacked(prev, kind, w[0], w[1], w[2], w[3], extHash, tip)));
        uint40 n = e + 1;
        accRing[n % RING] = acc;
        if (n % STRIDE == 0) checkpoints[n] = acc;
        nextEntry = n;
        emit EntryPublished(e, kind, w, extHash, tip, body);
    }

    function _accStep(uint256 acc, PendingRecord calldata p) internal pure returns (uint256) {
        if (p.extHash > MASK253) revert BadField();
        for (uint256 j; j < 4; ++j) if (p.w[j] >= R) revert BadField();
        return _h253(sha256(abi.encodePacked(acc, p.kind, p.w[0], p.w[1], p.w[2], p.w[3], p.extHash, p.tip)));
    }

    /// Re-hash the pending prefix against the queue head. Returns (absorbIndex, partial, value, asset) of the
    /// single allowed deposit (all zero if none) and the tips owed to whoever inserts these entries.
    function _absorbPending(uint40 start, PendingRecord[] calldata pending) internal view returns (uint256[4] memory absorb, uint256 reward) {
        uint256 acc = insertedAcc;
        bool seenDeposit;
        for (uint256 i = 0; i < pending.length; i++) {
            PendingRecord calldata p = pending[i];
            if (p.kind == OP_DEPOSIT) {
                if (seenDeposit || p.w[0] == 0 || p.w[0] >= R || p.w[1] == 0 || p.w[1] >= (uint256(1) << 128)
                    || p.w[2] >= numAssets || p.w[3] != 0) revert NotAbsorbable();
                seenDeposit = true;
                absorb = [uint256(start) + i, p.w[0], p.w[1], p.w[2]];
            } else if (p.kind != OP_EXIT || p.w[0] != 0 || p.w[1] != 0 || p.w[2] != 0 || p.w[3] != 0) {
                revert NotAbsorbable();
            }
            acc = _accStep(acc, p);
            reward += p.tip;
        }
        if (acc != knownAcc(nextEntry)) revert Stale();
    }

    function _collectTopUps(uint40 start, uint40 end) internal returns (uint256 sum) {
        uint40 pend = pendingTopUps;
        if (pend == 0) return 0;
        for (uint40 e = start; e < end; e++) {
            uint128 x = extraTip[e];
            if (x != 0) { sum += x; delete extraTip[e]; pend--; }
        }
        pendingTopUps = pend;
    }

    /// Advance the inserted prefix to `end` with accumulator `accEnd`; optionally pin a new root; pay `reward` as credit.
    function _markInserted(uint40 end, uint256 accEnd, uint256 newRoot, bool pinRoot, uint256 reward, address beneficiary, uint8 mode) internal {
        uint40 start = insertedEntries;
        insertedEntries = end;
        insertedAcc = accEnd;
        uint64 seq = rootSeq;
        if (pinRoot && newRoot != rootRing[seq % RING]) { seq += 1; rootSeq = seq; rootRing[seq % RING] = newRoot; }
        if (reward > 0) {
            if (reward > T) revert TipAccounting();
            T -= reward;
            C += reward;
            credit[beneficiary] += reward;
        }
        emit Inserted(start, end, rootRing[seq % RING], seq, accEnd, beneficiary, reward, mode);
        _checkBacking(0);
    }

    function _checkTransferBody(TransferBody calldata b) internal view {
        if (b.recipientCiphertexts.length != 436 || b.recoveryCiphertext.length != 400) revert BadLength();
        _checkCommon(b.deadline, b.executor, b.W, b.publicAsset, b.recipient, b.payoutGas);
        for (uint256 j = 0; j < 4; j++) { if (b.commitments[j] == 0 || b.commitments[j] >= R) revert BadField(); }
    }

    /// W == 0: nothing crosses the boundary, so the asset must stay hidden (publicAsset = 0, no recipient).
    function _checkCommon(uint64 deadline, address executor, uint128 W, uint8 publicAsset, address recipient, uint32 payoutGas) internal view {
        if (block.timestamp > deadline) revert Expired();
        if (executor != address(0) && executor != msg.sender) revert NotExecutor();
        if (W > 0) {
            if (publicAsset >= numAssets) revert BadAsset();
            if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
            if (publicAsset == 0) { if (payoutGas == 0 || payoutGas > payoutGasCap) revert BadPayoutGas(); }
            else if (payoutGas != 0) revert NonCanonical();
        } else if (publicAsset != 0 || recipient != address(0) || payoutGas != 0) revert NonCanonical();
    }

    function _checkNullifiers(uint256[] calldata nfs) internal view {
        uint256 n = nfs.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 x = nfs[i];
            if (x == 0 || x >= R) revert BadField();
            if (nullifierSpent[x]) revert NullifierUsed();
            for (uint256 j = 0; j < i; j++) if (nfs[j] == x) revert DuplicateNullifier();
        }
    }

    function _checkNullifiersMem(uint256[] memory nfs) internal view {
        for (uint256 i = 0; i < nfs.length; i++) {
            uint256 x = nfs[i];
            if (x == 0 || x >= R) revert BadField();
            if (nullifierSpent[x]) revert NullifierUsed();
            for (uint256 j = 0; j < i; j++) if (nfs[j] == x) revert DuplicateNullifier();
        }
    }

    function _checkProofEncoding(Groth16Proof calldata p) internal pure {
        if (p.a[0] >= Q || p.a[1] >= Q || p.c[0] >= Q || p.c[1] >= Q
            || p.b[0][0] >= Q || p.b[0][1] >= Q || p.b[1][0] >= Q || p.b[1][1] >= Q) revert BadField();
    }

    function _debitLiability(uint8 asset, uint128 amount) internal {
        if (amount == 0) return;
        uint256 l = liability[asset];
        if (l < amount) revert Liability();
        liability[asset] = l - amount;
    }

    function _payout(uint8 asset, address to, uint128 amount, uint32 gasAllowance) internal {
        if (asset == 0) {
            if (gasleft() < (uint256(gasAllowance) * 64 + 62) / 63 + 15000) revert InsufficientGas();
            (bool ok,) = to.call{value: amount, gas: gasAllowance}("");
            if (!ok) revert PayoutFailed();
        } else {
            uint256 p0 = _balanceOf(asset, address(this));
            uint256 r0 = _balanceOf(asset, to);
            _tokenCall(asset, abi.encodeWithSelector(0xa9059cbb, to, amount));
            uint256 p1 = _balanceOf(asset, address(this));
            uint256 r1 = _balanceOf(asset, to);
            if (p0 < amount || p1 != p0 - amount || r1 < r0 || r1 - r0 != amount) revert TokenTransferFailed();
        }
    }

    function _pullToken(uint8 asset, uint128 amount) internal {
        uint256 p0 = _balanceOf(asset, address(this));
        uint256 s0 = _balanceOf(asset, msg.sender);
        _tokenCall(asset, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount));
        uint256 p1 = _balanceOf(asset, address(this));
        uint256 s1 = _balanceOf(asset, msg.sender);
        if (s0 < amount || s1 != s0 - amount || p1 < p0 || p1 - p0 != amount) revert TokenTransferFailed();
    }

    // Copy at most 32 return bytes. Empty or canonical true is accepted; malformed/false returns reject.
    function _tokenCall(uint8 asset, bytes memory data) internal {
        address token = assetToken[asset];
        uint256 cap = assetCallGasCap[asset];
        bool ok; uint256 size; uint256 word;
        if (gasleft() < (cap * 64 + 62) / 63 + 15000) revert InsufficientGas();
        assembly {
            let p := mload(0x40)
            mstore(p, 0)
            ok := call(cap, token, 0, add(data, 32), mload(data), p, 32)
            size := returndatasize()
            word := mload(p)
        }
        if (!ok || !(size == 0 || (size == 32 && word == 1))) revert TokenTransferFailed();
    }

    function _balanceOf(uint8 asset, address account) internal view returns (uint256 bal) {
        address token = assetToken[asset];
        uint256 cap = assetBalanceGasCap[asset];
        bytes memory data = abi.encodeWithSelector(0x70a08231, account);
        bool ok; uint256 size;
        if (gasleft() < (cap * 64 + 62) / 63 + 10000) revert InsufficientGas();
        assembly {
            let p := mload(0x40)
            mstore(p, 0)
            ok := staticcall(cap, token, add(data, 32), mload(data), p, 32)
            size := returndatasize()
            bal := mload(p)
        }
        if (!ok || size != 32) revert TokenTransferFailed();
    }

    // Only the boundary asset is touched; private sends and insertion never call every token.
    function _checkBacking(uint8 asset) internal view {
        if (address(this).balance < liability[0] + T + C) revert Backing();
        if (asset != 0 && _balanceOf(asset, address(this)) < liability[asset]) revert Backing();
    }

    function _h253(bytes32 d) internal pure returns (uint256) { return uint256(d) & MASK253; }
}
```

## Appendix B: Verifier (`contracts/SethGroth16Verifier.sol`)

5,144-byte runtime (runs 200).

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Proof layout exactly as snarkjs `exportSolidityCallData` emits it: `b` already in EIP-197 order
/// ([x_im, x_re], [y_im, y_re]).
struct Groth16Proof { uint256[2] a; uint256[2][2] b; uint256[2] c; }

interface ISethVerifier {
    function nPublic() external view returns (uint256);
    function verify(Groth16Proof calldata p, uint256[] calldata pub) external view returns (bool);
    function verifyBatch(Groth16Proof[] calldata ps, uint256[] calldata pubFlat) external view returns (bool);
}

/// @title Groth16 verifier (BN254) for one circuit with k public inputs, with Fiat-Shamir batch verification.
/// The IC points live in an immutable data contract (SSTORE2 pattern); everything else is immutable.
///
/// Single:  e(-A, B) e(alpha, beta) e(IC0 + sum_j x_j IC_{j+1}, gamma) e(C, delta) == 1
/// Batch:   prod_i e(-r_i A_i, B_i) * e(S alpha, beta) * e(S IC0 + sum_j T_j IC_{j+1}, gamma) * e(sum_i r_i C_i, delta) == 1
///          S = sum_i r_i, T_j = sum_i r_i x_ij (mod R), r_0 = 1, r_i = keccak(seed, i) mod R (nonzero),
///          seed = keccak(chainid, this, all proofs, all inputs). Pairings: n + 3 instead of 4n; the public-input
///          MSM is (k + 1) scalar multiplications per batch instead of k per proof.
contract SethGroth16Verifier is ISethVerifier {
    uint256 internal constant Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 public constant MAX_BATCH = 32;

    uint256 public immutable override nPublic;
    address internal immutable icData;           // runtime code = 0x00 || abi.encodePacked(IC0x, IC0y, IC1x, ...)
    uint256 internal immutable alphaX; uint256 internal immutable alphaY;
    uint256 internal immutable betaX1; uint256 internal immutable betaX0; uint256 internal immutable betaY1; uint256 internal immutable betaY0;
    uint256 internal immutable gammaX1; uint256 internal immutable gammaX0; uint256 internal immutable gammaY1; uint256 internal immutable gammaY0;
    uint256 internal immutable deltaX1; uint256 internal immutable deltaX0; uint256 internal immutable deltaY1; uint256 internal immutable deltaY0;

    /// G2 arguments in EIP-197 order [x_im, x_re, y_im, y_re], i.e. from a snarkjs vk: [v[0][1], v[0][0], v[1][1], v[1][0]].
    /// ic = [IC0x, IC0y, IC1x, IC1y, ...], length 2 * (k + 1).
    constructor(uint256[2] memory alpha, uint256[4] memory beta, uint256[4] memory gamma, uint256[4] memory delta, uint256[] memory ic) {
        require(ic.length >= 4 && ic.length % 2 == 0, "ic");
        nPublic = ic.length / 2 - 1;
        bytes memory runtime = abi.encodePacked(uint8(0), ic);
        bytes memory init = abi.encodePacked(hex"61", uint16(runtime.length), hex"80600c6000396000f3", runtime); // PUSH2 len DUP1 PUSH1 12 PUSH1 0 CODECOPY PUSH1 0 RETURN
        address d;
        assembly { d := create(0, add(init, 0x20), mload(init)) }
        require(d != address(0) && d.code.length == runtime.length, "icData");
        icData = d;
        alphaX = alpha[0]; alphaY = alpha[1];
        betaX1 = beta[0]; betaX0 = beta[1]; betaY1 = beta[2]; betaY0 = beta[3];
        gammaX1 = gamma[0]; gammaX0 = gamma[1]; gammaY1 = gamma[2]; gammaY0 = gamma[3];
        deltaX1 = delta[0]; deltaX0 = delta[1]; deltaY1 = delta[2]; deltaY0 = delta[3];
    }

    function verify(Groth16Proof calldata p, uint256[] calldata pub) external view returns (bool) {
        uint256 k = nPublic;
        if (pub.length != k || !_canonical(p)) return false;
        uint256[] memory ic = _ic(k);
        uint256 vx = ic[0]; uint256 vy = ic[1]; bool ok;
        for (uint256 j = 0; j < k; j++) {
            if (pub[j] >= R) return false;
            uint256 mx; uint256 my;
            (ok, mx, my) = _mul(ic[2 * j + 2], ic[2 * j + 3], pub[j]); if (!ok) return false;
            (ok, vx, vy) = _add(vx, vy, mx, my); if (!ok) return false;
        }
        uint256[] memory q = new uint256[](24);
        q[0] = p.a[0]; q[1] = p.a[1] == 0 ? 0 : Q - p.a[1];
        q[2] = p.b[0][0]; q[3] = p.b[0][1]; q[4] = p.b[1][0]; q[5] = p.b[1][1];
        _tail(q, 6, alphaX, alphaY, vx, vy, p.c[0], p.c[1]);
        return _pairing(q);
    }

    /// All-or-nothing batch check of independent proofs of this circuit; pubFlat = n * k inputs, proof-major.
    function verifyBatch(Groth16Proof[] calldata ps, uint256[] calldata pubFlat) external view returns (bool) {
        uint256 n = ps.length; uint256 k = nPublic;
        if (n == 0 || n > MAX_BATCH || pubFlat.length != n * k) return false;
        bytes32 seed = keccak256(abi.encode(block.chainid, address(this), ps, pubFlat));
        uint256[] memory q = new uint256[](6 * (n + 3));
        uint256[] memory t = new uint256[](k);
        uint256 sumR; uint256 cx; uint256 cy; bool ok;
        for (uint256 i = 0; i < n; i++) {
            Groth16Proof calldata pr = ps[i];
            if (!_canonical(pr)) return false;
            uint256 r = 1;
            if (i > 0) { r = uint256(keccak256(abi.encode(seed, i))) % R; if (r == 0) r = 1; }
            for (uint256 j = 0; j < k; j++) {
                uint256 x = pubFlat[i * k + j];
                if (x >= R) return false;
                t[j] = addmod(t[j], mulmod(r, x, R), R);
            }
            uint256 ax; uint256 ay;
            (ok, ax, ay) = _mul(pr.a[0], pr.a[1], r); if (!ok) return false;
            uint256 o = 6 * i;
            q[o] = ax; q[o + 1] = ay == 0 ? 0 : Q - ay;
            q[o + 2] = pr.b[0][0]; q[o + 3] = pr.b[0][1]; q[o + 4] = pr.b[1][0]; q[o + 5] = pr.b[1][1];
            uint256 rcx; uint256 rcy;
            (ok, rcx, rcy) = _mul(pr.c[0], pr.c[1], r); if (!ok) return false;
            (ok, cx, cy) = _add(cx, cy, rcx, rcy); if (!ok) return false;
            sumR = addmod(sumR, r, R);
        }
        uint256[] memory ic = _ic(k);
        uint256 vx; uint256 vy;
        (ok, vx, vy) = _mul(ic[0], ic[1], sumR); if (!ok) return false;
        for (uint256 j = 0; j < k; j++) {
            uint256 mx; uint256 my;
            (ok, mx, my) = _mul(ic[2 * j + 2], ic[2 * j + 3], t[j]); if (!ok) return false;
            (ok, vx, vy) = _add(vx, vy, mx, my); if (!ok) return false;
        }
        uint256 axs; uint256 ays;
        (ok, axs, ays) = _mul(alphaX, alphaY, sumR); if (!ok) return false;
        _tail(q, 6 * n, axs, ays, vx, vy, cx, cy);
        return _pairing(q);
    }

    // ------------------------------------------------------------------ internals
    function _tail(uint256[] memory q, uint256 o, uint256 ax, uint256 ay, uint256 vx, uint256 vy, uint256 cx, uint256 cy) internal view {
        q[o] = ax; q[o + 1] = ay; q[o + 2] = betaX1; q[o + 3] = betaX0; q[o + 4] = betaY1; q[o + 5] = betaY0;
        q[o + 6] = vx; q[o + 7] = vy; q[o + 8] = gammaX1; q[o + 9] = gammaX0; q[o + 10] = gammaY1; q[o + 11] = gammaY0;
        q[o + 12] = cx; q[o + 13] = cy; q[o + 14] = deltaX1; q[o + 15] = deltaX0; q[o + 16] = deltaY1; q[o + 17] = deltaY0;
    }

    function _ic(uint256 k) internal view returns (uint256[] memory ic) {
        ic = new uint256[](2 * (k + 1));
        address d = icData; uint256 len = 64 * (k + 1);
        assembly { extcodecopy(d, add(ic, 0x20), 1, len) }
    }

    function _canonical(Groth16Proof calldata p) internal pure returns (bool) {
        return p.a[0] < Q && p.a[1] < Q && p.c[0] < Q && p.c[1] < Q && p.b[0][0] < Q && p.b[0][1] < Q && p.b[1][0] < Q && p.b[1][1] < Q;
    }

    function _mul(uint256 x, uint256 y, uint256 s) internal view returns (bool ok, uint256 rx, uint256 ry) {
        uint256[3] memory inp = [x, y, s]; uint256[2] memory out;
        assembly { ok := staticcall(gas(), 0x07, inp, 0x60, out, 0x40) }
        rx = out[0]; ry = out[1];
    }

    function _add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (bool ok, uint256 rx, uint256 ry) {
        uint256[4] memory inp = [x1, y1, x2, y2]; uint256[2] memory out;
        assembly { ok := staticcall(gas(), 0x06, inp, 0x80, out, 0x40) }
        rx = out[0]; ry = out[1];
    }

    function _pairing(uint256[] memory q) internal view returns (bool) {
        uint256[1] memory out; bool ok; uint256 len = q.length * 32;
        assembly { ok := staticcall(gas(), 0x08, add(q, 0x20), len, out, 0x20) }
        return ok && out[0] == 1;
    }
}
```

## Appendix C: Circuit changes

`transfer.circom` is unchanged from v0.7.

### C.1 `lib.circom`

The v0.7 file with the compile fix (`BEBits` no longer switches templates; new `BEBitsField()`) and the new `StatementHash(n)`.

```circom
pragma circom 2.1.9;
include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/bitify.circom";
include "../node_modules/circomlib/circuits/comparators.circom";
include "../node_modules/circomlib/circuits/sha256/sha256.circom";

// Domain tags (capacity element of PoseidonEx)
function T_AK()    { return 1; }
function T_NK()    { return 2; }
function T_OWNER() { return 3; }
function T_PART()  { return 4; }
function T_CM()    { return 5; }
function T_NF()    { return 6; }
function T_DUMMY() { return 7; }
function T_NODE()  { return 8; }

// P(tag, in[0..n-1]) = PoseidonEx(n,1).out[0] with initialState = tag
template TaggedPoseidon(n, tag) {
    signal input in[n];
    signal output out;
    component p = PoseidonEx(n, 1);
    p.initialState <== tag;
    for (var i = 0; i < n; i++) { p.inputs[i] <== in[i]; }
    out <== p.out[0];
}

// Bottom-up fold, LSB-first direction bits: bit=0 -> current is left child.
template MerkleFold(depth) {
    signal input leaf;
    signal input sib[depth];
    signal input bits[depth];
    signal output root;
    signal cur[depth + 1];
    signal left[depth];
    component h[depth];
    cur[0] <== leaf;
    for (var i = 0; i < depth; i++) {
        bits[i] * (bits[i] - 1) === 0;
        left[i] <== cur[i] + bits[i] * (sib[i] - cur[i]);
        h[i] = TaggedPoseidon(2, T_NODE());
        h[i].in[0] <== left[i];
        h[i].in[1] <== cur[i] + sib[i] - left[i];
        cur[i + 1] <== h[i].out;
    }
    root <== cur[depth];
}

// Boolean: x != 0
template NonZero() {
    signal input in;
    component z = IsZero();
    z.in <== in;
    z.out === 0;
}

// Big-endian byte-stream bits of an unsigned value that fits in `width` bits,
// laid out as a `bytesLen`-byte field (leading zero bits). Returns MSB-first bits.
template BEBits(width, bytesLen) {
    signal input in;
    signal output out[bytesLen * 8];
    component n2b = Num2Bits(width);   // width <= 253 cannot wrap the field
    n2b.in <== in;
    var total = bytesLen * 8;
    for (var p = 0; p < total; p++) {
        var lsbIndex = total - 1 - p;
        if (lsbIndex < width) { out[p] <== n2b.out[lsbIndex]; } else { out[p] <== 0; }
    }
}

// Canonical (< r) field element as a big-endian 32-byte field: alias-checked 254-bit decomposition.
template BEBitsField() {
    signal input in;
    signal output out[256];
    component n2b = Num2Bits_strict();
    n2b.in <== in;
    out[0] <== 0; out[1] <== 0;
    for (var p = 2; p < 256; p++) { out[p] <== n2b.out[255 - p]; }
}

// H253 of a SHA-256 digest given as 256 MSB-first bits: drop the top 3 bits.
template H253FromDigest() {
    signal input digest[256];
    signal output out;
    var acc = 0;
    for (var p = 3; p < 256; p++) { acc += digest[p] * (1 << (255 - p)); }
    out <== acc;
}

// Root of an entry's aligned 4-leaf subtree.
template SubtreeRoot() {
    signal input l[4];
    signal output root;
    component a = TaggedPoseidon(2, T_NODE()); a.in[0] <== l[0]; a.in[1] <== l[1];
    component b = TaggedPoseidon(2, T_NODE()); b.in[0] <== l[2]; b.in[1] <== l[3];
    component c = TaggedPoseidon(2, T_NODE()); c.in[0] <== a.out; c.in[1] <== b.out;
    root <== c.out;
}

// v0.8 public-input hashing profile: out = H253(SHA256(u256be(w[0]) || ... || u256be(w[n-1]))).
// Every word is decomposed with the alias-checked field gadget, so each hashed word is the canonical integer < r.
template StatementHash(n) {
    signal input w[n];
    signal output out;
    component b[n];
    component sha = Sha256(n * 256);
    for (var i = 0; i < n; i++) {
        b[i] = BEBitsField(); b[i].in <== w[i];
        for (var p = 0; p < 256; p++) { sha.in[i * 256 + p] <== b[i].out[p]; }
    }
    component h = H253FromDigest();
    for (var p = 0; p < 256; p++) { h.digest[p] <== sha.out[p]; }
    out <== h.out;
}
```

### C.2 `batch.circom`

The v0.7 file with the component-array compile fix in the statement hash.

```circom
pragma circom 2.1.9;
include "lib.circom";

// One queue record -> next accumulator. record = acc(32) kind(1) w0..w3(4x32) extHash(32) tip(16) = 209 bytes
template AccStep() {
    signal input acc;
    signal input kind;
    signal input w[4];
    signal input extHash;
    signal input tip;
    signal output next;
    component bAcc = BEBits(253, 32); bAcc.in <== acc;
    component bKind = BEBits(8, 1);   bKind.in <== kind;
    component bW[4];
    for (var j = 0; j < 4; j++) { bW[j] = BEBitsField(); bW[j].in <== w[j]; }
    component bExt = BEBits(253, 32); bExt.in <== extHash;
    component bTip = BEBits(128, 16); bTip.in <== tip;
    component sha = Sha256(1672);
    var o = 0;
    for (var p = 0; p < 256; p++) { sha.in[o] <== bAcc.out[p]; o++; }
    for (var p = 0; p < 8; p++)   { sha.in[o] <== bKind.out[p]; o++; }
    for (var j = 0; j < 4; j++) { for (var p = 0; p < 256; p++) { sha.in[o] <== bW[j].out[p]; o++; } }
    for (var p = 0; p < 256; p++) { sha.in[o] <== bExt.out[p]; o++; }
    for (var p = 0; p < 128; p++) { sha.in[o] <== bTip.out[p]; o++; }
    component h = H253FromDigest();
    for (var p = 0; p < 256; p++) { h.digest[p] <== sha.out[p]; }
    next <== h.out;
}

// Record words -> the entry's 4-leaf subtree root.
// DEPOSIT (kind 1): words = (partial, value, asset, 0); leaf0 = P(T_CM, partial, value, asset), others 0.
template EntrySubtree() {
    signal input kind;
    signal input w[4];
    signal output root;
    component isDep = IsEqual(); isDep.in[0] <== kind; isDep.in[1] <== 1;
    component cmDep = TaggedPoseidon(3, T_CM()); cmDep.in[0] <== w[0]; cmDep.in[1] <== w[1]; cmDep.in[2] <== w[2];
    component sub = SubtreeRoot();
    sub.l[0] <== w[0] + isDep.out * (cmDep.out - w[0]);
    sub.l[1] <== w[1] - isDep.out * w[1];
    sub.l[2] <== w[2] - isDep.out * w[2];
    sub.l[3] <== w[3];
    root <== sub.root;
}

// maxK = 1 (BATCH_1) or 16 (BATCH_UPTO_16). Z2 = empty 4-leaf subtree root. Single public input: statement.
template BatchInsert(maxK, Z2) {
    signal input statement;
    // statement fields (bound only through the statement hash)
    signal input poolIdBits[256];
    signal input chainIdBits[256];
    signal input circuitId;
    signal input oldRoot;
    signal input newRoot;
    signal input start;
    signal input k;
    signal input accStart;
    signal input accEnd;
    signal input baseTipSum;
    signal input beneficiary;
    // per-entry witnesses (public data, private wires)
    signal input kind[maxK];
    signal input w[maxK][4];
    signal input extHash[maxK];
    signal input tip[maxK];
    signal input sib[maxK][30];

    // 1 <= k <= maxK
    component kLo = LessThan(8); kLo.in[0] <== 0;     kLo.in[1] <== k;        kLo.out === 1;
    component kHi = LessThan(8); kHi.in[0] <== k;     kHi.in[1] <== maxK + 1; kHi.out === 1;
    component startBits = Num2Bits(30); startBits.in <== start;

    signal accCur[maxK + 1];
    signal rootCur[maxK + 1];
    signal active[maxK];
    signal tipAcc[maxK + 1];
    accCur[0] <== accStart;
    rootCur[0] <== oldRoot;
    tipAcc[0] <== 0;
    component isAct[maxK];
    component step[maxK];
    component dep[maxK]; component tr[maxK]; component ex[maxK];
    component sub[maxK];
    component idxBits[maxK];
    component oldF[maxK];
    component newF[maxK];
    signal idx[maxK];
    for (var i = 0; i < maxK; i++) {
        isAct[i] = LessThan(8); isAct[i].in[0] <== i; isAct[i].in[1] <== k;
        active[i] <== isAct[i].out;
        dep[i] = IsEqual(); dep[i].in[0] <== kind[i]; dep[i].in[1] <== 1;
        tr[i] = IsEqual(); tr[i].in[0] <== kind[i]; tr[i].in[1] <== 2;
        ex[i] = IsEqual(); ex[i].in[0] <== kind[i]; ex[i].in[1] <== 3;
        dep[i].out + tr[i].out + ex[i].out === 1;
        dep[i].out * w[i][3] === 0;
        for (var j = 0; j < 4; j++) { ex[i].out * w[i][j] === 0; (1 - active[i]) * w[i][j] === 0; }
        (1 - active[i]) * (kind[i] - 3) === 0;
        (1 - active[i]) * extHash[i] === 0;
        (1 - active[i]) * tip[i] === 0;
        for (var h = 0; h < 30; h++) { (1 - active[i]) * sib[i][h] === 0; }

        step[i] = AccStep();
        step[i].acc <== accCur[i]; step[i].kind <== kind[i];
        for (var j = 0; j < 4; j++) { step[i].w[j] <== w[i][j]; }
        step[i].extHash <== extHash[i]; step[i].tip <== tip[i];
        accCur[i + 1] <== accCur[i] + active[i] * (step[i].next - accCur[i]);

        sub[i] = EntrySubtree(); sub[i].kind <== kind[i];
        for (var j = 0; j < 4; j++) { sub[i].w[j] <== w[i][j]; }

        idx[i] <== start + active[i] * i;
        idxBits[i] = Num2Bits(30); idxBits[i].in <== idx[i];
        oldF[i] = MerkleFold(30); newF[i] = MerkleFold(30);
        oldF[i].leaf <== Z2; newF[i].leaf <== sub[i].root;
        for (var h = 0; h < 30; h++) {
            oldF[i].sib[h] <== sib[i][h]; oldF[i].bits[h] <== idxBits[i].out[h];
            newF[i].sib[h] <== sib[i][h]; newF[i].bits[h] <== idxBits[i].out[h];
        }
        active[i] * (oldF[i].root - rootCur[i]) === 0;          // append-only: slot was empty
        rootCur[i + 1] <== rootCur[i] + active[i] * (newF[i].root - rootCur[i]);
        tipAcc[i + 1] <== tipAcc[i] + active[i] * tip[i];
    }
    rootCur[maxK] === newRoot;
    accCur[maxK] === accEnd;
    tipAcc[maxK] === baseTipSum;

    // statement = H253(SHA256(abi.encode(poolId, chainId, circuitId, oldRoot, newRoot, start, k,
    //                                     accStart, accEnd, baseTipSum, beneficiary)))  -- 11 words, 352 bytes
    // circom requires one template per component array, so the two field-width roots are separate components
    component fCirc = BEBits(8, 32);   fCirc.in <== circuitId;
    component fOld = BEBitsField();    fOld.in <== oldRoot;
    component fNew = BEBitsField();    fNew.in <== newRoot;
    component fStart = BEBits(30, 32); fStart.in <== start;
    component fK = BEBits(8, 32);      fK.in <== k;
    component fAccS = BEBits(253, 32); fAccS.in <== accStart;
    component fAccE = BEBits(253, 32); fAccE.in <== accEnd;
    component fTip = BEBits(132, 32);  fTip.in <== baseTipSum;
    component fBen = BEBits(160, 32);  fBen.in <== beneficiary;
    component sha = Sha256(2816);
    for (var p = 0; p < 256; p++) { poolIdBits[p] * (poolIdBits[p] - 1) === 0; sha.in[p] <== poolIdBits[p]; }
    for (var p = 0; p < 256; p++) { chainIdBits[p] * (chainIdBits[p] - 1) === 0; sha.in[256 + p] <== chainIdBits[p]; }
    for (var p = 0; p < 256; p++) {
        sha.in[512 + p] <== fCirc.out[p];   sha.in[768 + p] <== fOld.out[p];   sha.in[1024 + p] <== fNew.out[p];
        sha.in[1280 + p] <== fStart.out[p]; sha.in[1536 + p] <== fK.out[p];    sha.in[1792 + p] <== fAccS.out[p];
        sha.in[2048 + p] <== fAccE.out[p];  sha.in[2304 + p] <== fTip.out[p];  sha.in[2560 + p] <== fBen.out[p];
    }
    component hs = H253FromDigest();
    for (var p = 0; p < 256; p++) { hs.digest[p] <== sha.out[p]; }
    hs.out === statement;
}
```

### C.3 `hashed.circom` (new) and mains

```circom
pragma circom 2.1.9;
include "transfer.circom";

// v0.8 public-input hashing profile. Each wrapper exposes exactly one public input, `stmt`, and proves that
// stmt = StatementHash(the circuit's former public inputs, in their v0.7 order). The wrapped relation is unchanged.

template TransferH(nIn, nOut, depth) {
    signal input stmt;
    signal input noteDomain; signal input numAssets; signal input root; signal input publicAmount;
    signal input publicAsset; signal input extHash; signal input nf[nIn]; signal input cm[nOut];
    signal input sk; signal input asset;
    signal input inEnabled[nIn]; signal input inValue[nIn]; signal input inD[nIn]; signal input inRseed[nIn];
    signal input inPath[nIn][depth]; signal input inBits[nIn][depth]; signal input inDummySeed[nIn];
    signal input outOwner[nOut]; signal input outValue[nOut]; signal input outRseed[nOut];

    component t = Transfer(nIn, nOut, depth);
    t.noteDomain <== noteDomain; t.numAssets <== numAssets; t.root <== root; t.publicAmount <== publicAmount;
    t.publicAsset <== publicAsset; t.extHash <== extHash; t.sk <== sk; t.asset <== asset;
    for (var i = 0; i < nIn; i++) {
        t.nf[i] <== nf[i]; t.inEnabled[i] <== inEnabled[i]; t.inValue[i] <== inValue[i]; t.inD[i] <== inD[i];
        t.inRseed[i] <== inRseed[i]; t.inDummySeed[i] <== inDummySeed[i];
        for (var h = 0; h < depth; h++) { t.inPath[i][h] <== inPath[i][h]; t.inBits[i][h] <== inBits[i][h]; }
    }
    for (var j = 0; j < nOut; j++) { t.cm[j] <== cm[j]; t.outOwner[j] <== outOwner[j]; t.outValue[j] <== outValue[j]; t.outRseed[j] <== outRseed[j]; }

    component s = StatementHash(6 + nIn + nOut);
    s.w[0] <== noteDomain; s.w[1] <== numAssets; s.w[2] <== root; s.w[3] <== publicAmount; s.w[4] <== publicAsset; s.w[5] <== extHash;
    for (var i = 0; i < nIn; i++) { s.w[6 + i] <== nf[i]; }
    for (var j = 0; j < nOut; j++) { s.w[6 + nIn + j] <== cm[j]; }
    s.out === stmt;
}

template ExitH(nIn, depth) {
    signal input stmt;
    signal input noteDomain; signal input numAssets; signal input root; signal input publicAmount;
    signal input publicAsset; signal input extHash; signal input nf[nIn];
    signal input sk; signal input asset;
    signal input inEnabled[nIn]; signal input inValue[nIn]; signal input inD[nIn]; signal input inRseed[nIn];
    signal input inPath[nIn][depth]; signal input inBits[nIn][depth]; signal input inDummySeed[nIn];

    component t = Exit(nIn, depth);
    t.noteDomain <== noteDomain; t.numAssets <== numAssets; t.root <== root; t.publicAmount <== publicAmount;
    t.publicAsset <== publicAsset; t.extHash <== extHash; t.sk <== sk; t.asset <== asset;
    for (var i = 0; i < nIn; i++) {
        t.nf[i] <== nf[i]; t.inEnabled[i] <== inEnabled[i]; t.inValue[i] <== inValue[i]; t.inD[i] <== inD[i];
        t.inRseed[i] <== inRseed[i]; t.inDummySeed[i] <== inDummySeed[i];
        for (var h = 0; h < depth; h++) { t.inPath[i][h] <== inPath[i][h]; t.inBits[i][h] <== inBits[i][h]; }
    }
    component s = StatementHash(6 + nIn);
    s.w[0] <== noteDomain; s.w[1] <== numAssets; s.w[2] <== root; s.w[3] <== publicAmount; s.w[4] <== publicAsset; s.w[5] <== extHash;
    for (var i = 0; i < nIn; i++) { s.w[6 + i] <== nf[i]; }
    s.out === stmt;
}

template TransferDirectH(depth, Z2) {
    signal input stmt;
    signal input noteDomain; signal input numAssets; signal input root; signal input publicAmount;
    signal input publicAsset; signal input extHash; signal input nf[2]; signal input cm[4];
    signal input newRoot; signal input ownIndex; signal input absorbIndex; signal input absorbPartial;
    signal input absorbValue; signal input absorbAsset;
    signal input sk; signal input asset;
    signal input inEnabled[2]; signal input inValue[2]; signal input inD[2]; signal input inRseed[2];
    signal input inPath[2][depth]; signal input inBits[2][depth]; signal input inDummySeed[2];
    signal input outOwner[4]; signal input outValue[4]; signal input outRseed[4];
    signal input absorbSib[depth - 2]; signal input ownSib[depth - 2];

    component t = TransferDirect(depth, Z2);
    t.noteDomain <== noteDomain; t.numAssets <== numAssets; t.root <== root; t.publicAmount <== publicAmount;
    t.publicAsset <== publicAsset; t.extHash <== extHash; t.newRoot <== newRoot; t.ownIndex <== ownIndex;
    t.absorbIndex <== absorbIndex; t.absorbPartial <== absorbPartial; t.absorbValue <== absorbValue; t.absorbAsset <== absorbAsset;
    t.sk <== sk; t.asset <== asset;
    for (var i = 0; i < 2; i++) {
        t.nf[i] <== nf[i]; t.inEnabled[i] <== inEnabled[i]; t.inValue[i] <== inValue[i]; t.inD[i] <== inD[i];
        t.inRseed[i] <== inRseed[i]; t.inDummySeed[i] <== inDummySeed[i];
        for (var h = 0; h < depth; h++) { t.inPath[i][h] <== inPath[i][h]; t.inBits[i][h] <== inBits[i][h]; }
    }
    for (var j = 0; j < 4; j++) { t.cm[j] <== cm[j]; t.outOwner[j] <== outOwner[j]; t.outValue[j] <== outValue[j]; t.outRseed[j] <== outRseed[j]; }
    for (var h = 0; h < depth - 2; h++) { t.absorbSib[h] <== absorbSib[h]; t.ownSib[h] <== ownSib[h]; }

    component s = StatementHash(18);
    s.w[0] <== noteDomain; s.w[1] <== numAssets; s.w[2] <== root; s.w[3] <== publicAmount; s.w[4] <== publicAsset; s.w[5] <== extHash;
    s.w[6] <== nf[0]; s.w[7] <== nf[1];
    for (var j = 0; j < 4; j++) { s.w[8 + j] <== cm[j]; }
    s.w[12] <== newRoot; s.w[13] <== ownIndex; s.w[14] <== absorbIndex; s.w[15] <== absorbPartial; s.w[16] <== absorbValue; s.w[17] <== absorbAsset;
    s.out === stmt;
}
```

```circom
pragma circom 2.1.9;
include "hashed.circom";
component main {public [stmt]} = TransferH(2, 4, 32);
pragma circom 2.1.9;
include "hashed.circom";
component main {public [stmt]} = TransferH(8, 4, 32);
pragma circom 2.1.9;
include "hashed.circom";
component main {public [stmt]} = ExitH(2, 32);
pragma circom 2.1.9;
include "hashed.circom";
component main {public [stmt]} = TransferDirectH(32, 8508108280010681241885759795573805045462523017836069467999300010978555398910);
```

### C.4 Development stand-in circuits (tests only, never production)

```circom
pragma circom 2.1.9;
// Development stand-in relation with one public input, for verifier and pool plumbing tests only.
template Toy() { signal input stmt; signal input x; signal x2; x2 <== x * x; stmt === x2 + 7; }
component main {public [stmt]} = Toy();
pragma circom 2.1.9;
// Development stand-in with three public inputs.
template Toy3() { signal input s[3]; signal input x; signal x2; x2 <== x * x; s[0] === x2 + 7; s[1] === x * s[0]; s[2] === s[1] * x; }
component main {public [s]} = Toy3();
pragma circom 2.1.9;
// Development stand-in: proves knowledge of nothing; binds k public inputs (each appears in a constraint).
template ToyK(k) { signal input s[k]; signal sq[k]; for (var j = 0; j < k; j++) { sq[j] <== s[j] * s[j]; } }
component main {public [s]} = ToyK(12);
```

`toyk1/8/18.circom` are identical to `toyk12.circom` apart from `k`. Each binds k public inputs (every input appears in a constraint) and proves nothing else. They exist only so that real pairing verification of pool-built statements can run at production public-input counts.

## Appendix D: Reference model (`ref/seth8.js`)

v0.7's `seth7.js` with v8 domain strings and the statement helpers `transferPub` and `statementOf`.

```javascript
// ShieldedETH v0.7 reference model (non-constant-time; for vectors and tests only).
// Deps: circomlibjs@0.1.7, @noble/curves@1.6.0, @noble/hashes@1.5.0, @noble/ciphers@1.0.0, ethers@5
"use strict";
const { buildPoseidonReference } = require("circomlibjs");
const { RistrettoPoint } = require("@noble/curves/ed25519");
const { sha256 } = require("@noble/hashes/sha256");
const { sha512 } = require("@noble/hashes/sha512");
const { hkdf, extract, expand } = require("@noble/hashes/hkdf");
const { chacha20poly1305 } = require("@noble/ciphers/chacha");
const { ethers } = require("ethers");

const r = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const L25519 = 2n ** 252n + 27742317777372353535851937790883648493n; // ristretto255 group order
const MASK253 = (1n << 253n) - 1n;
const VERSION = 8;
const T = { AK: 1n, NK: 2n, OWNER: 3n, PART: 4n, CM: 5n, NF: 6n, DUMMY: 7n, NODE: 8n };
const KIND = { DEPOSIT: 1, TRANSFER: 2, EXIT: 3 }; // record kind == operation code
const CIRCUIT = { TRANSFER_2_4: 1, TRANSFER_8_4: 2, EXIT_2_0: 3, BATCH_1: 4, BATCH_UPTO_16: 5, TRANSFER_2_4_DIRECT: 6 };

const utf8 = (s) => new TextEncoder().encode(s);
const cat = (...a) => { const n = a.reduce((s, x) => s + x.length, 0); const o = new Uint8Array(n); let i = 0; for (const x of a) { o.set(x, i); i += x.length; } return o; };
const beN = (x, n) => { if (BigInt(x) < 0n || !Number.isSafeInteger(n) || n < 1) throw Error("bad unsigned integer"); const o = new Uint8Array(n); let v = BigInt(x); for (let i = n - 1; i >= 0; i--) { o[i] = Number(v & 0xffn); v >>= 8n; } if (v) throw Error("overflow"); return o; };
const toBig = (b) => BigInt("0x" + (Buffer.from(b).toString("hex") || "0"));
const toBigLE = (b) => toBig(Uint8Array.from(b).reverse());
const H253 = (digest) => toBig(digest) & MASK253;
const hex = (b) => "0x" + Buffer.from(b).toString("hex");
const b64u = (b) => Buffer.from(b).toString("base64url");

let _P;
async function init() { const p = await buildPoseidonReference(); _P = (tag, xs) => p.F.toObject(p(xs, tag)); }
const P = (tag, ...xs) => _P(tag, xs); // PoseidonEx(n,1).out[0] with initialState = tag

// ---------- keys (HKDF-SHA256) ----------
function walletKeys(seed) {
  if (!(seed instanceof Uint8Array) || seed.length !== 32) throw Error("seed length");
  const prk = extract(sha256, seed, sha256(utf8("ShieldedETH/v0.8/wallet")));
  let sk, ivk;
  for (let c = 0; ; c++) { sk = toBig(expand(sha256, prk, cat(utf8("sk/"), beN(c, 4)), 32)); if (sk >= 1n && sk < r) break; }
  for (let c = 0; ; c++) { ivk = toBigLE(expand(sha256, prk, cat(utf8("ivk/"), beN(c, 4)), 64)) % L25519; if (ivk !== 0n) break; }
  const ovk = expand(sha256, prk, utf8("ovk"), 32);
  return { sk, ak: P(T.AK, sk), nk: P(T.NK, sk), ivk, ovk };
}
const baseFor = (d) => RistrettoPoint.hashToCurve(sha512(cat(utf8("SETH/v8/div"), d)));
function address(keys, d, poolId) {
  if (d.length !== 11 || poolId.length !== 32) throw Error("address inputs");
  const Hd = baseFor(d), pkd = Hd.multiply(keys.ivk);
  if (Hd.equals(RistrettoPoint.ZERO) || pkd.equals(RistrettoPoint.ZERO)) throw Error("identity point");
  const owner = P(T.OWNER, keys.ak, toBig(d));
  const payload = cat(Uint8Array.of(VERSION), poolId.slice(0, 8), d, beN(owner, 32), pkd.toRawBytes());
  const check = sha256(cat(utf8("SETH/v8/address"), payload)).slice(0, 8);
  return { d, owner, pkd, Hd, text: "seth8:" + b64u(cat(payload, check)) };
}

// ---------- notes ----------
const partialOf = (owner, rseed) => P(T.PART, owner, rseed);
const cmOf = (partial, value, asset) => P(T.CM, partial, value, BigInt(asset));
const nfReal = (noteDomain, nk, cm, pos) => P(T.NF, noteDomain, nk, cm, BigInt(pos));
const nfDummy = (noteDomain, seed, slot) => P(T.DUMMY, noteDomain, seed, BigInt(slot));

// ---------- delivery (109-byte recipient ciphertext) ----------
function eskOf(poolId, rseed) {
  for (let c = 0; ; c++) { const e = toBigLE(sha512(cat(utf8("SETH/v8/esk"), poolId, beN(rseed, 32), beN(c, 4)))) % L25519; if (e) return e; }
}
function seal(poolId, addr, value, asset, rseed, cm) {
  if (value < 0n || value >= (1n << 128n) || !Number.isInteger(asset) || asset < 0 || asset >= 8 || rseed <= 0n || rseed >= r || cm <= 0n || cm >= r) throw Error("note range");
  if (cmOf(partialOf(addr.owner, rseed), value, asset) !== cm) throw Error("note commitment mismatch");
  const esk = eskOf(poolId, rseed), epk = addr.Hd.multiply(esk), ss = RistrettoPoint.fromHex(addr.pkd.toRawBytes()).multiply(esk);
  const ctx = cat(Uint8Array.of(VERSION), poolId, beN(cm, 32), epk.toRawBytes());
  const m = expand(sha256, extract(sha256, ss.toRawBytes(), sha256(utf8("SETH/v8/note"))), ctx, 44);
  const pt = cat(Uint8Array.of(VERSION), beN(value, 16), Uint8Array.of(asset), addr.d, beN(rseed, 32));
  return { esk, ct: cat(epk.toRawBytes(), chacha20poly1305(m.slice(0, 32), m.slice(32, 44), ctx).encrypt(pt)) };
}
function open(poolId, keys, ct, cm, numAssets) {
  if (!_P) throw Error("reference model not initialized");
  if (!Number.isInteger(numAssets) || numAssets < 2 || numAssets > 8) throw Error("manifest asset count");
  if (!keys || keys.ivk <= 0n || keys.ivk >= L25519) throw Error("invalid local viewing key");
  if (!(ct instanceof Uint8Array) || ct.length !== 109 || poolId.length !== 32 || cm <= 0n || cm >= r) return null;
  // All attacker-controlled point parsing and cryptography stay inside the rejection boundary.
  try {
    const epkB = ct.slice(0, 32), epk = RistrettoPoint.fromHex(epkB);
    if (epk.equals(RistrettoPoint.ZERO)) return null;
    const ss = epk.multiply(keys.ivk);
    const ctx = cat(Uint8Array.of(VERSION), poolId, beN(cm, 32), epkB);
    const m = expand(sha256, extract(sha256, ss.toRawBytes(), sha256(utf8("SETH/v8/note"))), ctx, 44);
    const pt = chacha20poly1305(m.slice(0, 32), m.slice(32, 44), ctx).decrypt(ct.slice(32));
    if (pt.length !== 61 || pt[0] !== VERSION) return null;
    const value = toBig(pt.slice(1, 17)), asset = pt[17], d = pt.slice(18, 29), rseed = toBig(pt.slice(29, 61));
    if (asset >= numAssets || rseed === 0n || rseed >= r) return null;
    const Hd = baseFor(d);
    if (Hd.equals(RistrettoPoint.ZERO) || !Hd.multiply(eskOf(poolId, rseed)).equals(epk)) return null;
    const owner = P(T.OWNER, keys.ak, toBig(d));
    return cmOf(partialOf(owner, rseed), value, asset) === cm ? { value, asset, d, rseed, owner } : null;
  } catch { return null; }
}


// ---------- pool identity, queue, tree ----------
function poolIdOf(chainId, poolAddr, salt) {
  return ethers.utils.arrayify(ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(
    ["bytes32", "uint16", "uint256", "address", "bytes32"],
    [ethers.utils.keccak256(utf8("ShieldedETH")), VERSION, chainId, poolAddr, salt])));
}
const noteDomainOf = (poolId) => toBig(poolId) & MASK253;
const acc0Of = (poolId) => H253(sha256(cat(utf8("SETH/v8/acc"), poolId)));
function recordBytes(acc, kind, w, extHash, tip) { // 209 bytes
  return cat(beN(acc, 32), Uint8Array.of(kind), ...w.map((x) => beN(x, 32)), beN(extHash, 32), beN(tip, 16));
}
const accStep = (acc, kind, w, extHash, tip) => H253(sha256(recordBytes(acc, kind, w, extHash, tip)));
function leavesOf(kind, w) { return kind === KIND.DEPOSIT ? [cmOf(w[0], w[1], w[2]), 0n, 0n, 0n] : w.slice(); }

let Z;
function zeros() { if (!Z) { Z = [0n]; for (let h = 0; h < 32; h++) Z.push(P(T.NODE, Z[h], Z[h])); } return Z; }
class Tree { // sparse depth-32 tree, entries = aligned 4-leaf subtrees
  constructor() { this.nodes = new Map(); zeros(); }
  get(h, i) { return this.nodes.get(h + ":" + i) ?? Z[h]; }
  set(h, i, v) { this.nodes.set(h + ":" + i, v); }
  insertEntry(e, leaves) {
    if (!Number.isSafeInteger(e) || e < 0 || e >= 2 ** 30 || leaves.length !== 4) throw Error("entry bounds");
    leaves.forEach((x, j) => this.set(0, 4 * e + j, x));
    this.set(1, 2 * e, P(T.NODE, leaves[0], leaves[1]));
    this.set(1, 2 * e + 1, P(T.NODE, leaves[2], leaves[3]));
    let q = 2 * e;
    for (let h = 1; h < 32; h++) { q = Math.floor(q / 2); this.set(h + 1, q, P(T.NODE, this.get(h, 2 * q), this.get(h, 2 * q + 1))); }
  }
  root() { return this.get(32, 0); }
  entryPath(e) { const sib = []; for (let h = 2; h < 32; h++) sib.push(this.get(h, (Math.floor(e / 2 ** (h - 2)) % 2 === 0 ? Math.floor(e / 2 ** (h - 2)) + 1 : Math.floor(e / 2 ** (h - 2)) - 1))); return sib; }
  path(pos) { if (!Number.isSafeInteger(pos) || pos < 0 || pos >= 2 ** 32) throw Error("position bounds"); const sib = [], bits = []; let i = pos; for (let h = 0; h < 32; h++) { sib.push(this.get(h, (i % 2 === 0 ? i + 1 : i - 1))); bits.push(i % 2); i = Math.floor(i / 2); } return { sib, bits }; }
}
function fold(leaf, sib, bits) { let x = leaf; for (let h = 0; h < sib.length; h++) x = bits[h] ? P(T.NODE, sib[h], x) : P(T.NODE, x, sib[h]); return x; }

// ---------- batch statement ----------
function batchStatement(s) {
  const enc = ethers.utils.defaultAbiCoder.encode(
    ["bytes32", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
    [s.poolId, s.chainId, s.circuitId, s.oldRoot, s.newRoot, s.start, s.k, s.accStart, s.accEnd, s.baseTipSum, s.beneficiary]);
  return H253(sha256(ethers.utils.arrayify(enc)));
}

// ---------- canonical bodies ----------
const BODY_TAG = ethers.utils.keccak256(utf8("SETH/v8/BODY"));
const HDR = ["bytes32", "uint16", "uint8", "uint8", "bytes32", "uint256", "uint128"];
const TRANSFER_BODY = "tuple(uint64 rootSeq,uint256 root,uint256[] nullifiers,uint256[4] commitments,uint128 W,uint8 publicAsset,uint128 tip,address recipient,uint32 payoutGas,address executor,uint64 deadline,bytes32 nonce,bytes recipientCiphertexts,bytes recoveryCiphertext)";
const EXIT_BODY = "tuple(uint64 rootSeq,uint256 root,uint256[2] nullifiers,uint128 W,uint8 publicAsset,uint128 tip,address recipient,uint32 payoutGas,address executor,uint64 deadline,bytes32 nonce)";
const DEPOSIT_BODY = "tuple(uint8 asset,uint256 partial,uint128 amount,uint128 tip,bytes ciphertext)";
function canonicalBody(op, circuitId, poolId, chainId, V, schema, body) {
  return ethers.utils.defaultAbiCoder.encode([...HDR, schema], [BODY_TAG, VERSION, op, circuitId, poolId, chainId, V, body]);
}
const DIRECT_CONTEXT = "tuple(uint40 expectedInserted,uint40 expectedNext,uint256 expectedInsertedAcc,uint256 expectedQueueAcc,uint256 newRoot,address rewardBeneficiary,bytes32 pendingHash)";
const PENDING_RECORD = "tuple(uint8 kind,uint256[4] w,uint256 extHash,uint128 tip)";
function pendingHash(records) { return ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([PENDING_RECORD + "[]"], [records])); }
function canonicalDirectBody(poolId, chainId, b, d) {
  return ethers.utils.defaultAbiCoder.encode([...HDR, TRANSFER_BODY, DIRECT_CONTEXT], [BODY_TAG, VERSION, KIND.TRANSFER, CIRCUIT.TRANSFER_2_4_DIRECT, poolId, chainId, 0n, b, d]);
}
const extHashOf = (bodyBytes) => H253(ethers.utils.arrayify(ethers.utils.keccak256(bodyBytes)));

// ---------- insertion scheduling ----------
function nextBatch(inserted, queued, stride = 16) {
  if (![inserted, queued, stride].every(Number.isSafeInteger) || inserted < 0 || queued < inserted || queued > 2 ** 30 || stride !== 16) throw Error("scheduler bounds");
  if (inserted >= queued) return null;
  const end = Math.min(queued, stride * (Math.floor(inserted / stride) + 1));
  return { start: inserted, k: end - inserted, end };
}

// ---------- v0.8 statements ----------
/** Native public-input vector for a queued TRANSFER_2_4 (v0.7 order). */
function transferPub(noteDomain, numAssets, b, extHash) {
  const pubAmt = BigInt(b.W) === 0n ? 0n : r - BigInt(b.W);
  return [noteDomain, BigInt(numAssets), BigInt(b.root), pubAmt, BigInt(b.publicAsset), extHash, ...b.nullifiers.map(BigInt), ...b.commitments.map(BigInt)];
}
/** v0.8 hashed profile: H253(SHA256(u256be(w0) || ... )). */
function statementOf(words) { return H253(sha256(cat(...words.map((w) => beN(BigInt(w), 32))))); }
module.exports = { transferPub, statementOf, init, r, L25519, T, KIND, CIRCUIT, VERSION, P, walletKeys, address, partialOf, cmOf, nfReal, nfDummy, seal, open,
  poolIdOf, noteDomainOf, acc0Of, recordBytes, accStep, leavesOf, zeros, Tree, fold, batchStatement, canonicalBody,
  extHashOf, nextBatch, canonicalDirectBody, pendingHash, DIRECT_CONTEXT, PENDING_RECORD, TRANSFER_BODY, EXIT_BODY, DEPOSIT_BODY, beN, toBig, hex, cat, utf8, H253 };
```

## Appendix E: Tests and recorded output

### E.1 `tests/verifier_test.js`

```javascript
"use strict";
// Real-pairing tests of SethGroth16Verifier against snarkjs-generated verifiers (development toy circuits). Fail-closed.
const fs = require("fs"), path = require("path"), solc = require("solc"), assert = require("assert"), snarkjs = require("snarkjs");
const { ethers } = require("ethers"); const { VM } = require("@ethereumjs/vm");
const { Common, Chain, Hardfork } = require("@ethereumjs/common"); const { Address, Account } = require("@ethereumjs/util");
const R = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583n;
const TOY = path.join(__dirname, "../toy");
const cdOf = async (proof, pub) => JSON.parse("[" + (await snarkjs.groth16.exportSolidityCallData(proof, pub)) + "]");
/** Development proof that the 1-input toy relation holds for statement `stmt` (needs stmt - 7 to be a square mod r). */
async function toyProofFor(stmt, F) {
  const x = F.sqrt(F.e((stmt - 7n + R) % R)); if (x === null) return null;
  const xs = F.toObject(x);
  const { proof, publicSignals } = await snarkjs.groth16.fullProve({ stmt: stmt.toString(), x: xs.toString() }, `${TOY}/toy_js/toy.wasm`, `${TOY}/toy.zkey`);
  const cd = await cdOf(proof, publicSignals); return { a: cd[0], b: cd[1], c: cd[2], pub: [stmt] };
}
async function toy3Proof(x) {
  const s0 = (x * x + 7n) % R, s1 = (x * s0) % R, s2 = (s1 * x) % R;
  const { proof, publicSignals } = await snarkjs.groth16.fullProve({ s: [s0, s1, s2].map(String), x: x.toString() }, `${TOY}/toy3_js/toy3.wasm`, `${TOY}/toy3.zkey`);
  const cd = await cdOf(proof, publicSignals); return { a: cd[0], b: cd[1], c: cd[2], pub: [s0, s1, s2] };
}
function vkArgs(vk) {
  const g2 = (v) => [v[0][1], v[0][0], v[1][1], v[1][0]];
  return [[vk.vk_alpha_1[0], vk.vk_alpha_1[1]], g2(vk.vk_beta_2), g2(vk.vk_gamma_2), g2(vk.vk_delta_2), vk.IC.flatMap((p) => [p[0], p[1]])];
}
module.exports = { toyProofFor, vkArgs };
if (require.main === module) (async () => {
  const { ZqField } = require("ffjavascript"); const F = new ZqField(R);
  const src = { "V.sol": { content: fs.readFileSync(path.join(__dirname, "../contracts/SethGroth16Verifier.sol"), "utf8") },
    "S1.sol": { content: fs.readFileSync(`${TOY}/SnarkjsToyVerifier.sol`, "utf8") }, "S3.sol": { content: fs.readFileSync(`${TOY}/SnarkjsToy3Verifier.sol`, "utf8") } };
  const out = JSON.parse(solc.compile(JSON.stringify({ language: "Solidity", sources: src, settings: { viaIR: true, optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun", outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] } } } })));
  for (const e of out.errors || []) if (e.severity === "error") throw Error(e.formattedMessage);
  const C = {}; for (const f of Object.values(out.contracts)) for (const [n, v] of Object.entries(f)) C[n] = { bin: "0x" + v.evm.bytecode.object, rt: v.evm.deployedBytecode.object.length / 2, iface: new ethers.utils.Interface(v.abi) };
  console.log("SethGroth16Verifier runtime:", C.SethGroth16Verifier.rt, "bytes");
  const vm = await VM.create({ common: new Common({ chain: Chain.Mainnet, hardfork: Hardfork.Cancun }) });
  const me = Address.fromString("0x1000000000000000000000000000000000000001");
  await vm.stateManager.putAccount(me, Account.fromAccountData({ balance: 10n ** 20n }));
  const run = async (to, iface, fn, args) => {
    const data = to ? ethers.utils.arrayify(iface.encodeFunctionData(fn, args)) : ethers.utils.arrayify(fn);
    const r = await vm.evm.runCall({ caller: me, to: to ? Address.fromString(to) : undefined, data, gasLimit: 30_000_000n });
    if (r.execResult.exceptionError) throw Error(`${fn} reverted: ${r.execResult.exceptionError.error}`);
    return to ? { v: iface.decodeFunctionResult(fn, r.execResult.returnValue)[0], gas: Number(r.execResult.executionGasUsed) } : r.createdAddress.toString();
  };
  const V = C.SethGroth16Verifier; let checks = 0;
  for (const [label, vkFile, sjName, mk] of [["k=1", "vk.json", "Groth16Verifier", (i) => toyProofFor((BigInt(i) * 7919n + 11n) ** 2n % R + 7n, F)],
                                              ["k=3", "vk3.json", "Groth16Verifier3", (i) => toy3Proof(BigInt(i) * 1000003n)]]) {
    const vk = JSON.parse(fs.readFileSync(`${TOY}/${vkFile}`));
    const seth = await run(null, V.iface, V.bin + V.iface.encodeDeploy(vkArgs(vk)).slice(2));
    const SJ = C[sjName]; const sj = await run(null, SJ.iface, SJ.bin);
    assert.equal(Number((await run(seth, V.iface, "nPublic", [])).v), vk.nPublic);
    const proofs = []; for (let i = 1; i <= 16; i++) proofs.push(await mk(i));
    for (const p of proofs.slice(0, 3)) {
      assert.equal((await run(seth, V.iface, "verify", [[p.a, p.b, p.c], p.pub])).v, true);
      assert.equal((await run(sj, SJ.iface, "verifyProof", [p.a, p.b, p.c, p.pub])).v, true);
      const bad = p.pub.slice(); bad[bad.length - 1] = bad[bad.length - 1] + 1n;
      assert.equal((await run(seth, V.iface, "verify", [[p.a, p.b, p.c], bad])).v, false);
      assert.equal((await run(sj, SJ.iface, "verifyProof", [p.a, p.b, p.c, bad])).v, false); checks += 4;
    }
    const g1 = await run(seth, V.iface, "verify", [[proofs[0].a, proofs[0].b, proofs[0].c], proofs[0].pub]);
    const gs = await run(sj, SJ.iface, "verifyProof", [proofs[0].a, proofs[0].b, proofs[0].c, proofs[0].pub]);
    console.log(`${label}: single verify agrees with snarkjs verifier (valid and invalid); gas ${g1.gas} vs snarkjs ${gs.gas}`);
    const batch = (ps) => [ps.map((p) => [p.a, p.b, p.c]), ps.flatMap((p) => p.pub)];
    const rows = [];
    for (const n of [1, 2, 4, 8, 16]) { const r = await run(seth, V.iface, "verifyBatch", batch(proofs.slice(0, n))); assert.equal(r.v, true); checks++; rows.push(`n=${n}: ${r.gas} (${Math.round(r.gas / n)}/proof)`); }
    console.log(`${label}: batch gas ${rows.join(", ")}`);
    const neg = [
      ["input off by one", ([pp, xs]) => { xs[5] = xs[5] + 1n; return [pp, xs]; }],
      ["inputs of two proofs swapped", ([pp, xs]) => { const k = xs.length / pp.length; for (let j = 0; j < k; j++) [xs[2 * k + j], xs[3 * k + j]] = [xs[3 * k + j], xs[2 * k + j]]; return [pp, xs]; }],
      ["C point taken from another proof", ([pp, xs]) => { pp[4] = [pp[4][0], pp[4][1], pp[6][2]]; return [pp, xs]; }],
      ["noncanonical coordinate", ([pp, xs]) => { pp[1] = [[BigInt(pp[1][0][0]) + Q, pp[1][0][1]], pp[1][1], pp[1][2]]; return [pp, xs]; }],
      ["input >= R", ([pp, xs]) => { xs[0] = xs[0] + R; return [pp, xs]; }],
      ["wrong input count", ([pp, xs]) => [pp, xs.slice(1)]],
    ];
    for (const [l, f] of neg) { assert.equal((await run(seth, V.iface, "verifyBatch", f(batch(proofs.slice(0, 8))))).v, false, l); checks++; }
    console.log(`${label}: batch rejects all ${neg.length} malformed/invalid variants`);
  }
  console.log(`${checks} assertions passed`);
  process.exit(0);
})().catch((e) => { console.error("FAIL:", e.message); process.exit(1); });
```

```text
SethGroth16Verifier runtime: 5144 bytes
k=1: single verify agrees with snarkjs verifier (valid and invalid); gas 194533 vs snarkjs 188457
k=1: batch gas n=1: 224226 (224226/proof), n=2: 275206 (137603/proof), n=4: 377180 (94295/proof), n=8: 581183 (72648/proof), n=16: 989405 (61838/proof)
k=1: batch rejects all 6 malformed/invalid variants
k=3: single verify agrees with snarkjs verifier (valid and invalid); gas 210107 vs snarkjs 201648
k=3: batch gas n=1: 240726 (240726/proof), n=2: 292904 (146452/proof), n=4: 397274 (99319/proof), n=8: 606075 (75759/proof), n=16: 1023921 (63995/proof)
k=3: batch rejects all 6 malformed/invalid variants
46 assertions passed
```

### E.2 `tests/hashed_circuit_test.js`

This uses v0.7's `ref/circuit_expectations.js`, unchanged.

```javascript
"use strict";
// v0.8 hashed-statement profile: circuits must accept exactly stmt = H253(SHA256(words)) computed by the reference. Fail-closed.
const S = require("../ref/seth8"); const { expectWitness } = require("../ref/circuit_expectations");
const path = require("path");
const B = path.join(__dirname, "../circuits/build"), CLI = path.join(__dirname, "../node_modules/snarkjs/build/cli.cjs");
const s = (x) => BigInt(x).toString();
(async () => {
  await S.init();
  const poolId = S.poolIdOf(1, "0x00000000000000000000000000000000005E7008", "0x" + "00".repeat(32));
  const noteDomain = S.noteDomainOf(poolId), R0 = S.zeros()[32];
  const alice = S.walletKeys(Uint8Array.from({ length: 32 }, (_, i) => i + 1)), bob = S.walletKeys(Uint8Array.from({ length: 32 }, (_, i) => 100 + i));
  const dA = Uint8Array.from({ length: 11 }, (_, i) => 0xa0 + i), dB = Uint8Array.from({ length: 11 }, () => 0xb0);
  const A = S.address(alice, dA, poolId), Bo = S.address(bob, dB, poolId);
  const rseed = 0xa11ce5n, partial = S.partialOf(A.owner, rseed), cmDep = S.cmOf(partial, 100n, 1), w0 = [partial, 100n, 1n, 0n];
  const t1 = new S.Tree(); t1.insertEntry(0, S.leavesOf(S.KIND.DEPOSIT, w0));
  const outs = [[Bo.owner, 30n], [A.owner, 69n], [A.owner, 1n], [A.owner, 0n]].map(([o, v], j) => ({ owner: o, value: v, rseed: 900n + BigInt(j) }));
  const cms = outs.map((o) => S.cmOf(S.partialOf(o.owner, o.rseed), o.value, 1));
  const t2 = new S.Tree(); t2.insertEntry(0, S.leavesOf(S.KIND.DEPOSIT, w0)); t2.insertEntry(1, cms); const R2 = t2.root();
  const nf0 = S.nfReal(noteDomain, alice.nk, cmDep, 0), nf1 = S.nfDummy(noteDomain, 31337n, 1);
  const { sib, bits } = t1.path(0);
  const words = [noteDomain, 2n, R0, 0n, 0n, 123456789n, nf0, nf1, ...cms, R2, 1n, 0n, partial, 100n, 1n];
  const direct = { stmt: s(S.statementOf(words)),
    noteDomain: s(noteDomain), numAssets: "2", root: s(R0), publicAmount: "0", publicAsset: "0", extHash: "123456789", nf: [s(nf0), s(nf1)], cm: cms.map(s),
    newRoot: s(R2), ownIndex: "1", absorbIndex: "0", absorbPartial: s(partial), absorbValue: "100", absorbAsset: "1",
    sk: s(alice.sk), asset: "1", inEnabled: ["1", "0"], inValue: ["100", "0"], inD: [s(S.toBig(dA)), "0"], inRseed: [s(rseed), "0"],
    inPath: [sib.map(s), Array(32).fill("0")], inBits: [bits.map(String), Array(32).fill("0")], inDummySeed: ["1", "31337"],
    outOwner: outs.map((o) => s(o.owner)), outValue: outs.map((o) => s(o.value)), outRseed: outs.map((o) => s(o.rseed)),
    absorbSib: new S.Tree().entryPath(0).map(s), ownSib: t1.entryPath(1).map(s) };
  // queued TRANSFER_2_4H: Alice spends her 69 change (position 5) under R2, withdrawing 20 publicly in asset 1
  const p5 = t2.path(5), W = 20n;
  const o3 = [49n, 0n, 0n, 0n].map((v, j) => ({ owner: A.owner, value: v, rseed: 1200n + BigInt(j) }));
  const cms3 = o3.map((o) => S.cmOf(S.partialOf(o.owner, o.rseed), o.value, 1));
  const nfC = S.nfReal(noteDomain, alice.nk, cms[1], 5), nfD = S.nfDummy(noteDomain, 55n, 1);
  const tw = [noteDomain, 2n, R2, S.r - W, 1n, 777n, nfC, nfD, ...cms3];
  const transfer = { stmt: s(S.statementOf(tw)), noteDomain: s(noteDomain), numAssets: "2", root: s(R2), publicAmount: s(S.r - W), publicAsset: "1", extHash: "777",
    nf: [s(nfC), s(nfD)], cm: cms3.map(s), sk: s(alice.sk), asset: "1", inEnabled: ["1", "0"], inValue: ["69", "0"], inD: [s(S.toBig(dA)), "0"], inRseed: [s(outs[1].rseed), "0"],
    inPath: [p5.sib.map(s), Array(32).fill("0")], inBits: [p5.bits.map(String), Array(32).fill("0")], inDummySeed: ["1", "55"],
    outOwner: o3.map((o) => s(o.owner)), outValue: o3.map((o) => s(o.value)), outRseed: o3.map((o) => s(o.rseed)) };
  // EXIT_2_0H: Bob exits his 30 (position 4) under R2
  const p4 = t2.path(4), nfB = S.nfReal(noteDomain, bob.nk, cms[0], 4), nfE = S.nfDummy(noteDomain, 66n, 1);
  const ew = [noteDomain, 2n, R2, S.r - 30n, 1n, 888n, nfB, nfE];
  const exit = { stmt: s(S.statementOf(ew)), noteDomain: s(noteDomain), numAssets: "2", root: s(R2), publicAmount: s(S.r - 30n), publicAsset: "1", extHash: "888",
    nf: [s(nfB), s(nfE)], sk: s(bob.sk), asset: "1", inEnabled: ["1", "0"], inValue: ["30", "0"], inD: [s(S.toBig(dB)), "0"], inRseed: [s(outs[0].rseed), "0"],
    inPath: [p4.sib.map(s), Array(32).fill("0")], inBits: [p4.bits.map(String), Array(32).fill("0")], inDummySeed: ["1", "66"] };
  const plus1 = (x) => s(BigInt(x) + 1n);
  const cases = [
    ["directh", "DIRECT_H: first-note journey accepted with the reference statement", direct, true],
    ["directh", "DIRECT_H: statement off by one", { ...direct, stmt: plus1(direct.stmt) }, false],
    ["directh", "DIRECT_H: hashed word (newRoot) changed, statement kept", { ...direct, newRoot: plus1(direct.newRoot) }, false],
    ["transfer24h", "TRANSFER_2_4_H: spend change, withdraw 20, accepted", transfer, true],
    ["transfer24h", "TRANSFER_2_4_H: extHash changed, statement kept", { ...transfer, extHash: "778" }, false],
    ["transfer24h", "TRANSFER_2_4_H: publicAsset relabelled", { ...transfer, publicAsset: "0" }, false],
    ["exith", "EXIT_2_0_H: Bob exits 30, accepted", exit, true],
    ["exith", "EXIT_2_0_H: amount changed, statement kept", { ...exit, publicAmount: s(S.r - 31n) }, false],
  ];
  let failures = 0;
  for (const [name, label, inp, accept] of cases) {
    try { await expectWitness({ name, buildDir: B, input: inp, shouldAccept: accept, snarkjsCli: CLI }); console.log(`PASS  ${label}`); }
    catch (e) { failures++; console.log(`FAIL  ${label}: ${String(e.message).split("\n")[0]}`); }
  }
  console.log(failures ? `${failures} FAILED` : `all ${cases.length} cases behaved as expected`);
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
```

```text
PASS  DIRECT_H: first-note journey accepted with the reference statement
PASS  DIRECT_H: statement off by one
PASS  DIRECT_H: hashed word (newRoot) changed, statement kept
PASS  TRANSFER_2_4_H: spend change, withdraw 20, accepted
PASS  TRANSFER_2_4_H: extHash changed, statement kept
PASS  TRANSFER_2_4_H: publicAsset relabelled
PASS  EXIT_2_0_H: Bob exits 30, accepted
PASS  EXIT_2_0_H: amount changed, statement kept
all 8 cases behaved as expected
```

### E.3 `tests/pool_test8.js`

```javascript
"use strict";
// v0.8 pool, both statement profiles, REAL Groth16 pairings through SethGroth16Verifier. Proofs come from development
// stand-in circuits with the production public-input counts, so verification gas equals production. Fail-closed.
const S = require("../ref/seth8"); const { vkArgs } = require("./verifier_test");
const fs = require("fs"), path = require("path"), solc = require("solc"), assert = require("assert"), snarkjs = require("snarkjs");
const { ethers } = require("ethers"); const { VM } = require("@ethereumjs/vm");
const { Common, Chain, Hardfork } = require("@ethereumjs/common"); const { Address, Account } = require("@ethereumjs/util");
const TOY = path.join(__dirname, "../toy"), R = S.r;
const TOKEN = `pragma solidity 0.8.26; contract MockToken { mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance; uint256 public pulls;
 function mint(address a, uint256 x) external { balanceOf[a] += x; } function approve(address s, uint256 x) external returns (bool) { allowance[msg.sender][s] = x; return true; }
 function transfer(address to, uint256 x) external returns (bool) { balanceOf[msg.sender] -= x; balanceOf[to] += x; return true; }
 function transferFrom(address f, address to, uint256 x) external returns (bool) { pulls++; allowance[f][msg.sender] -= x; balanceOf[f] -= x; balanceOf[to] += x; return true; } }`;
async function prove(k, vec) {
  const { proof, publicSignals } = await snarkjs.groth16.fullProve({ s: vec.map((x) => BigInt(x).toString()) }, `${TOY}/toyk${k}_js/toyk${k}.wasm`, `${TOY}/toyk${k}.zkey`);
  const cd = JSON.parse("[" + (await snarkjs.groth16.exportSolidityCallData(proof, publicSignals)) + "]"); return [cd[0], cd[1], cd[2]];
}
const log = []; const say = (x) => { log.push(x); console.log(x); };
(async () => {
  await S.init();
  const src = { "ShieldedETHPool.sol": { content: fs.readFileSync(path.join(__dirname, "../contracts/ShieldedETHPool.sol"), "utf8") },
    "SethGroth16Verifier.sol": { content: fs.readFileSync(path.join(__dirname, "../contracts/SethGroth16Verifier.sol"), "utf8") }, "T.sol": { content: TOKEN } };
  const out = JSON.parse(solc.compile(JSON.stringify({ language: "Solidity", sources: src, settings: { viaIR: true, optimizer: { enabled: true, runs: 10 }, evmVersion: "cancun", outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } } })));
  for (const e of out.errors || []) if (e.severity === "error") throw Error(e.formattedMessage);
  const C = {}; for (const f of Object.values(out.contracts)) for (const [n, v] of Object.entries(f)) C[n] = { bin: "0x" + v.evm.bytecode.object, iface: new ethers.utils.Interface(v.abi) };
  const P = C.ShieldedETHPool.iface, TK = C.MockToken.iface, V = C.SethGroth16Verifier;
  for (const profile of ["native", "hashed"]) {
    const hashed = profile === "hashed";
    const vm = await VM.create({ common: new Common({ chain: Chain.Mainnet, hardfork: Hardfork.Cancun }) });
    const me = Address.fromString("0x1000000000000000000000000000000000000001");
    await vm.stateManager.putAccount(me, Account.fromAccountData({ balance: 10n ** 24n }));
    const call = async (to, iface, fn, args = [], value = 0n) => {
      const data = to ? ethers.utils.arrayify(iface.encodeFunctionData(fn, args)) : ethers.utils.arrayify(fn);
      const r = await vm.evm.runCall({ caller: me, to: to ? Address.fromString(to) : undefined, data, value, gasLimit: 30_000_000n });
      const ex = r.execResult;
      if (ex.exceptionError) { let reason = ex.exceptionError.error; try { reason = iface.parseError(ex.returnValue).name; } catch {} return { ok: false, reason }; }
      if (!to) return { ok: true, address: r.createdAddress.toString() };
      let ret; try { ret = iface.decodeFunctionResult(fn, ex.returnValue); } catch {}
      return { ok: true, ret, logs: ex.logs, gas: Number(ex.executionGasUsed), data };
    };
    const deploy = async (n, a = []) => { const r = await call(null, C[n].iface, C[n].bin + C[n].iface.encodeDeploy(a).slice(2)); assert(r.ok, n + ": " + r.reason); return r.address; };
    const verifier = async (k) => deploy("SethGroth16Verifier", vkArgs(JSON.parse(fs.readFileSync(`${TOY}/vkk${k}.json`))));
    const v1 = await verifier(1), v8 = hashed ? v1 : await verifier(8), v12 = hashed ? v1 : await verifier(12), v18 = hashed ? v1 : await verifier(18);
    const tok = await deploy("MockToken"), E18 = 10n ** 18n, salt = "0x" + "00".repeat(32);
    const mask = hashed ? (1 << 1) | (1 << 2) | (1 << 3) | (1 << 6) : 0;
    const pool = await deploy("ShieldedETHPool", [[salt, 90n * 86400n, 200000,
      [[ethers.constants.AddressZero, 1000n * E18, 10000n * E18, 0, 0], [tok, 10n ** 30n, 10n ** 31n, 100000, 30000]], v12, v18, v8, v1, v1, v18, mask]]);
    const view = async (fn, a = []) => { const r = await call(pool, P, fn, a); assert(r.ok, fn + ": " + r.reason); return r.ret.length === 1 ? r.ret[0] : r.ret; };
    const poolId = S.poolIdOf(1, pool, salt); assert.equal(await view("poolId"), S.hex(poolId));
    const noteDomain = S.noteDomainOf(poolId);
    const alice = S.walletKeys(Uint8Array.from({ length: 32 }, (_, i) => i + 1)), bob = S.walletKeys(Uint8Array.from({ length: 32 }, (_, i) => 100 + i));
    const dA = Uint8Array.from({ length: 11 }, (_, i) => 0xa0 + i), dB = Uint8Array.from({ length: 11 }, () => 0xb0);
    const A = S.address(alice, dA, poolId), Bo = S.address(bob, dB, poolId);
    // ---------- depositMany: 2 ETH + 18 token notes (payroll-style), token pulled once
    const items = [], meta = [];
    const mk = (keys, addr, asset, amount, tip, rs) => { const partial = S.partialOf(addr.owner, rs), cm = S.cmOf(partial, amount, asset);
      const ct = S.seal(poolId, addr, amount, asset, rs, cm).ct; items.push([asset, partial, amount, tip, ct]); meta.push({ keys, addr, asset, amount, tip, partial, cm, ct }); };
    mk(alice, A, 0, E18, 10n ** 13n, 11n); mk(bob, Bo, 0, 2n * E18, 10n ** 13n, 12n);
    for (let i = 0; i < 18; i++) mk(i % 2 ? bob : alice, i % 2 ? Bo : A, 1, 1000n + BigInt(i), 10n ** 12n, 100n + BigInt(i));
    await call(tok, TK, "mint", [me.toString(), 10n ** 9n]); await call(tok, TK, "approve", [pool, 10n ** 9n]);
    const ethNeeded = meta.reduce((a, m) => a + m.tip + (m.asset === 0 ? m.amount : 0n), 0n);
    let r = await call(pool, P, "depositMany", [items], ethNeeded); assert(r.ok, "depositMany: " + r.reason);
    const gDM = r.gas;
    assert.equal((await call(tok, TK, "pulls")).ret[0].toNumber(), 1);
    let acc = S.acc0Of(poolId); const tree = new S.Tree();
    meta.forEach((m, e) => {
      const V = m.tip + (m.asset === 0 ? m.amount : 0n);
      m.ext = S.extHashOf(S.canonicalBody(S.KIND.DEPOSIT, 0, poolId, 1n, V, S.DEPOSIT_BODY, { asset: m.asset, partial: m.partial, amount: m.amount, tip: m.tip, ciphertext: m.ct }));
      m.w = [m.partial, m.amount, BigInt(m.asset), 0n]; m.entry = e;
      acc = S.accStep(acc, S.KIND.DEPOSIT, m.w, m.ext, m.tip); tree.insertEntry(e, S.leavesOf(S.KIND.DEPOSIT, m.w));
    });
    assert.equal((await view("knownAcc", [20])).toBigInt(), acc);
    // single deposit for comparison (entry 20, not used later)
    const sp = S.partialOf(A.owner, 999n), sct = S.seal(poolId, A, 5n, 1, 999n, S.cmOf(sp, 5n, 1)).ct;
    r = await call(pool, P, "deposit", [1, sp, 5n, sct], 10n ** 12n); assert(r.ok); const gSingle = r.gas;
    const spExt = S.extHashOf(S.canonicalBody(S.KIND.DEPOSIT, 0, poolId, 1n, 10n ** 12n, S.DEPOSIT_BODY, { asset: 1, partial: sp, amount: 5n, tip: 10n ** 12n, ciphertext: sct }));
    const spW = [sp, 5n, 1n, 0n]; acc = S.accStep(acc, S.KIND.DEPOSIT, spW, spExt, 10n ** 12n); tree.insertEntry(20, S.leavesOf(1, spW));
    say(`[${profile}] depositMany x20 (2 ETH + 18 token, one token pull): ${gDM} exec gas = ${Math.round(gDM / 20)}/deposit vs single token deposit ${gSingle}; records identical to single-deposit encoding`);
    // ---------- insert entries 0..15 and 16..20 with BATCH_UPTO_16 statements (real 1-input proofs)
    const insert = async (start, k, accStart, accEnd, oldRoot, newRoot, tipSum) => {
      const ben = "0x000000000000000000000000000000000000bEEF";
      const stmt = S.batchStatement({ poolId, chainId: 1n, circuitId: 5n, oldRoot, newRoot, start: BigInt(start), k: BigInt(k), accStart, accEnd, baseTipSum: tipSum, beneficiary: BigInt(ben) });
      const pf = await prove(1, [stmt]);
      const rr = await call(pool, P, "insertBatch", [5, start, oldRoot, accStart, k, newRoot, tipSum, ben, pf]); assert(rr.ok, "insertBatch: " + rr.reason); return rr.gas;
    };
    const accs = [S.acc0Of(poolId)]; meta.forEach((m) => accs.push(S.accStep(accs.at(-1), 1, m.w, m.ext, m.tip))); accs.push(acc);
    const tA = new S.Tree(); for (let e = 0; e < 16; e++) tA.insertEntry(e, S.leavesOf(1, meta[e].w));
    const gIns = await insert(0, 16, accs[0], accs[16], S.zeros()[32], tA.root(), meta.slice(0, 16).reduce((a, m) => a + m.tip, 0n));
    await insert(16, 5, accs[16], accs[21], tA.root(), tree.root(), meta.slice(16).reduce((a, m) => a + m.tip, 0n) + 10n ** 12n);
    say(`[${profile}] insertBatch k=16 with real 1-input verification: ${gIns} exec gas`);
    let rootSeq = 2, root = tree.root(), entry = 21;
    // ---------- spend helper: builds a pure transfer (W = 0) for note m, returns {body, proof}
    const spend = async (m, nonceByte, tip) => {
      const pos = 4 * m.entry;
      const outs = [m.amount, 0n, 0n, 0n].map((v, j) => S.cmOf(S.partialOf(m.addr.owner, 5000n + BigInt(pos * 4 + j)), v, m.asset));
      const nf = [S.nfReal(noteDomain, m.keys.nk, m.cm, pos), S.nfDummy(noteDomain, 77n + BigInt(pos), 1)];
      const body = { rootSeq, root, nullifiers: nf, commitments: outs, W: 0, publicAsset: 0, tip, recipient: ethers.constants.AddressZero, payoutGas: 0,
        executor: ethers.constants.AddressZero, deadline: 2n ** 40n, nonce: "0x" + nonceByte.repeat(32), recipientCiphertexts: "0x" + "11".repeat(436), recoveryCiphertext: "0x" + "22".repeat(400) };
      const ext = S.extHashOf(S.canonicalBody(S.KIND.TRANSFER, 1, poolId, 1n, tip, S.TRANSFER_BODY, body));
      const vec = S.transferPub(noteDomain, 2, body, ext);
      return { body, ext, proof: await prove(hashed ? 1 : 12, hashed ? [S.statementOf(vec)] : vec) };
    };
    // ---------- single-lane transfer
    const s0 = await spend(meta[0], "a0", 10n ** 13n);
    r = await call(pool, P, "transact", [1, s0.proof, s0.body], 10n ** 13n); assert(r.ok, "transact: " + r.reason);
    const gTx = r.gas, cdTx = r.data.length; entry++;
    say(`[${profile}] single transact (TRANSFER_2_4, real ${hashed ? "1" : "12"}-input verification): ${gTx} exec gas, ${cdTx} calldata bytes`);
    // ---------- aggregator lane: 16 fresh token notes (entries 2..17) + 2 stale entries appended
    const good = []; for (let i = 2; i < 18; i++) good.push(await spend(meta[i], (i + 16).toString(16).padStart(2, "0"), 10n ** 12n));
    const dupOfFirst = { ...good[0], body: { ...good[0].body, nonce: "0x" + "fe".repeat(32) } };   // same nullifiers as good[0]
    const spentAlready = s0;                                                                       // nullifier spent by the single transact
    const lane = [...good.slice(0, 14), dupOfFirst, spentAlready];
    const tipsAll = lane.reduce((a, x) => a + BigInt(x.body.tip), 0n);
    const bad = [...lane.slice(0, 3).map((x) => x.proof), good[4].proof, ...lane.slice(4).map((x) => x.proof)];      // proof 3 swapped
    r = await call(pool, P, "transactBatch", [bad, lane.map((x) => x.body)], tipsAll); assert(!r.ok && r.reason === "BadProof", "bad batch must revert");
    r = await call(pool, P, "transactBatch", [lane.map((x) => x.proof), lane.map((x) => x.body)], tipsAll); assert(r.ok, "transactBatch: " + r.reason);
    const ev = r.logs.map((l) => { try { return P.parseLog({ topics: l[1].map((t) => S.hex(t)), data: S.hex(l[2]) }); } catch { return null; } }).filter(Boolean);
    const bt = ev.find((e) => e.name === "BatchTransacted"); assert.equal(bt.args.includedMask.toNumber(), (1 << 14) - 1);
    assert.equal(bt.args.refundedTips.toBigInt(), BigInt(dupOfFirst.body.tip) + BigInt(spentAlready.body.tip));
    const pubs = ev.filter((e) => e.name === "EntryPublished"); assert.equal(pubs.length, 14);
    pubs.forEach((e, i) => assert.equal(e.args.extHash.toBigInt(), good[i].ext));            // lane-agnostic: same extHash as single lane
    for (const g of good.slice(0, 14)) assert.equal(await view("nullifierSpent", [g.body.nullifiers[0]]), true);
    const gB14 = r.gas; say(`[${profile}] transactBatch: 14 included + 2 stale skipped (duplicate nullifier, already spent): ${gB14} exec gas = ${Math.round(gB14 / 14)}/transfer; invalid-proof batch reverted BadProof; extHash per entry equals single-lane extHash`);
    // small batch for scaling
    r = await call(pool, P, "transactBatch", [good.slice(14, 16).map((x) => x.proof), good.slice(14, 16).map((x) => x.body)], 2n * 10n ** 12n); assert(r.ok, "batch2: " + r.reason);
    say(`[${profile}] transactBatch n=2: ${r.gas} exec gas = ${Math.round(r.gas / 2)}/transfer`);
    log.push({ profile, gDM, gSingle, gIns, gTx, gB14, gB2: r.gas });
  }
  fs.writeFileSync(path.join(__dirname, "pool_test8.json"), JSON.stringify(log.filter((x) => typeof x === "object"), null, 1));
  console.log("ALL POOL ASSERTIONS PASSED");
  process.exit(0);
})().catch((e) => { console.error("FAIL:", e.message); process.exit(1); });
```

```text
[native] depositMany x20 (2 ETH + 18 token, one token pull): 937373 exec gas = 46869/deposit vs single token deposit 70327; records identical to single-deposit encoding
[native] insertBatch k=16 with real 1-input verification: 287571 exec gas
[native] single transact (TRANSFER_2_4, real 12-input verification): 409615 exec gas, 1892 calldata bytes
[native] transactBatch: 14 included + 2 stale skipped (duplicate nullifier, already spent): 2931269 exec gas = 209376/transfer; invalid-proof batch reverted BadProof; extHash per entry equals single-lane extHash
[native] transactBatch n=2: 614564 exec gas = 307282/transfer
[hashed] depositMany x20 (2 ETH + 18 token, one token pull): 937373 exec gas = 46869/deposit vs single token deposit 70327; records identical to single-deposit encoding
[hashed] insertBatch k=16 with real 1-input verification: 287571 exec gas
[hashed] single transact (TRANSFER_2_4, real 1-input verification): 324398 exec gas, 1892 calldata bytes
[hashed] transactBatch: 14 included + 2 stale skipped (duplicate nullifier, already spent): 2702472 exec gas = 193034/transfer; invalid-proof batch reverted BadProof; extHash per entry equals single-lane extHash
[hashed] transactBatch n=2: 509260 exec gas = 254630/transfer
ALL POOL ASSERTIONS PASSED
```

### E.4 E2 kernel compatibility

In `XmrSwapKernel.sol` (v0.7 E2 Appendix A), change `uint16 public constant VERSION = 7;` to `8`, and the constructor check `pool_.VERSION() != 7` to `!= 8`. With those changes it compiles to an 8,140-byte runtime. Its behavioural tests must be re-run against v0.8 in testnet round R3.
