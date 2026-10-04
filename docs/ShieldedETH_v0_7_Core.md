# ShieldedETH v0.7: Core Protocol Specification

> Historical v0.7 specification. The [current v0.8 specification](ShieldedETH_v0_8_Core_Delta.md) governs the executable implementation, production requirements and measured evidence. Embedded source candidates and proposed tests are retained for reference.

**Status:** Implementation candidate and normative engineering specification. Not audited, not deployed, no production setup, and not authorization to accept funds.  
**Scope:** A native-ETH and fixed-allowlist ERC-20 shielded payment pool on Ethereum L1. Multi-asset support is a required core capability, not a deferred extension.  
**Companions:** [E1: Transaction Capacity](ShieldedETH_v0_7_E1_Capacity.md) and [E2: XMR Settlement](ShieldedETH_v0_7_E2_XMR_Settlement.md).  
**Supersedes:** The v0.5 core plus the v0.6 delta. This is a standalone specification, not a patch that requires reading both predecessors. Version 7 is not wire-, key-derivation-, address-, proof-, or deployment-compatible with versions 5 or 6.

MUST and MUST NOT are requirements of this proposed release. SHOULD permits a documented deviation. MAY is optional. A requirement or test case in this document is not a claim that an implementation has passed it.


## Contents

- [0. Decisions, provenance, and evidence](#0-decisions-provenance-and-evidence)
- [1. Scope, roles, and guarantees](#1-scope-roles-and-guarantees)
- [2. Assets and token boundary](#2-assets-and-token-boundary)
- [3. Cryptographic profile and encoding](#3-cryptographic-profile-and-encoding)
- [4. Keys, addresses, notes, and nullifiers](#4-keys-addresses-notes-and-nullifiers)
- [5. Delivery encryption and outgoing recovery](#5-delivery-encryption-and-outgoing-recovery)
- [6. Conservation, liability, tips, and credits](#6-conservation-liability-tips-and-credits)
- [7. Queue and authenticated history](#7-queue-and-authenticated-history)
- [8. Proved insertion, rewards, and zero-entry advancement](#8-proved-insertion-rewards-and-zero-entry-advancement)
- [9. Direct mode, including actual first-deposit spending](#9-direct-mode-including-actual-first-deposit-spending)
- [10. Roots, capacity, and complete exits](#10-roots-capacity-and-complete-exits)
- [11. Canonical bodies and public statements](#11-canonical-bodies-and-public-statements)
- [12. Contract interface and execution requirements](#12-contract-interface-and-execution-requirements)
- [13. Submission and asset-aware fees](#13-submission-and-asset-aware-fees)
- [14. Wallet state, verified recovery, and privacy](#14-wallet-state-verified-recovery-and-privacy)
- [15. Gas and economic measurement](#15-gas-and-economic-measurement)
- [16. Test requirements and independent checks](#16-test-requirements-and-independent-checks)
- [17. Release gates](#17-release-gates)
- [18. Launch, incidents, and migration](#18-launch-incidents-and-migration)
- [19. Release manifest and implementation checklist](#19-release-manifest-and-implementation-checklist)
- [20. Sources and interpretation](#20-sources-and-interpretation)
- [Appendix A: Pool implementation candidate](#appendix-a-pool-implementation-candidate)
- [Appendix B: Circuit implementation candidates](#appendix-b-circuit-implementation-candidates)
- [Appendix C: Reference encoding and tree utilities](#appendix-c-reference-encoding-and-tree-utilities)
- [Appendix D: Fail-closed tests and build procedure](#appendix-d-fail-closed-tests-and-build-procedure)


## 0. Decisions, provenance, and evidence

### 0.1 Protocol scope

The system supports multiple approved assets in one commitment tree. Each payment consumes and creates notes of exactly one asset, without publishing an explicit asset identifier for a pure private transfer. It supports independent self-submission and an optional broadcaster paid in that same asset through an ordinary shielded output. ETH gas and public insertion tips remain separate from private note accounting.

There is no exchange operation, price oracle, protocol token, deployer percentage fee, lending of collateral, administrative spending key, or mandatory service registry. E2 can deliver native ETH to asset 0; it does not make the core an XMR custodian or automatically exchange XMR for every listed token.

### 0.2 Source-derived baseline versus v0.7 changes

Section 20 identifies the predecessor specifications. The following table distinguishes inherited rules from the v0.7 requirements; predecessor test results do not establish conformance to this revision.

| Area | Retained baseline | Explicit v0.7 revision |
|---|---|---|
| Multi-asset ledger | v0.6 asset-bearing commitments and per-asset liabilities | Required from the first complete release; `numAssets` is explicitly constrained by every spending circuit |
| Deposits | Proofless, no on-chain Poseidon; amount and asset enter the authenticated queue | Exact incoming sender and pool balance changes for approved tokens; cheap capacity/cap checks first |
| Direct mode | Authenticate an idle-compatible pending prefix and insert the sender's output subtree | Spend membership is checked under the intermediate root **after** absorbing the pending deposit; this permits the actual first-note transaction sequence |
| Insertion rewards | Batch beneficiary is proof-bound | Direct-mode reward beneficiary is bound through the canonical direct body; never implicitly paid to whichever account copies the proof |
| Asset risk | Fixed deployment allowlist | No unconditional “hard money,” “unfreezable forever,” or complete failure-isolation claims; exact deployment risk records required |
| Token withdrawals | Optional-return token call | Bounded calls and exact observed pool debit **and recipient credit**; rollback on mismatch |
| Queue liveness | Pinned inserted accumulator; checkpoints every 16; batches of 1–16 | Retained; batch tip sums have an explicit 132-bit bound; strict canonical field-to-bit encoding |
| Root history | Current root plus 1,023 historical roots | Root sequence advances only when the note-tree root changes, not for zero-only advancement |
| Launch cap | Time-based growth to an unlimited value | Time-based growth saturates at a **permanent per-asset ceiling**; no automatic uncapping |
| Wallet | Diversified addresses and compact encryption | Total rejection boundary for hostile ciphertext; unsigned/high-index-safe tree arithmetic; gift sweeps use independent recovery keys |
| Tests and benchmarks | Partial predecessor evidence | Reset v0.7 evidence; fail-closed tests; no inherited proof counts, runtime sizes, or gas receipts presented as v0.7 measurements |

### 0.3 Evidence classification

**Specified:** the rules, ABI, circuit relations, source candidates, regression cases, and release gates below.

**Predecessor evidence only:** v0.5 reports a reduced-depth real-proof test; v0.6 reports circuit witness checks and contract tests with mock verifiers. Their reported results neither prove the new intermediate-root relation nor constitute v0.7 benchmarks. Their logging-only negative-test helpers must not be reused as release gates. [S-C5 §0 and Appendix E; S-C6 §1 and Appendix D]

**Not established for v0.7:** successful Solidity/Circom compilation, production-depth real-verifier integration, full batch proving, constant-time wallet implementation, independent vectors, mobile performance, code-size compliance, audited security, or production ceremony. Appendix code is an implementation candidate, not a compiled release. A small specification/helper-check report, if distributed alongside this document, covers only the checks explicitly named in that report.

## 1. Scope, roles, and guarantees

**CORE-01.** Support deposits of native ETH and approved ERC-20 units; arbitrary supported integer-unit payments; private change; per-asset consolidation; public withdrawals; and complete-note exits. A recipient needs a valid receiving address, not a funded public account or registration.

**CORE-02.** The production v0.7 profile contains 2–8 assets, including asset 0 native ETH and at least one separately reviewed ERC-20. Test fixtures use the same bounds. The allowlist is immutable for a deployment.

**CORE-03.** A successful queued spend records nullifiers and funded outputs immediately. Those outputs become conventionally spendable after insertion. A successful direct spend inserts its outputs in the same pool call, subject to chain finality. Mere decryption, mempool appearance, or a transaction hash is not finalized payment.

**CORE-04.** Proof verification, current nullifier checks, state updates, and any public payout are atomic within the pool call. An exception reverts that call's effects. Off-chain disclosure and network fees are not undone by a revert.

| Component | Responsibilities | Trust and failure boundary |
|---|---|---|
| Pool | Backing, validity checks, liabilities, nullifiers, queue, insertion roots, credits, settlement | Circuit/contract/setup errors can compromise funds; immutable code has no repair key |
| Wallet/prover | Keys, address verification, amount parsing, proof generation, recovery, user approval | A malicious wallet can misdirect or disclose funds; private witnesses never go to broadcasters |
| Broadcaster | Asset-aware quote, fee-note validation, funded submission | Learns fee asset and amount, its output, and session metadata; may decline or delay |
| Batcher | Build insertion proofs from public records and submit | Needs public ETH; may lose races; has no note-spend authority |
| Archive/indexer | Serve canonical bodies, snapshots, paths | Can withhold or give stale data; wallet authenticates against a chain view |
| E1/E2 services | Optional onboarding or external settlement | Do not change core conservation or acquire a pool privilege |

Excluded from v0.7: cross-asset transfers within one proof, private swaps/DeFi, multi-owner inputs, arbitrary application callbacks, proof-of-work minting, guaranteed ciphertext delivery, guaranteed anonymity-set size, and pool-as-ERC-4337-account behavior.

“No protocol fee” means no percentage deduction or deployer share. Gas, ETH insertion tips, fixed broadcaster fees, conversion spreads, and archive costs remain real.

## 2. Assets and token boundary

### 2.1 Immutable asset configuration

```solidity
struct Asset {
    address token;          // address(0) only at index 0
    uint128 rampC0;         // initial liability limit, base units
    uint128 capCeiling;     // permanent liability ceiling, base units
    uint32 callGasCap;      // token transfer / transferFrom allowance; 0 for ETH
    uint32 balanceGasCap;   // token balanceOf allowance; 0 for ETH
}
```

IDs are contiguous `0 .. numAssets-1`. Token addresses must be nonzero, unique, and have code. `0 < rampC0 <= capCeiling`. The candidate contract permits token call caps in `[25,000, 1,000,000]` and balance-call caps in `[5,000, 200,000]`; deployment values must be benchmarked for the exact assets. Native ETH has zero token-call caps. A limit that later becomes inadequate cannot be raised in place.

The release manifest additionally fixes full token addresses, chain, display decimals, source/implementation code hashes, proxy and underlying dependencies, approved transfer behavior, exact approval/permit dialect, and the review date/block. Symbols and decimals are display metadata, not asset identity and not inputs to conservation. An address-only comparison is insufficient for an upgradeable dependency.

The v0.6 candidates (DAI, sDAI, LUSD, BOLD, wstETH, and rETH) remain **candidates for investigation**, not an approved production list. This document does not verify their current deployments or assign safety tiers. Freeze actual assets only after asset-specific review. [S-C6 §2]

### 2.2 Required asset risk record

| Dimension | Questions that must be answered for the exact deployment |
|---|---|
| Transfer control | Pause, blacklist, seizure, transfer restrictions, privileged bypasses? |
| Upgradeability | Proxy, implementation replacement, mutable dependencies, governance authority? |
| Economic value | Issuance, redemption, collateral, oracle, exchange-rate, or underlying protocol dependence? |
| Unit semantics | Fixed balance units, shares, positive/negative rebase, fees, rounding, exchange-rate drift? |
| Call behavior | Exact debit/credit, return-data convention, gas bounds, callbacks, unusual `balanceOf` behavior? |
| Failure handling | What fails if transfers stop? What remains operable? Is recovery possible without changing this pool? |

Non-rebasing share tokens may be held as **share-unit notes**. A changing share redemption rate does not change the quantity of shares owed by the pool and is not a promise of positive yield. The pool does not auto-redeem wrappers or convert note units into underlying units.

The launch policy excludes rebasing balances, transfer-tax tokens, and callback-dependent transfer semantics. Runtime checks detect some violations, not a permanent guarantee about future external code. “No blacklist in this token contract” must never be equated with absence of every governance or economic dependency.

### 2.3 Exact token movements

For a token deposit of `D` by caller `s`, read `poolBefore` and `senderBefore`, execute bounded `transferFrom(s, pool, D)`, then require:

```text
poolAfter   = poolBefore + D
senderAfter = senderBefore - D
```

For a withdrawal of `W` to `r`, require:

```text
poolAfter      = poolBefore - W
recipientAfter = recipientBefore + W
```

All comparisons are checked unsigned arithmetic. Underflow, extra debit, short delivery, false/no-op success, or unexpected balance behavior reverts the entire operation. A token call accepts only empty return data or exactly 32 bytes encoding `true`. `false`, malformed, and oversized returns reject. A balance call returns exactly one 32-byte integer. Copy no more than 32 return bytes to avoid unbounded return-data allocation.

These are extra protocol requirements beyond the generic ERC-20 interface; ERC-20 callers must handle false returns. [R-ERC20] Observed balances can still be dishonest when the token itself is malicious. Exact-delta checks are not a proof that external contracts cannot lie.

### 2.4 Failure containment without overstating isolation

`liability[a]` is backed by asset `a`, not another token. Token boundary calls check that token only, plus ETH backing. Pure private transfers and insertion must not query every token. A reverting token must not mechanically block unrelated-token exits through a global balance loop.

Nevertheless, all assets share core code, proof assumptions, queue capacity, and insertion infrastructure. Shared defects and queue congestion can affect everyone. A frozen or insolvent token may still have transferable internal notes; the core cannot privately inspect its solvency during every hidden-asset transfer. Wallets must display verified external risk warnings rather than imply those notes are guaranteed redeemable.

## 3. Cryptographic profile and encoding

### 3.1 Proof field and points

Use Groth16 over BN254 for the six circuit IDs in §11. The canonical scalar field is:

```text
r = 21888242871839275222246405745257275088548364400416034343698204186575808495617
q = 21888242871839275222246405745257275088696311157297823662689037894645226208583
```

Field values are strictly less than `r`; proof coordinates are strictly less than `q`. Reject noncanonical inputs rather than reducing them. Pin generated, unmodified verifier code from the final circuit and setup. Pairing and point checks must use the expected EVM precompile behavior. [R-BN254]

The security review must assess BN254's contemporary security margin independently of the delivery cipher. This document does not label the entire protocol “128-bit secure” merely because one component has that target.

### 3.2 Tagged Poseidon

`P(tag, x0..x(n-1))` is output 0 of `circomlib PoseidonEx(n, 1)` with `initialState=tag`. Freeze library commits, round constants, field interpretation, and cross-language vectors. Poseidon runs in circuits/wallets, not Solidity.

| Tag | Value | Arity | Inputs |
|---|---:|---:|---|
| `T_AK` | 1 | 1 | `sk` |
| `T_NK` | 2 | 1 | `sk` |
| `T_OWNER` | 3 | 2 | `ak, d` |
| `T_PART` | 4 | 2 | `owner, rseed` |
| `T_CM` | 5 | 3 | `partial, value, asset` |
| `T_NF` | 6 | 4 | `noteDomain, nk, cm, pos` |
| `T_DUMMY` | 7 | 3 | `noteDomain, dummySeed, slot` |
| `T_NODE` | 8 | 2 | `left, right` |

This carries forward the v0.6 three-input commitment, not the v0.5 two-input commitment. [S-C6 §3]

### 3.3 Hash truncation and full-width contexts

```text
H253(digest32) = uint256_be(digest32) & (2^253 - 1)
```

H253 intentionally discards the top three bits. Account for the 253-bit digest in the security analysis. It is not a way to accept arbitrary noncanonical field encodings.

When hashing field values as bytes inside a circuit, use an alias-safe decomposition constrained to the canonical integer `< r`; a plain 254-bit decomposition alone is insufficient as a general canonicality rule. Widths at most 253 cannot wrap this field. For an arbitrary 256-bit context such as `poolId` or chain ID, use 256 Boolean bits, or two 128-bit limbs, and hash the exact 32 bytes. Do not first coerce it into one field value. The candidate batch circuit uses Boolean bit arrays for both identifiers.

### 3.4 Immutable pool identity

```text
poolId = keccak256(abi.encode(
    keccak256("ShieldedETH"), uint16(7), uint256(deploymentChainId),
    address(pool), bytes32(instanceSalt)))
noteDomain = H253(poolId)          # nonzero, immutable
poolTag = poolId[0:8]              # compact-address discovery hint only
```

A live `block.chainid` is separately included in transaction bodies and batch statements. A subsequent chain-ID change must never change an existing note's nullifier. A same-ID fork with copied state cannot be separated by these bytes alone; wallets need an authenticated chain-selection policy.

The short pool tag and address checksum are not authorization to select an untrusted deployment. A wallet must resolve and verify the **full poolId** and manifest out of band. A short-tag collision must not cause automatic chain or contract selection.

### 3.5 Byte conventions

Fixed integers use big-endian unsigned widths. `d` is 11 bytes/88 bits. Ristretto point encodings use RFC 9496 canonical encodings; wide scalar derivation interprets hash bytes little-endian modulo the group order. Recovery scalar fields use explicit 32-byte big-endian scalar integers in this application format. [R-RISTRETTO]

Strict Base64URL means alphabet `A-Z a-z 0-9 - _`, no padding, no whitespace, and decode/re-encode equality. Reject unsupported versions, malformed lengths, signed values, excess digits, and noncanonical fields. JSON on-chain amounts, IDs wider than safely representable numbers, and field elements are strings, never JavaScript floating-point numbers.

## 4. Keys, addresses, notes, and nullifiers

### 4.1 Wallet capabilities

```text
prk = HKDF-Extract(salt=SHA256("ShieldedETH/v0.7/wallet"), ikm=seed32)
sk  = first c >= 0 for which 1 <= int_be(HKDF-Expand(prk, "sk/" || u32be(c), 32)) < r
ivk = first c >= 0 for which int_le(HKDF-Expand(prk, "ivk/" || u32be(c), 64)) mod ell != 0
ovk = HKDF-Expand(prk, "ovk", 32)
ak = P(T_AK, sk)
nk = P(T_NK, sk)
ell = 2^252 + 27742317777372353535851937790883648493
```

A uniformly random 32-byte seed is required. Stop safely if the 32-bit retry counter is exhausted. Do not replace rejection sampling for `sk` with modulo reduction. HKDF argument order must follow RFC 5869, not an assumed library convention. [R-HKDF]

| Capability | Material | Meaning |
|---|---|---|
| Spend scalar | `sk` | Authorizes owned openings, but alone cannot scan independent encryption branches |
| Incoming view | `ak, ivk` | Detects/validates received notes; does not compute their nullifiers without `nk` |
| Outgoing recovery | `ovk` | Reads batches intentionally encrypted under it; no spending authority |
| Full view | `ak, nk, ivk, ovk` | Receipts, outgoing records, and spent status from available history; no spending authority |
| Wallet secret | `seed`, or complete equivalent secret bundle | Spend and recover |

Viewing-key exposure is broad over matching accessible history, not automatically limited to a date range. A disclosed key is not a completeness proof of all of a person's holdings.

### 4.2 Diversified receiving address

```text
H_d = ristretto255.FromUniformBytes(SHA512("SETH/v7/div" || d))
pk_d = [ivk] H_d
owner_d = P(T_OWNER, ak, int_be(d))
payload = u8(7) || poolTag[8] || d[11] || u256be(owner_d) || encode(pk_d)
check = SHA256("SETH/v7/address" || payload)[0:8]
address = "seth7:" || Base64URL_NoPad(payload || check)
```

The payload is 84 bytes and the checked payload 92 bytes; the full address has 129 ASCII characters. Reject identity bases/keys and resample a freshly chosen diversifier. RFC 9496 supplies the element derivation operation; the SHA-512 domain-separated composition is this protocol's choice, not a claim that raw FromUniformBytes is itself preimage resistant. [R-RISTRETTO]

There is no explicit shared wallet identifier across distinct diversified addresses apart from the selected pool tag. Address privacy remains conditional on the reviewed hash/group constructions and does not cover reuse, shared counterparties, or network metadata.

### 4.3 Notes and units

```text
opening = (value, asset, d, rseed)
0 <= value < 2^128                # base units of the asset, not always wei
0 <= asset < numAssets
1 <= rseed < r
partial = P(T_PART, owner_d, rseed)
cm = P(T_CM, partial, value, asset)
```

Honest wallets require nonzero partial and commitment and resample randomness if needed. Enabled inputs additionally have positive value. Padding outputs are genuine zero-value commitments and are not counted as balance.

Proofless deposits publish a hiding partial and a public asset/amount; insertion derives `cm`. The contract cannot detect malformed delivery or a partial with no usable opening. A rare zero final commitment can be inserted as an empty leaf and is unspendable, not permission to change its position or value.

### 4.4 Spend markers

```text
pos = 4 * entry + slot             # 0 <= pos < 2^32, slot in 0..3
nf_real  = P(T_NF, noteDomain, nk, cm, pos)
nf_dummy = P(T_DUMMY, noteDomain, dummySeed, inputSlot)
```

The circuit derives `nk` from the same spend scalar used for ownership, reconstructs `cm`, and derives `pos` from the exact membership path bits. It cannot independently choose a position or nullifier secret. A new root, executor, quote, deadline, or chain-ID context does not change a real nullifier. Equal funded commitments at distinct positions are different note occurrences. No global duplicate-commitment registry is required.

Real and dummy nullifiers are nonzero, canonical, unique within the call, and checked against the current global registry. Their intended indistinguishability is a cryptographic assumption to review, not a consequence of using identical Solidity types.

## 5. Delivery encryption and outgoing recovery

### 5.1 Recipient channel: 109 bytes per output

```text
esk = first c with int_le(SHA512("SETH/v7/esk" || poolId || u256be(rseed) || u32be(c))) mod ell != 0
epk = [esk] H_d
ss = [esk] pk_d                    # receiver computes [ivk] epk
ctx = u8(7) || poolId || u256be(cm) || encode(epk)
m = HKDF-Expand(HKDF-Extract(SHA256("SETH/v7/note"), encode(ss)), ctx, 44)
pt = u8(7) || u128be(value) || u8(asset) || d[11] || u256be(rseed)    # 61 bytes
ct = encode(epk) || ChaCha20Poly1305.Seal(m[0:32], m[32:44], pt, aad=ctx)
```

The cipher has a 16-byte tag; `32 + 61 + 16 = 109` bytes. Never use `extHash` to derive this ciphertext's key: the body hash includes the ciphertext and would create a dependency cycle.

Before accepting a received output, check exact length, point decoding and identity, AEAD authentication, plaintext version/length, registered asset, canonical value and randomness, recomputed ephemeral key, and equality of the reconstructed commitment with the public commitment.

**WALLET-01.** Every attacker-controlled parsing and cryptographic operation is inside a bounded per-output rejection path. Malformed points, truncated bytes, and decrypt failures must not abort scanning of later outputs. Invalid local keys or an uninitialized cryptographic library are configuration failures, not silently ignored ciphertexts.

The conservation proof binds commitments, not encryption correctness. A sender can burn value through bad delivery; recipients must not accept proof verification alone as evidence they received a spendable note.

### 5.2 Outgoing recovery: 400 bytes

For each of four output slots, the recovery record is:

```text
u256be(owner_d) || encode(pk_d) || u256be(esk)     # 96 bytes
```

Four records are 384 bytes. Compute:

```text
outCtx = SHA256("SETH/v7/out-context" || poolId || u256be(cm_0)..u256be(cm_3) || ct_0..ct_3)
m = HKDF-Expand(HKDF-Extract(SHA256("SETH/v7/out"), recoveryKey), outCtx, 44)
ctOut = ChaCha20Poly1305.Seal(m[0:32], m[32:44], records, aad=outCtx)
```

`recoveryKey` normally equals the sender wallet's `ovk`. It is a wallet-chosen recovery capability, not a circuit-checked relationship to `sk`. This distinction is necessary for an E1 gift sweep: use the recipient's independent main-wallet recovery key, not the shared gift wallet's `ovk`.

A recovery client validates scalar/point encodings, derives each note key, decrypts, recomputes `esk`, verifies `epk`, and reconstructs `cm` including the recovered asset. An outgoing record is history, not ownership of another recipient's note.

### 5.3 Construction and padding rules

Order: output openings and commitments → recipient ciphertexts → recovery batch → complete canonical body → `extHash` → proof. Direct mode computes its tree transition from the already fixed commitments before hashing its body. Fresh output randomness is required for new constructions; retrying an already authorized identical transaction reuses its exact bytes, not partially changed plaintext under reused encryption material.

Transfers always have four shuffled output roles: payment, change, broadcaster fee, and padding where necessary. All four ciphertexts have the same size; the total transfer delivery is `436 + 400 = 836` bytes. A deposit has one ciphertext and no outgoing batch. An exit has none. Gift-sweep padding belongs to the recipient's independent wallet, not the shared gift address.

## 6. Conservation, liability, tips, and credits

### 6.1 One private asset per proof

For asset `a`, every real input and every output uses the same private asset signal:

```text
sum(v_in) = sum(v_out) + W
publicAmount = 0 if W == 0 else r - W
publicAmount * (asset - publicAsset) == 0
```

The spending circuit constrains `2 <= numAssets <= 8` and `0 <= asset < numAssets`; the contract supplies its immutable count. For `W=0`, the contract forces `publicAsset=0`, recipient zero, and payout gas zero. Zero means no explicit public asset disclosure, not an assertion that this is an ETH transfer. For `W>0`, the public asset must be registered and equal to the note asset. Exits require `W>0`.

With at most eight 128-bit inputs, four 128-bit outputs, and a 128-bit withdrawal, the relevant integer sums remain below `2^132`, far below `r`. Range checks and the contract's exact mapping of `W` make the field equation an integer conservation relation.

### 6.2 ETH funding is separate

| Operation | `msg.value` | Note principal |
|---|---|---|
| ETH deposit | `D + tip` | Increases `liability[0]` by `D` |
| Token deposit | `tip` | Pulls exactly `D` token units; increases `liability[a]` |
| Queued transfer / exit | Exactly `tip` | No deposit through this path; only `W` reduces the public asset's liability |
| Direct transfer | Zero; `tip=0` | Private payment plus any `W`; absorbed deposits were already funded |
| Tip top-up | Top-up amount | No note creation |

Every transaction value must fit the canonical `uint128 V` body field. A fee note `F_a` is one of the four outputs in asset `a`; never deduct it a second time. ETH gas/tips are fronted by the user or provider. Paying a tip out of private ETH-note value is intentionally excluded from this multi-asset release.

### 6.3 State accounting

`liability[a]`, total outstanding ETH tips `T`, total earned ETH credits `C`, and account credits use checked `uint256` accounting. Base tips and per-entry top-ups are bounded `uint128`. A batch's base-tip sum is `<2^132`; accumulated credits need not fit in one note amount.

```text
ETH balance >= liability[0] + T + C
approved token a balance >= liability[a]       # check when that token crosses the boundary
T = sum(uninserted base tips + uninserted top-ups)
C = sum(unclaimed insertion credits)
```

| Transition | Liability | T | C | Actual movement |
|---|---|---|---|---|
| Deposit asset a | `+D` for a | `+tip` | Unchanged | Receives D in a and tip in ETH |
| Private transfer | Unchanged | `+tip` | Unchanged | Receives ETH tip only |
| Withdrawal / exit | `-W` for a | `+tip` if queued | Unchanged | Sends W in a; receives ETH tip |
| Insert authenticated entries | Unchanged | `-reward` | `+reward` | No external call |
| Top-up | Unchanged | `+x` | Unchanged | Receives x ETH |
| Claim insertion credit | Unchanged | Unchanged | `-x` | Sends x ETH |

A direct operation spends an absorbed deposit by ordinary input/output conservation; it does **not** increase liability again when inserting it. Previously spent leaves remain in the append-only tree, including a just-absorbed deposit spent in the same direct call. Current nullifiers prevent later reuse.

Forced/unrequested ETH or token transfers are surplus, never newly issued notes. There is no administrative or public sweep of backing or surplus.

## 7. Queue and authenticated history

### 7.1 Entry layout and positions

Each accepted deposit, transfer, and nonterminal exit reserves one entry of four leaf positions. `MAX_ENTRIES = 2^30`, depth is 32, and entry `e` owns positions `4e .. 4e+3`. Positions are assigned at acceptance on the active chain, not at later batching.

| Kind | Four record words | Four leaves |
|---|---|---|
| 1 DEPOSIT | `partial, D, asset, 0` | `P(T_CM, partial, D, asset), 0, 0, 0` |
| 2 TRANSFER | `cm0, cm1, cm2, cm3` | Same four commitments |
| 3 EXIT | `0,0,0,0` | Zero subtree |

Deposits need no proof and no on-chain Poseidon. The batch/direct circuit derives their leaf from the authenticated public record. Invalid ciphertext can make a note unrecoverable, but cannot increase the amount represented by that deposit.

### 7.2 Accumulator encoding

```text
acc_0 = H253(SHA256("SETH/v7/acc" || poolId))
record_e = u256be(acc_e) || u8(kind) || u256be(w0) || u256be(w1)
           || u256be(w2) || u256be(w3) || u256be(extHash) || u128be(baseTip)
acc_(e+1) = H253(SHA256(record_e))
```

Each record is exactly 209 bytes. Top-ups are separate state; adding a top-up never changes this history. Hashing uses full canonical bytes, including asset labels and tip widths.

### 7.3 Stored state

`nextEntry` and `insertedEntries` are counts and satisfy `0 <= insertedEntries <= nextEntry <= 2^30`. They use `uint40` so the terminal count is representable. `rootSeq` and `terminalExitCount` are checked `uint64`. `pendingTopUps` counts entries with a positive top-up and fits `uint40`.

The state includes:

- immutable pool identity, asset table, verifiers, caps, and initial hashes;
- `insertedAcc` pinned at `insertedEntries`;
- `accRing[1024]` for recent counts and permanent checkpoints at multiples of 16;
- `rootRing[1024]`, per-asset liabilities, `T`, `C`, and `terminalExitAcc`;
- nullifier, credit, and per-entry top-up mappings.

`knownAcc(n)` accepts only genesis, the pinned insertion count, a checkpoint not beyond the queue, or a count in the last 1,024 entries. Arithmetic retention checks distinguish overwritten slots; zero is not used as an existence sentinel. Every checkpoint is written when reached.

### 7.4 Always-representable next batch

For `s = insertedEntries < n = nextEntry`:

```text
end = min(n, 16 * (floor(s/16) + 1))
k = end - s                       # always 1..16
```

The start is pinned; the end is the queue head or a permanent checkpoint. This gives a finite draining sequence for every finite valid backlog, assuming available history, a correct prover, gas funding, and inclusion. It is not a promise that a provider will do unprofitable work.

Required regression: `s=1, n=1041` advances by 15 to checkpoint 16. A fixed-size-16-only implementation is nonconforming.

### 7.5 Head-of-line delay

All assets share a sequential insertion prefix. Low-tip entries can delay later ones; direct mode is intentionally limited and cannot skip an arbitrary busy prefix. The UI must show pending position, estimated prefix cost, existing tips, and fallback choices. Funded, low-value deposits still consume queue space. No claim of economic DoS immunity is made.

## 8. Proved insertion, rewards, and zero-entry advancement

### 8.1 Tree relation

`Z[0]=0`, `Z[h+1]=P(T_NODE,Z[h],Z[h])`. A four-leaf entry is an aligned depth-2 subtree. Prove insertion using a depth-30 path at entry index `e`: the old subtree must equal `Z[2]`, and the same path updates it to the new four-leaf subtree. Every index bit is Boolean. No overwriting or reordering is allowed.

The candidate constant is the unchanged source-defined `Z[32]`:

```text
0x1bef23e9a4249514364aad066477b69165bfca8323517caac310800b7838ff3a
```

Independently regenerate this and all intermediate zero hashes from the pinned Poseidon profile before setup. A copied constant is not independent evidence.

### 8.2 Single-input batch statement

```text
statement = H253(SHA256(abi.encode(
    bytes32 poolId, uint256 chainId, uint256 circuitId,
    uint256 oldRoot, uint256 newRoot, uint256 start, uint256 k,
    uint256 accStart, uint256 accEnd, uint256 baseTipSum,
    uint256(uint160(beneficiary)))))
```

The encoding is 352 bytes. Full chain-ID bits are hashed; a 64-bit-only chain encoding is not this profile. The contract reconstructs the statement from verified state and arguments. A proof cannot be moved to a different beneficiary without satisfying a different statement. Another party may generate its own proof for the same public job and compete.

### 8.3 Batch circuit

`BATCH_1` has `maxK=1`; `BATCH_UPTO_16` has `maxK=16`. Require `1<=k<=maxK`, active slots exactly `i<k`, valid kind, canonical widths, consecutive indices, exact accumulator chaining, exact empty-subtree replacements, final root equality, and exact base-tip sum.

Inactive slots use kind EXIT, zero words, zero extHash/tip, and zero siblings. Their accumulator/root contribution is masked off. The active index is `start+i`; inactive index handling must not overflow at the last entry. Encode 254-bit field values with a strict `<r` bit gadget.

### 8.4 Contract insertion order

`insertBatch` checks explicit expected start, old root, and starting accumulator before verifying. It resolves a retained end accumulator, checks counts/canonical inputs, verifies the one-input proof, and only then collects top-ups, advances the prefix, pins any changed root, and credits the proof-bound beneficiary.

No external call occurs during insertion. All collected top-ups are deleted, `pendingTopUps` is updated, and the total reward must not exceed `T`. An unexpected failure rolls back all effects.

### 8.5 Top-ups and credits

`addInsertionTip(entry)` accepts a positive ETH subsidy for a currently pending entry. The per-entry total must fit `uint128`; the amount is nonrefundable after success and goes to whoever validly inserts it. If insertion wins the race, the top-up call reverts.

`claimInsertionFees(to,amount)` debits the caller's earned credit and pays last. Reject zero/pool recipient and amounts beyond the caller's credit. Failure preserves the credit. Credits are ETH, not shielded notes, and have no expiry.

### 8.6 Idle exits and skip

An exit with zero tip on an empty queue can reserve and immediately mark its zero entry inserted; the root and root sequence do not change.

`skipZeroEntries(expectedStart,expectedAccStart,beneficiary,records)` accepts 1–16 consecutive authenticated EXIT records. Verify zero words, canonical fields, the retained end accumulator, and expected prefix. Credit their tips/top-ups to the supplied nonzero beneficiary and advance without a proof. There is no exclusive proof-work right in this operation: another submitter can construct a competing skip with a different beneficiary. Operators must price that public-data race explicitly. Ordinary batch and direct proof rewards have stronger binding as described above.

## 9. Direct mode, including actual first-deposit spending

### 9.1 Supported pending prefix

A direct call requires the current root and an exact pending prefix of at most four entries. That prefix contains zero or more EXIT entries and at most one DEPOSIT; no TRANSFER entry and no second deposit. `tip=0` and `msg.value=0` for the new direct entry.

The contract re-hashes every supplied pending record from `insertedAcc` to the authenticated queue head. It derives the deposit's `(absorbIndex,partial,D,asset)` or canonical all-zero absence tuple. The submitting user need not own the deposit merely to insert it, but must prove ownership to spend it.

### 9.2 Bound direct context

```solidity
struct DirectContext {
    uint40 expectedInserted;
    uint40 expectedNext;
    uint256 expectedInsertedAcc;
    uint256 expectedQueueAcc;
    uint256 newRoot;
    address rewardBeneficiary;
    bytes32 pendingHash;       // keccak256(abi.encode(PendingRecord[]))
}
```

The complete DirectContext is in the canonical body hashed into the proof's `extHash`. Its beneficiary cannot be replaced with `msg.sender` at execution. Require a nonzero non-pool beneficiary even when the presently observed reward is zero, because top-ups may arrive before execution. Existing and newly arriving top-ups follow the same authorized beneficiary.

### 9.3 Corrected circuit order

Let `R0` be the public old root and `eOwn=expectedNext`.

```text
1. If a deposit is present:
     prove its entry slot is empty under R0;
     R1 = insert authenticated deposit subtree at absorbIndex.
   Otherwise:
     R1 = R0, with all absent-absorb fields zero.

2. Prove all enabled input memberships under R1, not R0.
   Apply the ordinary single-asset ownership, nullifier and conservation relations.

3. Prove eOwn's slot is empty under R1;
   R2 = insert the four output commitments at eOwn;
   require R2 == public newRoot.
```

The intermediate root is computed by the circuit and is **not** an arbitrary caller-selected anchor. It need not be separately registered. Existing inputs are proved under their updated paths in `R1`; the new deposit can be an input at position `4*absorbIndex`. The deposit's asset may differ from the transaction's asset only when that deposit is merely inserted and is not a real input. All real inputs remain single-asset.

For a present deposit require nonzero partial/value, registered asset, bounded index, and `absorbIndex<eOwn`. Absence is explicitly canonical. Do not use index zero as an absence sentinel: entry zero is a valid first deposit.

### 9.4 Required first-note example

Starting from the empty root:

1. Alice deposits 100 token units to her own address; entry 0 is pending and liability is 100.
2. A direct proof inserts entry 0, then spends that note under `R1`.
3. Outputs include Bob 30, Alice change 69, provider fee 1, and zero padding, all in that token.
4. The call marks the input nullifier, inserts entry 1, and finishes with unchanged token liability 100.
5. The spent deposit leaf remains in the tree but cannot be spent again.

This is a **v0.7 required test**, not an inherited v0.6 result. A witness that only spends an older ETH note while inserting an unrelated token deposit does not test this property.

### 9.5 Order of effects

Cheap exact-state checks → authenticated pending re-hash (read-only) → body/nullifier/proof checks → direct verification → record nullifiers and any withdrawal liability debit → collect pending top-ups → enqueue own output entry → mark the whole prefix inserted and credit the bound beneficiary → public payout last → scoped backing checks.

Absorption does not pull tokens or increase liability again. A failed payout reverts the insertion, new outputs, nullifiers, credits, and liability debit together.

### 9.6 Races, recovery, privacy

Queue/head/root changes invalidate the precomputed direct transition. Explicit expected state must fail before expensive verification. A top-up alone does not change the authenticated queue or root; it raises the bound beneficiary's eventual reward.

After staleness, the wallet re-synchronizes. If it relied on spending the absorbed deposit, it cannot blindly switch to a queued proof: the deposit must first be in a recognized root or a newly valid direct transition. Rebuild accordingly.

Direct absorption can publicly narrow candidate input history. A first and uniquely funded deposit immediately spent has little ambiguity even though its output amounts are confidential. The UI must expose the latency/privacy tradeoff. “No separate batch transaction in this supported state” is the claim, not “no infrastructure, no races, or guaranteed unlinkability.”

## 10. Roots, capacity, and complete exits

A queued spend names `(rootSeq,root)` from the current or preceding 1,023 root checkpoints. The current root remains recognized indefinitely during inactivity. Zero-entry skip and idle-exit advancement do not evict roots. If an old anchor is evicted by real updates, rebuild its proof; its notes do not expire.

At `nextEntry=2^30`, deposits and transfers, including direct transfers, are rejected. Pending entries can still be inserted; already inserted notes can still exit. There is no rollover in this profile.

A terminal exit has no new output, zero tip/value, and an authenticated terminal record:

```text
term_0 = H253(SHA256("SETH/v7/terminal-exits" || poolId))
term_(n+1) = H253(SHA256(u256be(term_n) || u64be(n) || u256be(extHash)))
```

It emits the complete body. `EXIT_2_0` withdraws all value of its enabled inputs and cannot create change or a shielded broadcaster fee. At capacity, assistance must be separately sponsored or paid outside the nonexistent output path. Do not promise normal fee-note compensation for terminal exits. A fee quote cannot manufacture capacity.

## 11. Canonical bodies and public statements

### 11.1 Version and circuit identifiers

Protocol `VERSION=7`; operations `DEPOSIT=1`, `TRANSFER=2`, `EXIT=3`.

| ID | Circuit | Public fields in exact order | Count |
|---:|---|---|---:|
| 1 | TRANSFER_2_4 | `noteDomain,numAssets,root,publicAmount,publicAsset,extHash,nf[2],cm[4]` | 12 |
| 2 | TRANSFER_8_4 | Same prefix, `nf[8],cm[4]` | 18 |
| 3 | EXIT_2_0 | Same prefix, `nf[2]` | 8 |
| 4 | BATCH_1 | `statement` | 1 |
| 5 | BATCH_UPTO_16 | `statement` | 1 |
| 6 | TRANSFER_2_4_DIRECT | ID 1 fields followed by `newRoot,ownIndex,absorbIndex,absorbPartial,absorbValue,absorbAsset` | 18 |

Verifier dispatch is immutable and exact. A changed circuit/public-input order requires new setup artifacts and a new compatible deployment, not a runtime reinterpretation.

### 11.2 Canonical ABI schemas

```text
Header values, in order:
  bytes32 BODY_TAG = keccak256("SETH/v7/BODY")
  uint16 version = 7
  uint8 operation
  uint8 circuitId
  bytes32 poolId
  uint256 currentChainId
  uint128 V = msg.value

DepositBody = (uint8 asset, uint256 partialCommitment, uint128 amount, uint128 tip, bytes ciphertext)
TransferBody = (uint64 rootSeq, uint256 root, uint256[] nullifiers, uint256[4] commitments,
                uint128 W, uint8 publicAsset, uint128 tip, address recipient, uint32 payoutGas,
                address executor, uint64 deadline, bytes32 nonce,
                bytes recipientCiphertexts, bytes recoveryCiphertext)
ExitBody = (uint64 rootSeq, uint256 root, uint256[2] nullifiers,
            uint128 W, uint8 publicAsset, uint128 tip, address recipient, uint32 payoutGas,
            address executor, uint64 deadline, bytes32 nonce)
PendingRecord = (uint8 kind, uint256[4] w, uint256 extHash, uint128 tip)
DirectContext = (uint40 expectedInserted, uint40 expectedNext, uint256 expectedInsertedAcc,
                 uint256 expectedQueueAcc, uint256 newRoot, address rewardBeneficiary, bytes32 pendingHash)
```

For deposit/queued transfer/exit, use `abi.encode(header values..., bodyTuple)`. For direct mode, use `abi.encode(header values..., transferBody, directContext)`, with two trailing tuples, not an extra nested tuple. `pendingHash=keccak256(abi.encode(pendingRecords))` with the exact PendingRecord[] type. These distinctions must be cross-language tested.

```text
extHash = H253(keccak256(canonicalBody))
```

Transfer recipient bytes are exactly 436, recovery bytes exactly 400, deposit bytes exactly 109. Arrays are bounded by the circuit. Canonical re-encoding is built by the contract; alternative outer ABI padding is not a second logical body. Deadline and executor are checked by the contract. `executor=0` permits any submission but never changes authorized outputs or the direct reward beneficiary.

### 11.3 Spending relation

Derive `ak,nk` from a nonzero `sk`. Slot zero is enabled. Every enable flag is Boolean. Every enabled note has positive bounded value, canonical 88-bit diversifier, nonzero randomness/partial/commitment, correct ownership, membership at its bit-derived position, and the correct real nullifier. Disabled slots have zero value and a fresh nonzero dummy seed; their nullifiers are forced to the dummy form.

Each output reconstructs its commitment with the same private registered asset and bounded value. Output encryption is outside this relation. Require conservation and the withdrawal/public-asset relation above. Contract checks handle duplicate/current nullifiers and actual token/ETH movement.

### 11.4 Envelope binding review gate

The candidate preserves the predecessor's quadratic retention relation:

```text
extSq <== extHash * extHash
```

**BIND-01.** Before setup, independently inspect the compiled relation and generated verifier and establish the required binding of all externally meaningful body fields under the selected Groth16 construction. An unused public variable, a comment, or one honest-proof mutation test is not sufficient. The retention relation remains a candidate subject to this gate; if the review rejects it, replace it with a reviewed binding construction and regenerate all artifacts. Do not claim generic strong nonmalleability or proof-byte uniqueness.

The batch statement is actually recomputed inside its circuit. The direct `extHash` includes beneficiary and complete state expectations. Public fields which enter arithmetic directly must still agree with their duplicate occurrences in the contract-rebuilt body.

## 12. Contract interface and execution requirements

| Entry point | Payment/proof | Behavior |
|---|---|---|
| `deposit(asset,partialCommitment,amount,ciphertext)` | Payable; no proof | Public entry; exact amount/asset/tip; queue; returns entry index |
| `transact(circuitId,proof,TransferBody)` | Payable, value equals tip | Queued single-asset spend and optional W |
| `transactDirect(proof,TransferBody,DirectContext,pending[])` | Nonpayable; direct proof | §9, including R1 membership and bound reward |
| `exit(proof,ExitBody)` | Payable, value equals tip | Complete-note exit; idle/queued/terminal history handling |
| `insertBatch(circuitId,expectedStart,expectedOldRoot,expectedAccStart,k,newRoot,baseTipSum,beneficiary,proof)` | Nonpayable; batch proof | Proved prefix insertion |
| `skipZeroEntries(expectedStart,expectedAccStart,beneficiary,records[])` | Nonpayable; no proof | Authenticated zero prefix, max 16 |
| `addInsertionTip(entry)` | Positive ETH | Nonrefundable pending reward top-up |
| `claimInsertionFees(to,amount)` | Nonpayable | Withdraw caller's earned ETH credit |

Views include full pool identity, version, asset table/count/caps, liabilities, roots, accumulator checkpoints, insertion scheduling, nullifier status, and credits.

All mutable entry points share the reentrancy guard. The candidate uses EIP-1153 transient storage on a compatible execution environment; pin the supported EVM revision and do not deploy to a chain lacking the instruction. [R-TRANSIENT]

Check supported sizes, deadlines, executor, payout rules, value, and capacity before expensive proof work. Require explicit true from the immutable generated verifier; reject missing code and canonical-coordinate violations. No mock or alternate verifier supplied by a caller can reach production.

For ETH W, recipient must be nonzero/non-pool and `0<payoutGas<=payoutGasCap`; use a conservative EIP-150-aware gas check. For a token W, `payoutGas=0` and immutable per-asset token call caps apply. All payout effects occur under the lock; failure rolls back the spend.

Events contain full canonical bodies and insertion transitions: `EntryPublished`, `Inserted`, `InsertionTipAdded`, `InsertionFeesClaimed`, and `TerminalExitPublished`. Index by chain and block hash, transaction/log position, and entry/sequence. A call routed through a smart account must remain reconstructible without privileged call traces.

## 13. Submission and asset-aware fees

### 13.1 Self-submission

A standalone CLI/wallet supports restore, verified sync, build, local proof, simulation, ordinary Ethereum submission, fallback prefix insertion, credit claims, and exit. Show principal, change, asset identity, public W/V/tip, direct-mode state expectations, reward destination, expected fee, and upfront funding allowance. Do not impose a service fee on this route.

### 13.2 Fixed broadcaster quote

The provider fronts public ETH and receives `F_a` base units of the transaction's asset in an ordinary output. The private quote includes full pool/chain identity, circuit/mode, fee asset ID and token address, fee address, exact `F_a`, ETH tip budget, executor, direct reward beneficiary, deadline, price assumptions, redemption/race allowance, and failure terms.

The provider must decrypt its own prospective note, verify its asset/owner/amount/commitment, verify the complete proof, authenticate relevant state, and simulate the exact call. Neither decryption alone nor proof validity alone establishes payment to that provider.

Quotes are fixed before proving. A token quote may be computed from a rational exchange rate expressed as asset base units per wei, with upward rounding. The rate, spread, expiry, and token inventory exposure are off-chain service terms; no pool oracle is introduced. If the provider has no market for a particular approved asset, it may decline it. Protocol support does not guarantee a quote.

EIP-712 can authenticate the quote, but application deadlines and replay IDs still need explicit handling. [R-712] Do not publish the fee amount or role index just to authenticate the quote. A public random session nonce avoids an unnecessary small-menu fee hash fingerprint.

### 13.3 Charging and retry policy

| Event | State | Cost allocation |
|---|---|---|
| Declined or invalid before submission | None | No fee note and no user debt |
| Mined spend reverts | Pool effects revert | Outer sender bears gas |
| Queued spend succeeds | Inputs spent, funded outputs pending | Fixed fee exists but awaits insertion |
| Direct spend succeeds | Outputs inserted | Fixed fee usable subject to chain policy |
| Provider loses batch/direct race | No effects | Loser pays inclusion/revert cost and reproving cost |
| Ciphertext malformed | Funded commitment can be unrecoverable | No automatic refund |
| Top-up changes before direct execution | Same authorized state transition | Bound beneficiary receives resulting collected amount |
| Service unavailable | Notes remain governed by core | Self-submit or obtain another quote |

Changing an authorized output, tip, fee, executor, deadline, or bound direct context requires fresh authorization/proof. Replacing the outer Ethereum gas price alone does not change the proof statement. Making a replacement proof does not cancel an earlier one; conflicting versions remain valid until their deadlines or until common real nullifiers are consumed.

## 14. Wallet state, verified recovery, and privacy

### 14.1 Required note lifecycle

`observed → decrypted-and-matched → accepted/queued → inserted → spendable-under-policy → spent`. A direct operation can move accepted outputs immediately to inserted. A queued input used in direct mode is spent only through the fully verified intermediate-root transition; it is not generally spendable before insertion.

Use current canonical history to roll back nullifiers, positions, queued outputs, credits, and direct transitions together on a reorganization. Keep local pending locks separate from accepted state.

### 14.2 Authenticated synchronization

Use a verified Ethereum state root from a selected node/light-client policy. Verify storage proofs for identity/counters, pinned inserted accumulator, queue-head accumulator, root, and terminal-exit head. Fetch full canonical bodies, re-encode and hash them, check the accumulator, and independently rebuild the inserted tree and terminal exits. [R-PROOF]

An arbitrary RPC is not authenticated merely because it returns JSON containing a root. A state proof must be verified against the selected authenticated state root. Missing history is a liveness/recovery failure, not permission to accept an unverified snapshot.

Rebuild nullifiers locally when possible. Queries for the specific nullifiers of one wallet can reveal that grouping to the RPC; verified storage responses do not hide query contents.

### 14.3 Recovery and archival obligations

Seed plus available authenticated history should restore received notes, spent status, and outgoing records encrypted under that wallet's recovery key. Gift-wallet source history and an unfinished E2 swap need their separate records; they must not be represented as recoverable from the main seed alone.

Publish self-verifying archived bodies and snapshots over independent mirrors and document restore without the original frontend. Do not rely on indefinite RPC retention of either calldata or logs. Storing the same bytes twice is not an indefinite archival guarantee.

### 14.4 Privacy statement by observer

| Observer | Information or potential inference |
|---|---|
| Public chain observer | Deposits/withdrawals, their asset and amounts, timing, fixed circuit shape, nullifiers, commitments, ciphertext sizes, tips, root choices, direct absorb records, submitting accounts |
| Recipient | Its note asset/amount and payment context; single-asset rule links that knowledge to the transaction asset |
| Broadcaster | Its fee asset/amount, its output, quote, and network/session metadata; knows the transaction asset |
| Batcher | Public queue/tree data and operational observations, not private note openings solely from proving |
| Gift-link holder | Gift seed, receipts in that wallet, nullifiers, and any recovery record encrypted under its shared key |
| Indexer/RPC | Requests and access patterns, potentially selected leaves/nullifiers |

Pure private transfers omit an explicit asset ID; this does not imply that every candidate history is equally plausible or that all assets supply the same effective anonymity. A shared tree is an accumulator design, not a numerical privacy guarantee. Thin assets, recognizable amounts, timing, sender reuse, and first-deposit direct spending require local warnings. No “anonymity score” is claimed without a defined model.

## 15. Gas and economic measurement

### 15.1 Authoritative numbers are receipts

No full-transaction v0.7 gas totals are asserted here. Regenerate calldata sizes and benchmark real verifiers for every operation. First-ever writes, fresh ring slots with nonzero liabilities, reused slots, checkpoint writes, top-up collection, token balance checks, and recipient-account state are separate cases. The prior 65k “first deposit” claim must not be copied into this release.

A deposit using the specified four-argument ABI and 109 ciphertext bytes occupies **292 calldata bytes** (`4 + 4*32 + 32 + 128`). This is encoding arithmetic, not its gas price. Direct calldata adds its context and variable pending prefix; measure from the exact ABI encoder.

### 15.2 Verifier arithmetic reference

Under the EIP-1108 schedule, conventional four-pair Groth16 precompile arithmetic is `181000 + 6150*p`. [R-1108]

| Circuit | p | Calculated precompile arithmetic only |
|---|---:|---:|
| TRANSFER_2_4 | 12 | 254,800 |
| TRANSFER_8_4 | 18 | 291,700 |
| EXIT_2_0 | 8 | 230,200 |
| BATCH_1 / BATCH_UPTO_16 | 1 | 187,150 |
| TRANSFER_2_4_DIRECT | 18 | 291,700 |

These exclude calls/memory, calldata, storage, events, payout, token checks, and all wallet proving cost. Constraint counts and deployed bytecode sizes must be regenerated; the v0.6 figures are not v0.7 results.

### 15.3 Actual fee versus required funding

For ordinary EIP-1559 submission:

```text
effectivePrice = min(maxFeePerGas, baseFee + maxPriorityFeePerGas)
actualETHCost = receipt.gasUsed * receipt.effectiveGasPrice
upfrontFunding = msg.value + gasLimit * maxFeePerGas
```

The maximum allowance is not necessarily spent. Successful and reverting mined transactions have actual fees; rejected/unbroadcast attempts do not consume on-chain execution gas. Use the applicable fork's transaction accounting, including EIP-7623's calldata floor where active. Never add a floor twice. [R-1559; R-7623]

### 15.4 Complete transaction sequences

Measure at least: ETH and each token deposit; first pending deposit directly spent; old note directly spent with/without unrelated deposit absorption; queued send plus actual insertion; first-deposit exit including insertion; service-assisted withdrawal; consolidation; terminal exit; zero-entry skip; and an E2 claim/settle/insert/spend sequence.

Report user total, provider public funding, provider earned private value, time to spendability, and unreimbursed failed attempts separately. A 1/16 batch share is justified only when that entry actually shares a sixteen-entry batch or the service explicitly subsidizes it.

For illustration only, 500,000 gas at 0.5 gwei is 0.00025 ETH; at a hypothetical $3,000/ETH that is $0.75. At 5 gwei it is $7.50. This is sensitivity arithmetic, not a v0.7 measurement or a promise that $1–2 buys a transaction.

## 16. Test requirements and independent checks

### 16.1 Test infrastructure must fail closed

Each test declares acceptance or rejection. Unexpected acceptance **or** rejection fails the process. Missing build files, compiler errors, command timeouts, and malformed test fixtures are infrastructure failures, never successful malicious-witness rejection. Remove logging-only test helpers. Appendix D gives a pattern; CI must prove that deliberately inverted expectations fail.

Real-verifier integration is separate from mock-based state-machine tests. Run full-depth proofs for all six circuits. A mock matching a reference public-input array does not test the verifier or malicious witness relation.

### 16.2 Mandatory regression families

| Family | Required cases |
|---|---|
| Multi-asset | Every approved ID; hidden asset outside count; ETH as token and token as ETH; mixed inputs/outputs; asset mutation in deposit/batch/direct; fee asset mismatch |
| Amounts | 0,1,2^64 boundaries,2^128-1,2^128 rejection; sum wrap; W mapping; double-counted fee/tip |
| Direct first-note | Empty root + own pending ETH deposit; repeat for token; mixed old/new same-asset inputs; foreign deposit only inserted; attempt to spend another owner's deposit |
| Direct context | Change reward beneficiary, prefix count/hash, old accumulator, queue head, own index, new root; top-up arrival; index zero absorb; empty prefix |
| Direct races | Deposit, transfer, batch, and idle exit between proof and inclusion; pending 0–4; too many; two deposits; unsupported transfer prefix; safe queued fallback |
| Nullifiers | Same occurrence under roots/chain contexts/versions of a quote; current duplicate; within-call duplicate; wrong bit-derived position; dummy reuse/masking |
| Tree | Independent sparse reference after every append; all carry patterns; explicit positions 2^31-1,2^31,2^32-1; overwrite and final-capacity cases |
| Queue | Starts 0..31 and ring boundaries; `1,1041`; long backlog; checkpoint and zero hashes; active/inactive batch slots; every k=1..16 |
| Tips/credits | 128-bit entry limits; 132-bit batch sum; donations; double collection; beneficiary rejection; top-up race; claim reentrancy; pending count accuracy |
| Tokens | Normal/no-return/false/malformed/huge return; no-op success; short delivery on both directions; sender surcharge; rebase during call; callbacks; changing/reverting/lying balanceOf; changed dependency |
| Cross-asset availability | Broken token must not require balance calls in unrelated-token/ETH exits, insertion, or hidden transfers |
| Delivery | Invalid/identity points before AEAD, wrong lengths/version/asset/key, epk mismatch, altered records; scanner continues after bad output; outgoing recovery round trip |
| Gift recovery | Main recipient ovk opens sweep history; shared gift ovk does not; padding cannot be detected by gift ivk |
| Proof interfaces | Wrong public order; aliased fields/bits; invalid points; false-return verifier; direct/body binding; no production mock path |
| Capacity | Final entry, insertion at full queue, terminal exits, no terminal fee-output promise, terminal history recovery |
| State rollback | Failed ETH/token payout, failed credit claim, cap rejection, forged proof, reentrancy, outer call exceptions |
| Archive/reorg | Authenticated full-body replay; omitted/reordered data; restore independently; both pending and inserted state roll back consistently |

A plaintext reference ledger tracks every funded note occurrence, its asset/value, pending/inserted/spent state, pool balances, liabilities, tips, and credits. Check invariants after every accepted and rejected action. Use a second implementation for critical encodings and roots; tests sharing one helper are not the only oracle.

### 16.3 Required artifacts

Pin source commits, dependencies, compilers, flags, circuit/R1CS hashes, witness-generator hashes, proving/verifying keys, verifier runtime hashes, EVM/client versions, hardware, workload, seed vectors, raw receipts, and test outcomes. Redact secrets only in public production-like traces, never substitute invented expected values for unreproduced vectors.

## 17. Release gates

| Gate | Required evidence |
|---|---|
| G0: Profile | Independent review of asset-bearing commitments, field encoding, binding, direct R1 relation, encryption/key separation, and source/ABI agreement |
| G1: Reference | Independent implementations match all new v0.7 vectors; fail-closed CI; high-index/scanner/queue regressions |
| G2: Full prototype | All six full-depth real verifiers; ETH and token first-note transaction sequences; terminal and negative cases |
| G3: Services/costs | Asset-specific quotes; separate batcher/broadcaster; receipt-based gas tables; full-batch memory and desktop/mobile proving |
| G4: Public testing | Independent restores, backlog/reorg/race drills, token failures, gift claim and onward payment |
| G5: Review/freeze/setup | Independent circuit, cryptography, contract, wallet reviews; no open critical/high findings; frozen code; reproducible public setup and verifiers |
| G6: Limited deployment | Verified immutable deployment with at least two approved assets; permanent ceilings; exact asset manifest; tested exits/credits; published artifacts |

E1 and E2 have their own activation gates. A core release does not declare the Monero side correct. Ceremony work must follow final circuit review; subsequent circuit edits invalidate its artifact association.

## 18. Launch, incidents, and migration

The deployment has no owner, upgrade, pause, delegatecall-based administration, privileged sweep, or parameter setter. Immutable external token dependencies can still have their own authorities; disclose those separately.

Per-asset admission cap:

```text
periods = floor((now - deploymentTime) / rampPeriod)
cap_a(now) = min(assetCapCeiling[a], assetRampC0[a] * 2^periods)
```

Compute saturation before shifting beyond safe widths. Time increases the configured limit, not security assurance. Set `rampC0=capCeiling` for a constant limit. No ceiling can be raised in place. Tokens use their own base-unit limits; summing different assets into an alleged ETH risk cap would require valuations this core does not provide.

Only deposits increase note liability and check admission limits. Limits must not block private transfers, insertion, credits, or exits. Voluntary migration to a new deployment is the upgrade path; old nullifiers, asset IDs, and address versions are never silently reinterpreted.

A deterministic deployment can remove a privileged deployment role, but does not establish author anonymity or legal conclusions. Operators decide their own service and jurisdictional obligations separately. The runbook must state actual available actions after a flaw, rather than promising administrative reimbursement or recovery that does not exist.

## 19. Release manifest and implementation checklist

The manifest must contain at least:

```text
protocolVersion, chainId, poolAddress, poolId, instanceSalt, deployTx/blockHash/time
assetCount, ordered asset configs, token addresses, decimals/display identity
asset source/code/proxy/dependency records and risk-review hashes
rampPeriod, permanent ceilings, payoutGasCap, token call/balance gas caps
scalar/base fields, Poseidon tags/constants/library hashes, zero roots
address/ciphertext/KDF formats, queue/body schemas, storage-layout hash
all six circuit IDs and ordered public inputs; R1CS/witness-generator hashes
setup transcripts, proving/verifying key hashes, verifier code hashes
compiler/dependency locks, runtime bytecode size and hash, EVM/client revision
independent test vectors and invariant/fuzz reports
real receipt/proving/recovery benchmarks and their hardware/state scenarios
archive locations and authenticated restore instructions
E1/E2 versions, separately stated activation status, and supported swap profiles
```

A missing item is a release blocker, not permission to infer it from a similarly named earlier file.

## 20. Sources and interpretation

**S-C5:** `ShieldedETH_v0_5_Core.md`, particularly §§2–13 and Appendices A–E.  
**S-C6:** `ShieldedETH_v0_6_Core_Delta.md`, particularly §§2–10 and Appendices A–D.  
**S-E1:** `ShieldedETH_v0_5_E1_Capacity.md`.  
**S-E2:** `ShieldedETH_v0_5_E2_XMR_Settlement.md`.

Those sources support the inherited design and the description of their own tests. They do not establish v0.7 implementation results. Changes in §0.2 and additional normative requirements are this revision's proposed decisions.

Primary references for underlying standards (not endorsements of this construction):

- **R-ERC20:** [ERC-20](https://eips.ethereum.org/EIPS/eip-20), token interface and false-return handling.
- **R-712:** [EIP-712](https://eips.ethereum.org/EIPS/eip-712), typed-data hashing/signing; application replay protection is separate.
- **R-BN254:** [EIP-196](https://eips.ethereum.org/EIPS/eip-196) and [EIP-197](https://eips.ethereum.org/EIPS/eip-197), elliptic-curve/pairing interfaces.
- **R-1108:** [EIP-1108](https://eips.ethereum.org/EIPS/eip-1108), precompile gas schedule.
- **R-1559:** [EIP-1559](https://eips.ethereum.org/EIPS/eip-1559), fee pricing and upfront funding.
- **R-7623:** [EIP-7623](https://eips.ethereum.org/EIPS/eip-7623), calldata-dependent transaction cost floor.
- **R-TRANSIENT:** [EIP-1153](https://eips.ethereum.org/EIPS/eip-1153), transient storage semantics; verify target-chain support.
- **R-PROOF:** [EIP-1186](https://eips.ethereum.org/EIPS/eip-1186), account/storage proof RPC.
- **R-RISTRETTO:** [RFC 9496](https://datatracker.ietf.org/doc/html/rfc9496), ristretto255 group and encodings.
- **R-HKDF:** [RFC 5869](https://datatracker.ietf.org/doc/html/rfc5869), HKDF.
- **R-AEAD:** [RFC 8439](https://www.rfc-editor.org/rfc/rfc8439), ChaCha20-Poly1305.

All protocol-specific combinations, caps, layouts, and operational policies still require the review gates above. No current market prices, token deployment approvals, or future network-fork dates are asserted by these references.


## Appendix A: Pool implementation candidate

This source is adapted from the supplied v0.6 pool, with the v0.7 revisions described in §0.2. **It has not been compiled or executed for this revision.** The contract, circuits, generated verifiers, reference code, and manifest must agree before G2 can pass. The normative rules above control this engineering draft; an implementation discrepancy is a defect to resolve, not an alternative interpretation.

No verifier keys or production deployment parameters are embedded. Do not replace missing verifier artifacts with mocks in a value-bearing deployment. The mandatory multi-asset constructor requires at least native ETH and one approved token.


### A.1 `ShieldedETHPool.sol`

Save this block as `contracts/ShieldedETHPool.sol`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Generated snarkjs Groth16 verifiers (unmodified output), one per circuit.
interface IVerifier1  { function verifyProof(uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c, uint256[1]  calldata pub) external view returns (bool); }
interface IVerifier8  { function verifyProof(uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c, uint256[8]  calldata pub) external view returns (bool); }
interface IVerifier12 { function verifyProof(uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c, uint256[12] calldata pub) external view returns (bool); }
interface IVerifier18 { function verifyProof(uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c, uint256[18] calldata pub) external view returns (bool); }

/// @title ShieldedETH v0.7 core pool: multi-asset, shared commitment tree, direct mode for idle-compatible queues.
/// Immutable: no owner, pause, upgrade, delegatecall, fee or sweep.
contract ShieldedETHPool {
    // ------------------------------------------------------------------ constants
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 internal constant MASK253 = (uint256(1) << 253) - 1;
    uint16  public constant VERSION = 7;
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
    bytes32 public constant BODY_TAG = keccak256("SETH/v7/BODY");

    // ------------------------------------------------------------------ types
    struct Proof { uint256[2] a; uint256[2][2] b; uint256[2] c; }
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
    }

    // ------------------------------------------------------------------ immutables
    bytes32 public immutable poolId;
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
    event TerminalExitPublished(uint64 indexed sequence, uint256 extHash, bytes canonicalBody);

    // ------------------------------------------------------------------ errors
    error Reentrancy(); error BadLength(); error BadField(); error BadAmount(); error BadCircuit(); error BadAsset();
    error Expired(); error NotExecutor(); error BadRecipient(); error BadPayoutGas(); error NonCanonical();
    error UnknownRoot(); error NullifierUsed(); error DuplicateNullifier(); error BadProof(); error CapExceeded();
    error Full(); error Stale(); error BadK(); error UnknownAccumulator(); error TipAccounting(); error NotPending();
    error PayoutFailed(); error TokenTransferFailed(); error InsufficientGas(); error Backing(); error Liability();
    error BadParams(); error NotAbsorbable();

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
        uint256 a0 = _h253(sha256(abi.encodePacked("SETH/v7/acc", id)));
        poolId = id; noteDomain = dom; acc0 = a0; numAssets = uint8(n);
        insertedAcc = a0;
        terminalExitAcc = _h253(sha256(abi.encodePacked("SETH/v7/terminal-exits", id)));
        rootRing[0] = EMPTY_ROOT;
        t0 = uint64(block.timestamp);
        rampPeriod = p.rampPeriod; payoutGasCap = p.payoutGasCap;
        vTransfer24 = p.vTransfer24; vTransfer84 = p.vTransfer84; vExit = p.vExit;
        vBatch1 = p.vBatch1; vBatch16 = p.vBatch16; vDirect = p.vDirect;
    }

    // ================================================================== deposit (no proof, no on-chain Poseidon)
    /// asset 0: msg.value = amount + tip. ERC-20 assets: exactly `amount` pulled via transferFrom; msg.value = tip (ETH).
    function deposit(uint8 asset, uint256 partialCommitment, uint128 amount, bytes calldata ciphertext)
        external payable nonReentrant returns (uint40 entry)
    {
        if (asset >= numAssets) revert BadAsset();
        if (ciphertext.length != 109) revert BadLength();
        if (partialCommitment == 0 || partialCommitment >= R) revert BadField();
        if (amount == 0 || msg.value >= (uint256(1) << 128)) revert BadAmount();
        if (nextEntry >= MAX_ENTRIES) revert Full();
        if (liability[asset] + amount > rampCap(asset)) revert CapExceeded();
        uint128 tip;
        if (asset == 0) {
            if (msg.value < amount) revert BadAmount();
            tip = uint128(msg.value) - amount;
        } else {
            tip = uint128(msg.value);
            _pullToken(asset, amount);
        }
        bytes memory body = abi.encode(BODY_TAG, VERSION, OP_DEPOSIT, uint8(0), poolId, block.chainid, uint128(msg.value),
            DepositBody(asset, partialCommitment, amount, tip, ciphertext));
        uint256 extHash = _h253(keccak256(body));
        liability[asset] += amount;
        T += tip;
        entry = _enqueue(OP_DEPOSIT, [partialCommitment, uint256(amount), uint256(asset), 0], extHash, tip, body);
        _checkBacking(asset);
    }

    // ================================================================== queued private transfer
    function transact(uint8 circuitId, Proof calldata proof, TransferBody calldata b) external payable nonReentrant {
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
            ok = IVerifier12(vTransfer24).verifyProof(proof.a, proof.b, proof.c, pub);
        } else {
            uint256[18] memory pub;
            pub[0] = noteDomain; pub[1] = numAssets; pub[2] = b.root; pub[3] = pubAmt; pub[4] = b.publicAsset; pub[5] = extHash;
            for (uint256 i = 0; i < 8; i++) pub[6 + i] = b.nullifiers[i];
            for (uint256 j = 0; j < 4; j++) pub[14 + j] = b.commitments[j];
            ok = IVerifier18(vTransfer84).verifyProof(proof.a, proof.b, proof.c, pub);
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
    function transactDirect(Proof calldata proof, TransferBody calldata b, DirectContext calldata d, PendingRecord[] calldata pending)
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
            if (!IVerifier18(vDirect).verifyProof(proof.a, proof.b, proof.c, pub)) revert BadProof();
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
    function exit(Proof calldata proof, ExitBody calldata b) external payable nonReentrant {
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
        if (!IVerifier8(vExit).verifyProof(proof.a, proof.b, proof.c, pub)) revert BadProof();
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
        uint8 k, uint256 newRoot, uint256 baseTipSum, address beneficiary, Proof calldata proof
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
        if (!IVerifier1(v).verifyProof(proof.a, proof.b, proof.c, [stmt])) revert BadProof();
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

    function nextBatchWindow() external view returns (uint40 start, uint8 k) {
        start = insertedEntries;
        uint40 ne = nextEntry;
        if (start >= ne) return (start, 0);
        uint40 end = (start / STRIDE + 1) * STRIDE;
        if (end > ne) end = ne;
        k = uint8(end - start);
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

    function _checkProofEncoding(Proof calldata p) internal pure {
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
        assembly ("memory-safe") {
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
        assembly ("memory-safe") {
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


## Appendix B: Circuit implementation candidates

Save the common library and templates into `circuits/`, and each main into its own file. These templates target the predecessor's Circom 2.1.9 / circomlib 2.0.5 interface; compatibility and compiler output have **not** been established here. Freeze reviewed commits and compiler flags before setup. Do not inherit constraint counts or proof times from v0.6.

The decisive direct-mode change is the membership root `rootA`. The outer public `root` remains the authenticated pre-insertion root; `rootA` is derived inside the circuit by inserting the authenticated pending deposit. All actual inputs must be owned and funded under that intermediate root.

The batch circuit uses full 256-bit pool/chain context, strict canonical field decomposition, a 132-bit base-tip sum, and active-prefix masking. Every supported batch size and the final-capacity boundary still require real proving tests.


### B.1 Common library

Save this block as `circuits/lib.circom`.

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
    component n2b;
    if (width == 254) { n2b = Num2Bits_strict(); } else { n2b = Num2Bits(width); }
    n2b.in <== in;
    var total = bytesLen * 8;
    for (var p = 0; p < total; p++) {
        var lsbIndex = total - 1 - p;
        if (lsbIndex < width) { out[p] <== n2b.out[lsbIndex]; } else { out[p] <== 0; }
    }
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
```


### B.2 Transfer, exit, and corrected direct relation

Save this block as `circuits/transfer.circom`.

```circom
pragma circom 2.1.9;
include "lib.circom";

// One input slot. enabled=1: real note under `root`; enabled=0: zero value, dummy nullifier.
template InputSlot(depth, slotIndex) {
    signal input ak;
    signal input nk;
    signal input noteDomain;
    signal input root;
    signal input enabled;
    signal input value;
    signal input d;
    signal input rseed;
    signal input pathElements[depth];
    signal input pathBits[depth];
    signal input dummySeed;
    signal input asset;
    signal output nf;

    enabled * (enabled - 1) === 0;
    component vBits = Num2Bits(128); vBits.in <== value;
    component dBits = Num2Bits(88);  dBits.in <== d;

    component owner = TaggedPoseidon(2, T_OWNER()); owner.in[0] <== ak;      owner.in[1] <== d;
    component part  = TaggedPoseidon(2, T_PART());  part.in[0]  <== owner.out; part.in[1] <== rseed;
    component cm    = TaggedPoseidon(3, T_CM());    cm.in[0]    <== part.out;  cm.in[1]   <== value; cm.in[2] <== asset;

    component fold = MerkleFold(depth);
    fold.leaf <== cm.out;
    var pos = 0;
    for (var h = 0; h < depth; h++) {
        fold.sib[h] <== pathElements[h];
        fold.bits[h] <== pathBits[h];
        pos += pathBits[h] * (1 << h);
    }
    enabled * (fold.root - root) === 0;

    // enabled => value, rseed, partial, cm all nonzero; disabled => value == 0, dummySeed nonzero
    component zV = IsZero(); zV.in <== value;
    component zR = IsZero(); zR.in <== rseed;
    component zP = IsZero(); zP.in <== part.out;
    component zC = IsZero(); zC.in <== cm.out;
    component zS = IsZero(); zS.in <== dummySeed;
    enabled * zV.out === 0;
    enabled * zR.out === 0;
    enabled * zP.out === 0;
    enabled * zC.out === 0;
    (1 - enabled) * value === 0;
    (1 - enabled) * zS.out === 0;

    component real = TaggedPoseidon(4, T_NF());
    real.in[0] <== noteDomain; real.in[1] <== nk; real.in[2] <== cm.out; real.in[3] <== pos;
    component dummy = TaggedPoseidon(3, T_DUMMY());
    dummy.in[0] <== noteDomain; dummy.in[1] <== dummySeed; dummy.in[2] <== slotIndex;
    nf <== dummy.out + enabled * (real.out - dummy.out);
}

template OutputNote() {
    signal input owner;
    signal input value;
    signal input rseed;
    signal input asset;
    signal output cm;
    component vBits = Num2Bits(128); vBits.in <== value;
    component nzR = NonZero(); nzR.in <== rseed;
    component part = TaggedPoseidon(2, T_PART()); part.in[0] <== owner;    part.in[1] <== rseed;
    component c    = TaggedPoseidon(3, T_CM());   c.in[0]    <== part.out; c.in[1]    <== value; c.in[2] <== asset;
    component nzP = NonZero(); nzP.in <== part.out;
    component nzC = NonZero(); nzC.in <== c.out;
    cm <== c.out;
}

template SpendKeys() {
    signal input sk;
    signal output ak;
    signal output nk;
    component nz = NonZero(); nz.in <== sk;
    component a = TaggedPoseidon(1, T_AK()); a.in[0] <== sk;
    component n = TaggedPoseidon(1, T_NK()); n.in[0] <== sk;
    ak <== a.out;
    nk <== n.out;
}

// TRANSFER_N_4 (queued). Public input order = declaration order below.
// One hidden asset per transaction: every input and output uses `asset`.
template Transfer(nIn, nOut, depth) {
    signal input noteDomain;
    signal input numAssets;
    signal input root;
    signal input publicAmount;
    signal input publicAsset;
    signal input extHash;
    signal input nf[nIn];
    signal input cm[nOut];

    signal input sk;
    signal input asset;
    signal input inEnabled[nIn];
    signal input inValue[nIn];
    signal input inD[nIn];
    signal input inRseed[nIn];
    signal input inPath[nIn][depth];
    signal input inBits[nIn][depth];
    signal input inDummySeed[nIn];
    signal input outOwner[nOut];
    signal input outValue[nOut];
    signal input outRseed[nOut];

    component keys = SpendKeys(); keys.sk <== sk;
    inEnabled[0] === 1;
    component assetBits = Num2Bits(8); assetBits.in <== asset;
    component countBits = Num2Bits(4); countBits.in <== numAssets;
    component countMin = LessThan(4); countMin.in[0] <== 1; countMin.in[1] <== numAssets; countMin.out === 1;
    component countMax = LessThan(4); countMax.in[0] <== numAssets; countMax.in[1] <== 9; countMax.out === 1;
    component validAsset = LessThan(8); validAsset.in[0] <== asset; validAsset.in[1] <== numAssets; validAsset.out === 1;
    publicAmount * (asset - publicAsset) === 0;      // asset is revealed only when value crosses the boundary

    component slot[nIn];
    var sumIn = 0;
    for (var i = 0; i < nIn; i++) {
        slot[i] = InputSlot(depth, i);
        slot[i].ak <== keys.ak; slot[i].nk <== keys.nk;
        slot[i].noteDomain <== noteDomain; slot[i].root <== root;
        slot[i].enabled <== inEnabled[i]; slot[i].value <== inValue[i];
        slot[i].d <== inD[i]; slot[i].rseed <== inRseed[i];
        for (var h = 0; h < depth; h++) { slot[i].pathElements[h] <== inPath[i][h]; slot[i].pathBits[h] <== inBits[i][h]; }
        slot[i].dummySeed <== inDummySeed[i];
        slot[i].asset <== asset;
        nf[i] === slot[i].nf;
        sumIn += inValue[i];
    }
    component out[nOut];
    var sumOut = 0;
    for (var j = 0; j < nOut; j++) {
        out[j] = OutputNote();
        out[j].owner <== outOwner[j]; out[j].value <== outValue[j]; out[j].rseed <== outRseed[j]; out[j].asset <== asset;
        cm[j] === out[j].cm;
        sumOut += outValue[j];
    }
    sumIn + publicAmount === sumOut;
    signal extSq;
    extSq <== extHash * extHash;
}

// EXIT_2_0: no outputs; all consumed note value leaves as W; the public ETH tip is separate.
template Exit(nIn, depth) {
    signal input noteDomain;
    signal input numAssets;
    signal input root;
    signal input publicAmount;
    signal input publicAsset;
    signal input extHash;
    signal input nf[nIn];

    signal input sk;
    signal input asset;
    signal input inEnabled[nIn];
    signal input inValue[nIn];
    signal input inD[nIn];
    signal input inRseed[nIn];
    signal input inPath[nIn][depth];
    signal input inBits[nIn][depth];
    signal input inDummySeed[nIn];

    component keys = SpendKeys(); keys.sk <== sk;
    inEnabled[0] === 1;
    component assetBits = Num2Bits(8); assetBits.in <== asset;
    component countBits = Num2Bits(4); countBits.in <== numAssets;
    component countMin = LessThan(4); countMin.in[0] <== 1; countMin.in[1] <== numAssets; countMin.out === 1;
    component countMax = LessThan(4); countMax.in[0] <== numAssets; countMax.in[1] <== 9; countMax.out === 1;
    component validAsset = LessThan(8); validAsset.in[0] <== asset; validAsset.in[1] <== numAssets; validAsset.out === 1;
    publicAmount * (asset - publicAsset) === 0;      // asset is revealed only when value crosses the boundary
    component slot[nIn];
    var sumIn = 0;
    for (var i = 0; i < nIn; i++) {
        slot[i] = InputSlot(depth, i);
        slot[i].ak <== keys.ak; slot[i].nk <== keys.nk;
        slot[i].noteDomain <== noteDomain; slot[i].root <== root;
        slot[i].enabled <== inEnabled[i]; slot[i].value <== inValue[i];
        slot[i].d <== inD[i]; slot[i].rseed <== inRseed[i];
        for (var h = 0; h < depth; h++) { slot[i].pathElements[h] <== inPath[i][h]; slot[i].pathBits[h] <== inBits[i][h]; }
        slot[i].dummySeed <== inDummySeed[i];
        slot[i].asset <== asset;
        nf[i] === slot[i].nf;
        sumIn += inValue[i];
    }
    sumIn + publicAmount === 0;
    signal extSq;
    extSq <== extHash * extHash;
}

// TRANSFER_2_4_DIRECT: spend + immediate insertion of the transaction's own entry at an idle queue,
// optionally absorbing one pending deposit first. Z2 = empty 4-leaf subtree root.
template TransferDirect(depth, Z2) {
    signal input noteDomain;
    signal input numAssets;
    signal input root;
    signal input publicAmount;
    signal input publicAsset;
    signal input extHash;
    signal input nf[2];
    signal input cm[4];
    signal input newRoot;
    signal input ownIndex;
    signal input absorbIndex;
    signal input absorbPartial;
    signal input absorbValue;
    signal input absorbAsset;

    signal input sk;
    signal input asset;
    signal input inEnabled[2];
    signal input inValue[2];
    signal input inD[2];
    signal input inRseed[2];
    signal input inPath[2][depth];
    signal input inBits[2][depth];
    signal input inDummySeed[2];
    signal input outOwner[4];
    signal input outValue[4];
    signal input outRseed[4];
    signal input absorbSib[depth - 2];
    signal input ownSib[depth - 2];

    signal rootA;

    var E = depth - 2;
    // optional absorbed deposit (absorbPartial == 0 means none)
    component zAbs = IsZero(); zAbs.in <== absorbPartial;
    signal isAbs; isAbs <== 1 - zAbs.out;
    component absV = Num2Bits(128); absV.in <== absorbValue;
    component absA = Num2Bits(8);   absA.in <== absorbAsset;
    (1 - isAbs) * absorbIndex === 0;
    (1 - isAbs) * absorbValue === 0;
    (1 - isAbs) * absorbAsset === 0;
    component av0 = IsZero(); av0.in <== absorbValue; isAbs * av0.out === 0;
    component aValid = LessThan(8); aValid.in[0] <== absorbAsset; aValid.in[1] <== numAssets;
    isAbs * (aValid.out - 1) === 0;
    component depCm = TaggedPoseidon(3, T_CM());
    depCm.in[0] <== absorbPartial; depCm.in[1] <== absorbValue; depCm.in[2] <== absorbAsset;
    component depSub = SubtreeRoot();
    depSub.l[0] <== depCm.out; depSub.l[1] <== 0; depSub.l[2] <== 0; depSub.l[3] <== 0;
    component aBits = Num2Bits(E); aBits.in <== absorbIndex;
    component aOld = MerkleFold(E); component aNew = MerkleFold(E);
    aOld.leaf <== Z2; aNew.leaf <== depSub.root;
    for (var h = 0; h < E; h++) {
        aOld.sib[h] <== absorbSib[h]; aOld.bits[h] <== aBits.out[h];
        aNew.sib[h] <== absorbSib[h]; aNew.bits[h] <== aBits.out[h];
    }
    isAbs * (aOld.root - root) === 0;                 // absorbed slot was empty under the anchor
    rootA <== root + isAbs * (aNew.root - root);

    component t = Transfer(2, 4, depth);
    t.noteDomain <== noteDomain; t.numAssets <== numAssets; t.root <== rootA; t.publicAmount <== publicAmount;
    t.publicAsset <== publicAsset; t.extHash <== extHash; t.sk <== sk; t.asset <== asset;
    for (var i = 0; i < 2; i++) {
        t.nf[i] <== nf[i]; t.inEnabled[i] <== inEnabled[i]; t.inValue[i] <== inValue[i]; t.inD[i] <== inD[i];
        t.inRseed[i] <== inRseed[i]; t.inDummySeed[i] <== inDummySeed[i];
        for (var h = 0; h < depth; h++) { t.inPath[i][h] <== inPath[i][h]; t.inBits[i][h] <== inBits[i][h]; }
    }
    for (var j = 0; j < 4; j++) {
        t.cm[j] <== cm[j]; t.outOwner[j] <== outOwner[j]; t.outValue[j] <== outValue[j]; t.outRseed[j] <== outRseed[j];
    }


    // own entry
    component ownSub = SubtreeRoot();
    for (var j = 0; j < 4; j++) { ownSub.l[j] <== cm[j]; }
    component oBits = Num2Bits(E); oBits.in <== ownIndex;
    component order = LessThan(E); order.in[0] <== absorbIndex; order.in[1] <== ownIndex;
    isAbs * (order.out - 1) === 0;
    component oOld = MerkleFold(E); component oNew = MerkleFold(E);
    oOld.leaf <== Z2; oNew.leaf <== ownSub.root;
    for (var h = 0; h < E; h++) {
        oOld.sib[h] <== ownSib[h]; oOld.bits[h] <== oBits.out[h];
        oNew.sib[h] <== ownSib[h]; oNew.bits[h] <== oBits.out[h];
    }
    oOld.root === rootA;                              // own slot empty after the absorb step
    oNew.root === newRoot;
}
```


### B.3 Authenticated batch insertion

Save this block as `circuits/batch.circom`.

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
    for (var j = 0; j < 4; j++) { bW[j] = BEBits(254, 32); bW[j].in <== w[j]; }
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
    component f[9];
    f[0] = BEBits(8, 32);   f[0].in <== circuitId;
    f[1] = BEBits(254, 32); f[1].in <== oldRoot;
    f[2] = BEBits(254, 32); f[2].in <== newRoot;
    f[3] = BEBits(30, 32);  f[3].in <== start;
    f[4] = BEBits(8, 32);   f[4].in <== k;
    f[5] = BEBits(253, 32); f[5].in <== accStart;
    f[6] = BEBits(253, 32); f[6].in <== accEnd;
    f[7] = BEBits(132, 32); f[7].in <== baseTipSum;
    f[8] = BEBits(160, 32); f[8].in <== beneficiary;
    component sha = Sha256(2816);
    for (var p = 0; p < 256; p++) { poolIdBits[p] * (poolIdBits[p] - 1) === 0; sha.in[p] <== poolIdBits[p]; }
    for (var p = 0; p < 256; p++) { chainIdBits[p] * (chainIdBits[p] - 1) === 0; sha.in[256 + p] <== chainIdBits[p]; }
    for (var q = 0; q < 9; q++) { for (var p = 0; p < 256; p++) { sha.in[512 + q * 256 + p] <== f[q].out[p]; } }
    component hs = H253FromDigest();
    for (var p = 0; p < 256; p++) { hs.digest[p] <== sha.out[p]; }
    hs.out === statement;
}
```


### B.4 Main: transfer24

Save this block as `circuits/main_transfer24.circom`.

```circom
pragma circom 2.1.9;
include "transfer.circom";
component main {public [noteDomain, numAssets, root, publicAmount, publicAsset, extHash, nf, cm]} = Transfer(2, 4, 32);
```


### B.5 Main: transfer84

Save this block as `circuits/main_transfer84.circom`.

```circom
pragma circom 2.1.9;
include "transfer.circom";
component main {public [noteDomain, numAssets, root, publicAmount, publicAsset, extHash, nf, cm]} = Transfer(8, 4, 32);
```


### B.6 Main: exit

Save this block as `circuits/main_exit.circom`.

```circom
pragma circom 2.1.9;
include "transfer.circom";
component main {public [noteDomain, numAssets, root, publicAmount, publicAsset, extHash, nf]} = Exit(2, 32);
```


### B.7 Main: batch1

Save this block as `circuits/main_batch1.circom`.

```circom
pragma circom 2.1.9;
include "batch.circom";
component main {public [statement]} = BatchInsert(1, 8508108280010681241885759795573805045462523017836069467999300010978555398910);
```


### B.8 Main: batch16

Save this block as `circuits/main_batch16.circom`.

```circom
pragma circom 2.1.9;
include "batch.circom";
component main {public [statement]} = BatchInsert(16, 8508108280010681241885759795573805045462523017836069467999300010978555398910);
```


### B.9 Main: direct

Save this block as `circuits/main_direct.circom`.

```circom
pragma circom 2.1.9;
include "transfer.circom";
component main {public [noteDomain, numAssets, root, publicAmount, publicAsset, extHash, nf, cm, newRoot, ownIndex, absorbIndex, absorbPartial, absorbValue, absorbAsset]} = TransferDirect(32, 8508108280010681241885759795573805045462523017836069467999300010978555398910);
```


## Appendix C: Reference encoding and tree utilities

This is a **non-constant-time development reference**, adapted from the source's JavaScript model. It is not a production wallet. It covers derivation, note encryption/opening, the tree, accumulator, and body encodings. Address-decoder hardening, outgoing-recovery implementation, authenticated chain synchronization, secure backup, and full user flows remain implementation tasks governed by the main specification. Encrypted round trips and Poseidon vectors are not verified by this specification.

Candidate dependencies, inherited from the supplied reference interface: `circomlibjs@0.1.7`, `@noble/curves@1.6.0`, `@noble/hashes@1.5.0`, `@noble/ciphers@1.0.0`, and an explicitly pinned `ethers` 5 release. These are compatibility inputs, not a claim that the versions are current or approved for production. Perform dependency/security review and commit a lockfile. Do not silently upgrade cryptographic behavior under the same release manifest.


### C.1 `seth7.js`

Save this block as `ref/seth7.js`.

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
const VERSION = 7;
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
  const prk = extract(sha256, seed, sha256(utf8("ShieldedETH/v0.7/wallet")));
  let sk, ivk;
  for (let c = 0; ; c++) { sk = toBig(expand(sha256, prk, cat(utf8("sk/"), beN(c, 4)), 32)); if (sk >= 1n && sk < r) break; }
  for (let c = 0; ; c++) { ivk = toBigLE(expand(sha256, prk, cat(utf8("ivk/"), beN(c, 4)), 64)) % L25519; if (ivk !== 0n) break; }
  const ovk = expand(sha256, prk, utf8("ovk"), 32);
  return { sk, ak: P(T.AK, sk), nk: P(T.NK, sk), ivk, ovk };
}
const baseFor = (d) => RistrettoPoint.hashToCurve(sha512(cat(utf8("SETH/v7/div"), d)));
function address(keys, d, poolId) {
  if (d.length !== 11 || poolId.length !== 32) throw Error("address inputs");
  const Hd = baseFor(d), pkd = Hd.multiply(keys.ivk);
  if (Hd.equals(RistrettoPoint.ZERO) || pkd.equals(RistrettoPoint.ZERO)) throw Error("identity point");
  const owner = P(T.OWNER, keys.ak, toBig(d));
  const payload = cat(Uint8Array.of(VERSION), poolId.slice(0, 8), d, beN(owner, 32), pkd.toRawBytes());
  const check = sha256(cat(utf8("SETH/v7/address"), payload)).slice(0, 8);
  return { d, owner, pkd, Hd, text: "seth7:" + b64u(cat(payload, check)) };
}

// ---------- notes ----------
const partialOf = (owner, rseed) => P(T.PART, owner, rseed);
const cmOf = (partial, value, asset) => P(T.CM, partial, value, BigInt(asset));
const nfReal = (noteDomain, nk, cm, pos) => P(T.NF, noteDomain, nk, cm, BigInt(pos));
const nfDummy = (noteDomain, seed, slot) => P(T.DUMMY, noteDomain, seed, BigInt(slot));

// ---------- delivery (109-byte recipient ciphertext) ----------
function eskOf(poolId, rseed) {
  for (let c = 0; ; c++) { const e = toBigLE(sha512(cat(utf8("SETH/v7/esk"), poolId, beN(rseed, 32), beN(c, 4)))) % L25519; if (e) return e; }
}
function seal(poolId, addr, value, asset, rseed, cm) {
  if (value < 0n || value >= (1n << 128n) || !Number.isInteger(asset) || asset < 0 || asset >= 8 || rseed <= 0n || rseed >= r || cm <= 0n || cm >= r) throw Error("note range");
  if (cmOf(partialOf(addr.owner, rseed), value, asset) !== cm) throw Error("note commitment mismatch");
  const esk = eskOf(poolId, rseed), epk = addr.Hd.multiply(esk), ss = RistrettoPoint.fromHex(addr.pkd.toRawBytes()).multiply(esk);
  const ctx = cat(Uint8Array.of(VERSION), poolId, beN(cm, 32), epk.toRawBytes());
  const m = expand(sha256, extract(sha256, ss.toRawBytes(), sha256(utf8("SETH/v7/note"))), ctx, 44);
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
    const m = expand(sha256, extract(sha256, ss.toRawBytes(), sha256(utf8("SETH/v7/note"))), ctx, 44);
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
const acc0Of = (poolId) => H253(sha256(cat(utf8("SETH/v7/acc"), poolId)));
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
const BODY_TAG = ethers.utils.keccak256(utf8("SETH/v7/BODY"));
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

module.exports = { init, r, L25519, T, KIND, CIRCUIT, VERSION, P, walletKeys, address, partialOf, cmOf, nfReal, nfDummy, seal, open,
  poolIdOf, noteDomainOf, acc0Of, recordBytes, accStep, leavesOf, zeros, Tree, fold, batchStatement, canonicalBody,
  extHashOf, nextBatch, canonicalDirectBody, pendingHash, DIRECT_CONTEXT, PENDING_RECORD, TRANSFER_BODY, EXIT_BODY, DEPOSIT_BODY, beN, toBig, hex, cat, utf8, H253 };
```


## Appendix D: Fail-closed tests and build procedure

### D.1 Expectation helper

Every call must be awaited. A missing compiler output, unavailable process, timeout, or unknown diagnostic is an infrastructure failure, not a successful negative test. Review the precise recognized constraint-error diagnostics against the pinned tools. Tests must deliberately demonstrate that inverting an honest/invalid expected result fails the process.


### D.1.1 `circuit_expectations.js`

Save this block as `ref/circuit_expectations.js`.

```javascript
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
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "seth7-witness-"));
  let accepted = false;
  let reason = "";
  try {
    let bin;
    try { bin = await wc.calculateWTNSBin(input, 0); }
    catch (err) {
      if (!/Assert Failed/i.test(String(err))) throw err;
      reason = "constraint assertion";
    }
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
```


### D.2 Required build and integration sequence

1. Extract the source blocks into the displayed relative paths; review the code changes against the original files and record their hashes.
2. Pin and obtain Circom, circomlib, solc, snarkjs, the reference dependencies, and a current-fork EVM/client in an isolated build environment. Verify provenance and dependencies. The embedded source candidates have no accompanying compilation evidence.
3. Compile all six production-depth mains. Save R1CS, symbols, witness generator, compiler output, public-input ordering, and constraint count. No extrapolated `BATCH_UPTO_16` build satisfies this step.
4. Compile the pool with solc 0.8.26, `viaIR: true`, optimizer enabled with 200 runs, and a compatible EVM revision as a candidate starting profile. Check errors, warnings, deployed runtime size, storage layout, and all external interfaces. These flags are not measured performance claims.
5. Generate fresh deterministic test vectors and independent reference outputs for v7. Never relabel v5/v6 vectors as v7 vectors.
6. In a development-only environment, generate throwaway setup artifacts for every circuit and export its actual verifier. Make it impossible to confuse development keys with production ceremony artifacts.
7. Assert honest and malicious witness cases, then run **real proofs through the actual generated verifier** and the pool in isolated per-transaction EVM contexts. `runCall` fragments and mocks do not replace complete transaction tests. Reset access/warmth/transient state correctly between transactions.
8. Run the complete first-token-deposit → direct spend of that deposit → onward payment → withdrawal transaction sequence. Test mixed-asset rejection, changed reward beneficiary, stale context, token no-op/fee behavior, queue wrap, high positions, and all capacity boundaries.
9. Run property/state-machine tests with an independent plaintext ledger and every required negative case in §16. Fail CI if a case is skipped, misclassified, or unexpectedly passes/fails.
10. Only after independent reviews and the final circuit freeze, perform production ceremonies and build the release manifest. Recompile/review every source change made after any earlier test run.

Example compilation commands, **not executed for this revision**:

```bash
mkdir -p circuits/build
for name in transfer24 transfer84 exit batch1 batch16 direct; do
  circom "circuits/main_${name}.circom" --r1cs --wasm --sym -o circuits/build
done
# Use solc's standard-JSON interface with the explicitly pinned settings above.
# Generate and export each DEVELOPMENT verifier from its actual development zkey.
# Production ceremony steps are a separate reviewed release operation.
```

### D.3 Limited checks actually run while preparing these documents

The following are the complete scope of the new executed evidence:

| Check | Result | Does not establish |
|---|---|---|
| E1 Python format/economic helper suite | 20 unit tests passed | Wallet security, mining profitability, or a working broadcaster |
| Static source-string and arithmetic checks | 21 checks passed, including 1,280 queue-scheduling cases | Compilation, circuit satisfiability, proof binding, EVM state correctness, or protocol safety |
| `node --check` on `seth7.js` and the expectation helper | Syntax accepted | Dependencies loading, runtime execution, correct cryptography, or passing witness tests |
| Solidity / Circom / full E2 integration | **Not run** | No new gas, runtime-size, constraint-count, or proof-time result exists |

The source-string checks only confirm that intended expressions are present. They cannot prove those expressions are sufficient or that the implementation is correct.


### D.3.1 Static/arithmetic check script

Save this block as `tests/check_spec.py`.

```python
"""Limited static/arithmetic checks. Not Solidity/Circom compilation or proof verification."""
from pathlib import Path
import json,re
B=Path(__file__).resolve().parents[1]
checks=[]
def ok(name,predicate):
    if not predicate: raise AssertionError(name)
    checks.append(name)
contract=(B/'contracts/ShieldedETHPool.sol').read_text()
circuit=(B/'circuits/transfer.circom').read_text()
batch=(B/'circuits/batch.circom').read_text()
kernel=(B/'contracts/XmrSwapKernel.sol').read_text()
ref=(B/'ref/seth7.js').read_text()
ok('multi-asset constructor requires two through eight', 'if (n < 2 || n > MAX_ASSETS' in contract)
ok('direct spend is wired to intermediate root', 't.root <== rootA' in circuit and 't.root <== root;' not in circuit)
ok('direct reward uses authorized beneficiary', '_markInserted(end, knownAcc(end), d.newRoot, true, reward, d.rewardBeneficiary, 1)' in contract)
ok('direct context enters canonical body', 'block.chainid, uint128(0), b, d)' in contract)
ok('asset-count validation is explicit', 'validAsset.out === 1' in circuit and 't.numAssets <== numAssets' in circuit)
ok('batch full chain-id bits', 'chainIdBits[256]' in batch and 'BEBits(64, 32)' not in batch)
ok('batch field array has nine elements', 'component f[9];' in batch)
ok('batch tip sum width 132', 'BEBits(132, 32)' in batch)
ok('token recipient-credit delta checked', 'r1 - r0 != amount' in contract)
ok('token sender-debit delta checked', 's1 != s0 - amount' in contract)
ok('cap has permanent ceiling', 'return scheduled < ceiling ? scheduled : ceiling' in contract)
ok('kernel verifies v7 and native asset', 'pool_.VERSION() != 7' in kernel and 'pool_.assetToken(0) != address(0)' in kernel)
ok('kernel delivery plan binds full identity and native asset', 'p.poolId != poolId || p.asset != 0' in kernel)
ok('kernel uses new native deposit signature', '(0, p.partialCommitment, p.D, ciphertext)' in kernel)
ok('kernel later-block settlement guard', 'block.number <= s.claimBlock' in kernel)
ok('reference avoids signed Number shifts for tree', 'i >>= 1' not in ref and 'i ^ 1' not in ref)
# Arithmetic: endpoint retention for every start residue and a range of backlogs.
for s in range(128):
    for gap in (1,2,15,16,17,1023,1024,1040,4097):
        n=s+gap; end=min(n,16*(s//16+1)); k=end-s
        assert 1<=k<=16 and (end==n or end%16==0)
ok('scheduler endpoints for 1,280 cases',True)
s,n=1,1041; steps=0
while s<n:
    s=min(n,16*(s//16+1));steps+=1
ok('old dead-end drains in finite steps',s==1041 and steps==66)
for pos in (0,1,(1<<31)-1,1<<31,(1<<32)-1):
    i=pos; bits=[]
    for _ in range(32):
        sibling=i+1 if i%2==0 else i-1
        assert sibling>=0
        bits.append(i%2);i//=2
    assert sum(b<<h for h,b in enumerate(bits))==pos and i==0
ok('unsigned 32-bit path boundaries',True)
ok('deposit ABI size is 292',4+4*32+32+128==292)
for p,expected in [(12,254800),(18,291700),(8,230200),(1,187150)]:assert 181000+6150*p==expected
ok('verifier arithmetic formulas',True)
print(json.dumps({'status':'passed','checks':len(checks),'scope':'static source strings and arithmetic only; not compiler, EVM, cryptographic or production tests','details':checks},indent=2))
```

### D.3.2 Recorded limited-check summary

```json
{
  "status": "passed",
  "checks": 21,
  "scope": "static source strings and arithmetic only; not compiler, EVM, cryptographic or production tests",
  "details": [
    "multi-asset constructor requires two through eight",
    "direct spend is wired to intermediate root",
    "direct reward uses authorized beneficiary",
    "direct context enters canonical body",
    "asset-count validation is explicit",
    "batch full chain-id bits",
    "batch field array has nine elements",
    "batch tip sum width 132",
    "token recipient-credit delta checked",
    "token sender-debit delta checked",
    "cap has permanent ceiling",
    "kernel verifies v7 and native asset",
    "kernel delivery plan binds full identity and native asset",
    "kernel uses new native deposit signature",
    "kernel later-block settlement guard",
    "reference avoids signed Number shifts for tree",
    "scheduler endpoints for 1,280 cases",
    "old dead-end drains in finite steps",
    "unsigned 32-bit path boundaries",
    "deposit ABI size is 292",
    "verifier arithmetic formulas"
  ]
}
```

### D.4 Original source identities

| Source attachment | SHA-256 of original bytes |
|---|---|
| `ShieldedETH_v0_5_Core.md` | `0c0cf6602c5bcbd51914e6e82b1d8af3838dc4902da43ebd55ce49d27476a784` |
| `ShieldedETH_v0_6_Core_Delta.md` | `3fb0b126eddf355314f3fb05f876ed374a9c1fac682c9ae3808529330772ef2e` |
| `ShieldedETH_v0_5_E1_Capacity.md` | `97b37cca87a4faa328163f26a855b51ce000f2bd9152b324c900cfbf98271ce3` |
| `ShieldedETH_v0_5_E2_XMR_Settlement.md` | `b7eadf08cace609d4479b3d4311adf51ca09b3c4667ec24cd0b2e6779f6f90b0` |

These hashes identify the exact supplied inputs used for this revision. They are not code signatures, audit approvals, or evidence of safe deployment.
