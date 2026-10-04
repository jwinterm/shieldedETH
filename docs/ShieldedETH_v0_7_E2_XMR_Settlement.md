# ShieldedETH v0.7: Extension E2: XMR → Shielded ETH Settlement

> Historical v0.7 specification. The [current v0.8 specification](ShieldedETH_v0_8_Core_Delta.md) governs the executable implementation, production requirements and measured evidence. Embedded source candidates and proposed tests are retained for reference.

**Status:** Independently gated cross-chain engineering specification with an ETH-side kernel candidate. Not an audited swap system, not a Monero implementation, and not authorization to trade with real funds.  
**Depends on:** [ShieldedETH v0.7 Core](ShieldedETH_v0_7_Core.md), specifically its immutable native-ETH asset 0 and `deposit()` interface. [E1](ShieldedETH_v0_7_E1_Capacity.md) can present this route after E2 activation.  
**Supersedes:** `ShieldedETH_v0_5_E2_XMR_Settlement.md` and the v0.6 two-line integration note. Versioned keys, ciphertexts, signatures, and end-to-end tests must all be updated, not just the deposit selector.


## Contents

- [0. Decisions and evidence](#0-decisions-and-evidence)
- [1. Roles, keys, and custody boundaries](#1-roles-keys-and-custody-boundaries)
- [2. Candidate cryptographic profile](#2-candidate-cryptographic-profile)
- [3. Quotes and pre-funding agreement](#3-quotes-and-pre-funding-agreement)
- [4. State machine and transaction sequence](#4-state-machine-and-transaction-sequence)
- [5. ETH kernel, typed authorizations, and accounting](#5-eth-kernel-typed-authorizations-and-accounting)
- [6. Two-stage settlement and fallback](#6-two-stage-settlement-and-fallback)
- [7. Symmetric deadlines and secret exposure](#7-symmetric-deadlines-and-secret-exposure)
- [8. Monero lock validation and recovery journal](#8-monero-lock-validation-and-recovery-journal)
- [9. Fees, minimum sizes, and funding choices](#9-fees-minimum-sizes-and-funding-choices)
- [10. Privacy and operational disclosures](#10-privacy-and-operational-disclosures)
- [11. Required tests](#11-required-tests)
- [12. Activation gates and deployment manifest](#12-activation-gates-and-deployment-manifest)
- [13. Source provenance and external references](#13-source-provenance-and-external-references)
- [Appendix A: ETH-side kernel implementation candidate](#appendix-a-eth-side-kernel-implementation-candidate)
- [Appendix B: Executable integration-suite requirements](#appendix-b-executable-integration-suite-requirements)


## 0. Decisions and evidence

### 0.1 Relationship to multi-asset Core

The core supports 2–8 assets. **E2's first profile settles only native ETH, asset ID 0.** It does not custody XMR in the pool, mint wrapped XMR, or convert XMR directly into DAI/LUSD/share-token notes. A further asset exchange would require a separate reviewed operation and its own fees/privacy disclosure. Do not market the core's multi-asset capability as an already implemented cross-chain swap for every asset.

A user can receive an ETH note through E2, then pay an ordinary broadcaster with an ETH fee note for later ETH payments. A user wishing to hold another asset needs an independently selected conversion route; E2 does not silently authorize it.

### 0.2 Revisions to the source design

| Area | v0.7 requirement |
|---|---|
| Core interface | Pin Core VERSION 7, full poolId, and asset 0 native ETH; 109-byte v7 ciphertext |
| Funding terms | Store immutable swap-profile identity and a terms digest; bind them into swap identity |
| Claim | Secret check and internal backed credit only; no pool or recipient call |
| Delivery | Separate beneficiary-authorized deposit operation; canonical native-asset plan |
| Same-transaction delivery | Record claim block and require settlement in a later block; wallet still waits for its stronger finality policy |
| Deadlines | Symmetric claim **and refund** secret-exposure rules; explicit provider monitoring of Funded swaps |
| Recovery | Independent encrypted swap journal with irreversible secret-exposure flags |
| Monero compatibility | Version/network/output-type evidence gate, not an assumed calendar date for FCMP++/Carrot |
| Evidence | No inherited kernel gas/runtime or test result is a v0.7 measurement |

The shared-key construction is based on the supplied E2 and the Athanor-style reference described there. Changes above are proposed v0.7 decisions. The exact Monero implementation and cross-curve proof profile remain independent release blockers. [S-E2; R-ATHANOR]

### 0.3 What the two-stage design does and does not guarantee

1. **Conditional exchange:** under the chosen key/profile, chain, timing, monitoring, and transaction-inclusion assumptions, the claim/refund secrets enable the corresponding counterparty to complete its leg.
2. **Durable committed entitlement:** after an ETH claim is accepted in the selected canonical history, pool-deposit failure cannot return that credit to the provider.
3. **Delivery:** the beneficiary can retry an authorized native-ETH deposit or withdraw credit publicly. Delivery can be delayed and remains subject to fees, inclusion, and core availability.

These are different guarantees. A mempool secret, an executed inner call later reverted by an outer call, or a reorganized claim is not a finalized credit. A queued pool deposit is not yet an ordinary spendable note. “Atomic” must not be used to imply no timeouts, no monitoring, no counterparty metadata, or guaranteed economics for tiny swaps.

## 1. Roles, keys, and custody boundaries

| Role | Holds/does | Must not receive |
|---|---|---|
| U: XMR holder | XMR, per-swap secret share, beneficiary authorization key, fresh core receiving address, journal | None |
| P: ETH provider | ETH escrow/operating float, per-swap secret share, verified XMR lock data | U's main Monero spend key or core seed/sk/ivk/ovk |
| Claim/settlement relayer | ETH float, public swap state, authorized fee plan, eventually broadcast secret | Secret before necessary execution; unrelated wallet keys |
| Watchtower | Only explicitly delegated monitoring/recovery material | Implied access to all main-wallet keys |
| Kernel | ETH escrow and ETH credits; secret/signature checks | No XMR keys, no Monero consensus verification, no core spending authority |
| Core pool | Ordinary asset-0 deposit and later private spending | No special swap role |

The beneficiary EVM key controls credit authorizations and can have zero ETH. It is distinct from both the cross-chain secret and the private-payment spend key. Each swap uses fresh independent keys. Never reuse a Monero shared-lock address across swaps.

## 2. Candidate cryptographic profile

### 2.1 Profile identity and activation

Call the candidate `E2-SHAREDKEY-7`. A kernel deployment pins a nonzero `profileId`, the digest of a reviewed profile manifest. That manifest fixes the Monero network/output classes, wallet/node versions, DLEQ implementation and transcript, scalar/point encoding, confirmation rules, and all key/lock validation steps.

Pinning a digest does not prove the Monero side on-chain. Both peers must actually verify it and perform the corresponding off-chain checks. A profile or Monero compatibility change requires explicit new profile approval; existing kernel credits remain ordinary ETH obligations and do not depend on future Monero support.

### 2.2 Secret shares and shared Monero address

For the legacy-style candidate only:

```text
ell = 2^252 + 27742317777372353535851937790883648493
U chooses s_u uniformly from [1,ell)
P chooses s_p uniformly from [1,ell)
S_u = [s_u] B          # canonical Monero/Edwards prime-subgroup point
S_p = [s_p] B
S = S_u + S_p
Q_u = [s_u] G          # secp256k1
Q_p = [s_p] G
claimKey  = address(Q_u)
refundKey = address(Q_p)
```

Reject identity/small-order/noncanonical points and an identity combined spend key. The eventual combined spend scalar is `(s_u+s_p) mod ell`; never substitute scalar addition modulo secp256k1's order for the Monero spend relation.

Both parties need shared per-swap viewing material to verify outputs. The profile must define its exact construction. A candidate is independent nonzero view shares exchanged over an authenticated encrypted channel, summed modulo ell, with identity sum rejected. No view secret is derived by disclosing a main wallet's spend material. The final address must be generated/validated by the pinned Monero implementation, including its network and output-key rules.

Core's ristretto255 encoding is **not** a Monero address or proof format. Equal underlying group order is not interchangeability of encodings, transcript rules, or spend-authority semantics. [R-RISTRETTO]

### 2.3 Cross-curve proof

Each party proves that its Edwards/Monero point and full secp256k1 point represent the same integer secret in the accepted common range. Verify both proofs before either asset is committed irreversibly. Candidate references include the cross-group DLEQ work identified in the supplied E2; this document does not implement that proof.

The profile must pin: generators, point validation, integer range proof, challenge hash, transcript encoding/domain separation, proof serialization, and association with parties/roles and signed swap terms. If the selected library has no context field, the profile must specify a reviewed signed transcript-binding wrapper rather than assume replay protection the library does not supply.

Compare the Ethereum address derived from the **same verified full secp256k1 point** with the kernel's stored key. Reject swapped roles, mismatched addresses, reused transcripts in an incompatible context, invalid subgroup points, and zero/out-of-range secrets.

A “similar DLEQ library” is not a completed profile. E2-G0 must approve exact source commits and positive/negative vectors.

### 2.4 Ethereum secret check

The ETH-side candidate verifies the Ethereum address of `[s]G` using the `ecrecover` identity:

```text
h = 0
R = G with even y; v = 27
rSig = Gx
sSig = s * Gx mod n
recovered = ecrecover(h, v, rSig, sSig) = address([s]G)
```

Check `1<=s<ell`, recovered address nonzero, and equality with the stored claim/refund key. The synthetic signature used for this mathematical check is not a user authorization signature; do not apply the user-signature low-s restriction to `sSig`. User EIP-712 signatures separately enforce low-s and valid v.

This is an Ethereum address equality check, not an on-chain DLEQ proof or Monero amount verifier. The cross-curve proof and point-to-address association remain peer-verification obligations.

### 2.5 Monero network changes

The source discusses FCMP++/Carrot. This revision deliberately makes **no assertion of an activation date or current mainnet status**. Before opening a swap, the client checks a maintained compatibility manifest for the selected network and actual node/wallet behavior.

For any changed output/spend model, prove that the secret disclosed by claim or refund still completes the necessary spend authority. Test funding, recognition, amount verification, unlocking, recovery, key-image/spend construction, and reorg behavior with actual supported software. Legacy wallet import success is not sufficient evidence.

If compatibility is unknown or the network is crossing an unreviewed upgrade window, stop opening new swaps and preserve existing recovery paths. An updated profile is separately versioned and reviewed; do not silently relabel it `E2-SHAREDKEY-7`.

## 3. Quotes and pre-funding agreement

### 3.1 Required quote content

The authenticated off-chain agreement binds:

- full kernel address, code/profile IDs, pool address/full poolId/version, Ethereum chain and Monero network;
- provider and beneficiary identities, verified claim/refund full public keys and Ethereum addresses;
- XMR lock amount/output policy and native ETH escrow amount;
- both Ethereum deadlines `tA<tB`, safe-broadcast margins, confirmation/finality policy, and monitoring responsibilities;
- claim, settlement, and fallback fee budgets and reserved credit;
- user-chosen asset-0 note partial, expected commitment, ciphertext digest, and versioned delivery intent, or an explicit rule allowing the beneficiary to finalize that destination later;
- provider spread, XMR/network fee treatment, quote expiry, and abort/refund conditions;
- an independent random salt and terms digest.

Store the full agreement in both journals before funding. The kernel stores `termsHash` and includes it and `profileId` in the swap ID. It does not execute every off-chain commercial term or verify the XMR leg merely because the digest exists.

### 3.2 Native settlement arithmetic

```text
E_locked = F_claim + D + tip + F_settle + reserve
```

All terms here are integer wei. Fallback instead debits its chosen public amount plus its authorized fee from remaining credit. Fees are distinct; the UI must not add claim or settlement costs twice. The provider's funding transaction fee and spread can be priced into the exchange quote, but are not secretly taken by the kernel.

The user creates destination material locally using Core v0.7 with `asset=0`. A provider may know the quote and receiving address, but must not choose an unrelated or unopenable destination for the user.

## 4. State machine and transaction sequence

### 4.1 Kernel states

`None → Funded → Ready (optional) → Claimed`, or `Funded/Ready → Refunded` under the permitted times. Claimed and Refunded are terminal exchange states; credit consumption is separate accounting, not a return to Funded.

| Current state | Action | Authorized actor | Time condition |
|---|---|---|---|
| None | fund | Provider supplying ETH | now < tA < tB |
| Funded | markReady | Provider | now < tA |
| Funded | claimToCredit | Beneficiary or authorized relayer | tA <= now < tB |
| Ready | claimToCredit | Beneficiary or authorized relayer | now < tB |
| Funded | refundToCredit, early | Provider | now < tA |
| Funded or Ready | refundToCredit, late | Provider | now >= tB |
| Claimed or Refunded | Any further claim/refund | Nobody | Reject |

**MONITOR-01.** Even without Ready, U can claim from tA. P must monitor and complete a safe early refund if valid XMR never arrives. Ready is not an on-chain proof of Monero payment.

### 4.2 Successful flow

1. Peers validate the profile, keys, DLEQ, terms, and recovery journals.
2. P funds the correct immutable kernel with agreed ETH.
3. U authenticates the funded state, amount, keys, beneficiary, profile/terms, and remaining time after its ETH confirmation policy.
4. U locks agreed XMR to the validated shared address and records exact outputs.
5. P independently verifies actual locked value, output ownership under the profile, confirmation depth, unlock/spendability rules, and deadline margin. It may markReady before tA.
6. U creates a safe, authorized claim submission. Revealing `s_u` enables P to derive the XMR spend secret; treat it as irreversible disclosure before receipt.
7. A canonical claim moves ETH into beneficiary credit and fee credit without external calls.
8. After a later block and the user's stronger finality policy, U authorizes a separate pool deposit.
9. A successful Core deposit creates a queued ETH note. Normal batch insertion or eligible Core direct spending makes it usable under the relevant relation.
10. P completes its XMR spend and both peers retain reconciled journals until their recovery policies permit deletion.

Each party follows its own authenticated chain views. The Monero leg is not complete merely because the counterparty supplied a transaction ID.

### 4.3 Local state includes exposure, not only receipts

Wallet journals track at least: prepared; ETH funded/confirmed; XMR locked/confirmed; Ready seen; user-secret exposed; provider-secret exposed; claim committed; refund committed; ETH credit remaining; pool queued; inserted; completed/aborted/recovery.

Exposure flags are monotonic. A revert or reorg may roll back chain state, but never resets “secret was shared with a relayer/mempool.” This distinction is essential to recovery.

## 5. ETH kernel, typed authorizations, and accounting

### 5.1 Fixed deployment

The candidate kernel pins a Core v7 address, its full poolId, and one nonzero profileId. Constructor validation checks code presence, core VERSION, and asset 0 native ETH. The wallet additionally verifies runtime and deployment hashes against the profile. No owner, upgrade, pause, sweep, or arbitrary-call function is provided.

A changed core deployment requires a new kernel or separately reviewed migration route. A v5/6 pool with a similar selector is not accepted as v7.

### 5.2 Swap identity

```text
swapId = keccak256(abi.encode(
    currentChainId, kernelAddress, provider, beneficiary,
    claimKey, refundKey, tA, tB, amountWei, salt,
    profileId, termsHash))
```

The stored swap includes provider, beneficiary, claim/refund key addresses, deadlines, amount, stage, termsHash, and claimBlock. Profiles/salts/terms prevent accidental identity reuse but cannot prove XMR exists.

### 5.3 EIP-712 types

Domain: name `ShieldedETH XMR Kernel`, version `7`, current chain ID, verifying kernel address. Recompute on chain-ID changes. [R-712]

```text
ClaimAuth(bytes32 swapId,uint128 fee,address feeRecipient,address executor,uint64 deadline)

DepositPlan(bytes32 swapId,bytes32 poolId,uint8 asset,uint64 nonce,
            uint256 partialCommitment,bytes32 ciphertextHash,
            uint128 D,uint128 tip,uint128 fee,address feeRecipient,
            address executor,uint64 deadline)

WithdrawAuth(bytes32 swapId,uint64 nonce,address to,uint128 amount,uint128 fee,
             address feeRecipient,address executor,uint64 deadline)
```

These exact type names, ordering, widths, and domains must be used by wallet and kernel. `asset` is required and must be 0; full `poolId` must match. Do not permit arbitrary token or pool selection through a delivery plan.

User signatures must be 65 bytes, canonical r/s, low-s, v 27/28, and recover the nonzero beneficiary. A directly calling beneficiary may authorize its own claim without a detached signature as shown in the candidate; relayable settlement and withdrawal require the beneficiary's signed plan.

`executor=0` permits any relay of the same authorized effect; nonzero binds submission. A copied claim cannot change its authorized fee/destination. A claim is one-shot per swap. Settlement and withdrawal share an ordered `creditNonce`; a changed plan does not cancel a still-valid older plan unless the nonce is consumed or it expires. The wallet must explicitly track those competing authorizations.

### 5.4 Backing and credits

```text
kernel ETH balance >= lockedTotal + userCreditTotal + addrCreditTotal
```

A claim:

```text
lockedTotal -= amount
userCredit[swapId] = amount - claimFee
userCreditTotal += amount - claimFee
addrCredit[feeRecipient] += claimFee
addrCreditTotal += claimFee
stage = Claimed
claimBlock = current block number
```

A refund moves the whole swap amount from lockedTotal into provider address credit and sets Refunded. Neither calls the provider, beneficiary, pool, token, or relayer.

Settlement consumes `D+tip+settlementFee` from user credit; fee becomes address credit; `D+tip` goes to Core. Public withdrawal consumes `amount+fee`; fee becomes address credit and the amount goes to the signed destination. Failed settlement/withdrawal reverts its credit/nonce changes. Address-credit claims are pull-only and debit before sending.

Use checked arithmetic. Per-swap amounts fit uint128; aggregates use uint256. Forced ETH is unowned surplus and does not create withdrawable credit. No one can seize another swap's credit, and credit does not expire merely because tB has passed.

## 6. Two-stage settlement and fallback

### 6.1 Stage A: claim to durable credit

**SWAP-01.** The authorized claim transaction targets the kernel's claim entry point and must not be wrapped with optional pool delivery or other failure-prone work. The claim does bounded validation, secret checking, internal accounting, and events only.

Once accepted on the canonical chain, a later failed pool call cannot reverse that credit. However, insufficient gas, invalid signatures, expiry, changed stage, an enclosing outer revert, or reorganization can still prevent or remove claim acceptance while the secret is already known. The wallet must verify the exact outer transaction and retain an independently actionable recovery/claim plan.

The kernel cannot generally force an arbitrary caller's outer transaction not to revert after its inner call. A malicious secret-bearing relayer can also withhold or disclose information. Do not present the no-external-call kernel as eliminating adversarial inclusion or secret-delivery risks.

### 6.2 Stage B: native ETH deposit

After U's finality policy and in a strictly later block than `claimBlock`, the relayer submits the signed DepositPlan and its ciphertext. The kernel checks stage, poolId, `asset=0`, nonce, deadline, executor, 109-byte ciphertext length and exact hash, nonzero D, fee rules, and credit availability.

Then call:

```solidity
entry = pool.deposit{value: uint256(D) + tip}(0, partialCommitment, D, ciphertext);
```

If Core rejects capacity, admission cap, encoding, or any other condition, only Stage B reverts; user credit and its nonce remain unchanged. The later-block rule prevents accidental same-transaction claim/deposit composition. It is not Ethereum finality; clients must apply the chosen stronger policy.

Changing D, tip, fee, partial, ciphertext, deadline, or executor requires a fresh signed plan. The note ciphertext's asset must be 0 and its commitment must match locally; the kernel does not prove decryption correctness.

### 6.3 After deposit

Core returns a queued entry. Observe and authenticate its full body, amount, partial, ciphertext, asset, and position. Then:

- ordinary insertion can make it a recognized input;
- if the full pending prefix is eligible, Core's corrected direct proof can insert and spend this deposit under R1 while inserting its new outputs;
- a busy prefix or pending transfer entries require normal insertion first.

A swap provider or settlement relayer has no priority override in the pool. Fixed quotes must price insertion and future fee headroom realistically. A claim+settle receipt is not proof that the note was already inserted.

### 6.4 Public fallback

`withdrawCredit` accepts a beneficiary-signed destination, amount, fee, executor, nonce, and deadline. Reject zero/kernel destination, zero amount, oversized debit, and invalid fee recipient. Pay after debiting; a failed public payout preserves the credit.

Fallback gives up the shielded-deposit route and exposes its destination. It preserves an ETH entitlement under the kernel, not guaranteed liquidity or network inclusion. A zero-ETH beneficiary can use a willing relayer whose authorized fee comes out of the credit. No relayer is forced to accept a uneconomical dust amount.

## 7. Symmetric deadlines and secret exposure

### 7.1 Safety policies are profile parameters

```text
latestSafeClaimBroadcast       = tB - claimSafetyMargin
latestSafeEarlyRefundBroadcast = tA - earlyRefundSafetyMargin
```

Margins cover inclusion, replacement, congestion, clock/chain-view uncertainty, monitoring gaps, and selected reorg tolerance. No universal duration is declared safe. Store policy version and effective deadlines in both journals. Stop opening a swap when any required interval is already too short.

Late refunds must not be broadcast before an authenticated chain view permits them at `tB`; prepare locally without disclosing `s_p`. Apply the chosen reorg policy. A transaction reverting for being early can nevertheless expose the provider secret.

### 7.2 User claim rules

Before disclosing s_u, U verifies kernel code/profile/state/amount/beneficiary/key/time, actual XMR lock ownership/value/spendability, authorizations, gas funding, and simulation locally or without releasing the secret. Never reveal s_u merely to obtain a quote or remote preflight.

After the latest safe broadcast point, refuse a new secret disclosure and enter monitored recovery. “Cancel transaction” is not “unreveal secret.” If a secret is already public, assess rescue against actual state, not an optimistic local pending flag.

A relayer that receives the secret is inside this step's confidentiality/liveness boundary even though it never obtains a main wallet spend key. Prefer exact authorized submissions and enough independently available fee capacity to complete the claim before its deadline if one service fails.

### 7.3 Provider early refund rules

P must complete an early refund safely if valid XMR is missing while the swap is Funded. At tA, an unready Funded swap becomes claimable by U. Missing XMR does not automatically disable that on-chain path.

Do not wait until the last block before tA to disclose s_p. A refund whose secret is public but which misses the early-refund window can leave P exposed while U's ETH-claim window is open. A replacement transaction cannot make the secret private again.

If P sees ambiguous/inadequate XMR, it must use the pre-agreed deadline policy and recovery actions rather than assume a future on-chain check will protect it. The kernel does not inspect Monero.

### 7.4 Provider late refund and both-secret recovery

At/after tB, P can reveal s_p for late refund from nonterminal states. U can derive the shared Monero spend scalar after observing s_p. Chain acceptance/finality and the safety policy still matter.

If both secrets become public, both parties may be able to construct a Monero spend. Recovery must consider actual outputs/key images/spends and canonical ETH entitlement, not assume observing a refund event alone eliminates every race. Use exact both-chain adversarial tests before claiming an atomicity result for the profile.

### 7.5 Watchtowers and reorgs

A watchtower receives only expressly delegated data and actions. Receiving secrets counts as disclosure. Its outage or censorship must be considered in the timing model; it cannot become an unstated universal trust assumption.

Reorganizations may undo Ready, claims, refunds, credit consumption, or the Monero lock. Secret-exposure records never roll back. Test both chains independently, including a secret leaked from a transaction absent from final history. [R-ATHANOR]

## 8. Monero lock validation and recovery journal

### 8.1 Validate actual outputs

The pinned implementation must verify network, shared spend/view keys, output derivation, amount commitments/decryption, transaction/output identifiers, confirmations, lock/unlock rules, and ability to construct the expected spend. Reject wrong-amount, unrelated, immature, unsupported-type, or already spent outputs as the swap funding leg.

Extra or partial payments require an explicit agreement; they do not silently change the fixed ETH escrow. On an abort, return to the profile's recovery logic, not a provider-controlled manual promise.

### 8.2 Journal schema

Before either asset moves, write and back up an encrypted journal containing:

```text
journalVersion, profileId, network identifiers and software/artifact hashes
full signed quote/terms, salt, termsHash
kernel/core addresses, full poolId, beneficiary key reference
per-swap secret shares and shared viewing material, with controlled access
full public keys and DLEQ transcripts/verification evidence
XMR output/transaction identifiers, observed amounts and unlock status
ETH swapId, funding/Ready/claim/refund/settlement hashes and block identities
claim/refund deadlines, margins, monitoring/fee reserve policy
monotonic secret-exposure flags and first-disclosure records
current kernel stage/credit/nonce, competing signed plans
planned v7 asset-0 note opening/ciphertext and resulting core entry/position
reconciliation history and last authenticated chain views
```

The ordinary ShieldedETH seed does not restore an unfinished swap or its beneficiary key. Store the journal independently, with an explicit export/import workflow and tested encryption/password handling. A reference helper is not a production journal encryption design.

Restore on a second machine after funding, XMR locking, each secret exposure, unconfirmed claim, claim reorg, committed credit, failed deposit, successful deposit before response, pending insertion, and observed refund. Do not retry blind after a lost response; reconcile nonce and state first.

## 9. Fees, minimum sizes, and funding choices

Total user cost can include XMR transaction fees, provider spread, provider ETH funding transaction cost, claim relay fee, settlement relay fee, Core deposit gas, insertion, later private spending, and fallback/retry exposure. Decompose them in the quote; avoid counting the same cost both inside the spread and again as a unexplained fee.

The minimum economically sensible swap depends on live prices, fees, service terms, and acceptable overhead. Do not assert that a few-dollar swap is always impossible or always attractive. The wallet must show the actual all-in quote relative to the user's net delivered value and compare permitted alternatives.

For an E1 miner, positive estimated revenue is not a funded swap. Confirm unlocked, spendable XMR and any payout/conversion minimum first. Do not lock an ETH provider's inventory for weeks while a user mines.

An XMR invoice followed by sponsored execution is simpler but non-atomic unless separately proved otherwise. Label custody, prepayment, failure, and refund terms. It must not silently charge the same gas cost again through a shielded fee note.

## 10. Privacy and operational disclosures

Public on Ethereum: funding amount and provider, beneficiary authorization address, key-address commitments, deadlines, terms/profile digests, secret-bearing actions, credit allocations, fees, and eventual native-ETH deposit or public fallback. The lock/claim/deposit stages can be linked.

Known to P: exchanged amounts, transcript, agreed destination material when shared, and session metadata. Known to relayers: the corresponding signed plan and its public fields. Known to a shared-view-key holder: the swap address's matching Monero outputs under the selected profile. Sharing dedicated viewing material does not authorize general main-wallet access, but remains a privacy disclosure.

E2 avoids requiring a publicly funded ETH account controlled by U. It does not hide the public deposit amount, erase exchange metadata, guarantee timing unlinkability, or add all Monero users to the core's anonymity set. Fresh per-swap beneficiary keys reduce avoidable reuse but do not provide a universal anonymity guarantee.

Provider/relayer operation, exchange services, taxes, and jurisdiction-specific obligations require their own assessment. This technical specification does not determine legal status or make an identity-free-service guarantee.

## 11. Required tests

No test below is marked passed merely because the predecessor printed a successful output. Run actual assertions and independently sourced fixtures.

| Family | Required cases |
|---|---|
| Scalar/point profile | 0,1,ell-1,ell and above; Edwards subgroup/identity; combined identity; secp invalid points; swapped keys; wrong point-to-address association |
| DLEQ | Positive vectors; altered ranges/challenges/roles; transcript replay; mismatched context; supported Monero output implementations |
| Funding | Wrong core/version/asset 0; wrong profile; zero/oversized amount; duplicate ID; invalid time order; wrong beneficiary/terms |
| State × time | Every Funded/Ready/terminal action at tA-1,tA,tB-1,tB, plus safe-broadcast margin policies |
| Signatures | r/s/v range, high-s, cross-chain/kernel/version replay, fee substitution, executor restriction, nonce races, expired quote |
| Claim | Exact backed credit; no external call; double claim; wrong secret; fee >= amount; outer revert/out-of-gas after disclosure |
| Refund | Early missing-XMR path; refund missing its window after disclosure; late refund disclosed too early; Ready blocks early refund; both secrets public |
| Credit | Aggregate invariant, partial use, dust, forced ETH, address-credit claim failure/reentrancy, unrelated swap isolation |
| Separate delivery | Same-block settlement rejects; later-block failed cap/capacity/encoding/token-version mismatch keeps credit/nonce; retry succeeds |
| Full core path | Real v7 pool, asset 0 ciphertext, deposit body/commitment match, batch insertion, onward spend, and corrected direct first-note path |
| Multi-asset boundary | DepositPlan asset 1+ rejects; no implicit token exchange; token approval or token balance must not be touched by E2 |
| Both chains | Real regtest/stagenet/devnet funding/claim/refund; wrong/immature XMR; censorship/underpricing; independent reorgs; observed secrets without accepted receipts |
| Journals | Restore every phase; no exposure-flag rollback; lost responses, duplicate submission, conflicting plans, corrupted backup |
| Compatibility | Exact supported Monero versions/output forms; unsupported fork/profile rejected before new locking |

Use a plaintext/kernel reference ledger and invariant fuzzing for ETH obligations. Mocks may isolate Core rejection paths, but final evidence includes real Core circuits and real Monero spend/recovery behavior. A successful `ecrecover` check alone does not validate the exchange protocol.

## 12. Activation gates and deployment manifest

**E2-G0: Profile:** approve the exact shared-key/DLEQ/Monero model, all encoding/range/domain rules, current compatibility evidence, and symmetric timing assumptions. FCMP++ and Carrot compatibility require explicit evidence for the selected Monero version and output format.

**E2-G1: Both-chain prototype:** real supported Monero outputs and Ethereum devnet transactions, every abort/recovery path, restored journals, and the full v7 delivery/insertion/spend transaction sequence.

**E2-G2: Independent review:** kernel, DLEQ implementation, Monero logic, relayers, transaction construction, timing/secret handling, journal security, and frontend approvals. No unresolved critical/high findings.

**E2-G3: Limited release:** verified fixed deployment, conservative wallet/provider exposure and concurrency limits, funded monitoring/replacement capacity, reproducible artifacts, and published measured costs. Limits in a reference wallet are not a global on-chain liquidity cap.

Core G6 does not activate E2. E1 mining integration must leave atomic settlement disabled until these separate gates pass.

Manifest includes profileId/terms schema, kernel/Core code/deployment hashes, core poolId/version, asset0 verification, compiler/EVM/dependency versions, DLEQ source/proof vectors, Monero network/software/output rules, security review, timing/confirmation policies, tested rescue behavior, exact typed-data schemas, journal format, and receipts/benchmarks.

## 13. Source provenance and external references

**S-E2:** `ShieldedETH_v0_5_E2_XMR_Settlement.md`: shared-key design, two-stage credits, types, and kernel candidate.  
**S-C6:** `ShieldedETH_v0_6_Core_Delta.md`: multi-asset Core deposit selector and 109-byte delivery.  
**S-C7:** This package's Core v0.7: authoritative current pool/asset/encoding/insertion requirements.

The v0.7 domain/types/profile binding, later-block settlement guard, and symmetric deadline requirements are revisions, not evidence that the Monero implementation or full swap has already been tested.

- **R-ATHANOR:** [Athanor atomic-swap protocol reference](https://github.com/athanorlabs/atomic-swap/blob/master/docs/protocol.md). A reference design is not a reviewed v0.7 dependency; pin exact source and assumptions at E2-G0.
- **R-712:** [EIP-712](https://eips.ethereum.org/EIPS/eip-712), typed-data signing with application replay protections.
- **R-RISTRETTO:** [RFC 9496](https://datatracker.ietf.org/doc/html/rfc9496), distinguishing ristretto255 encodings from Monero's required profile.
- **R-1559:** [EIP-1559](https://eips.ethereum.org/EIPS/eip-1559), public fee funding and replacement economics.

This document does not assert a current Monero fork schedule, maintained swap liquidity, live exchange price, or a measured v0.7 transaction cost.


## Appendix A: ETH-side kernel implementation candidate

This source adapts the supplied v0.5 kernel to the v7 core interface, versioned typed data, profile/terms binding, and later-block pool settlement. **It has not been compiled or run for this revision.** There is no Monero node/wallet integration, DLEQ implementation, complete swap daemon, or production relayer embedded here. Those are explicit E2-G0/G1 prerequisites.

The two-phase architecture reduces a specific delivery failure risk; it does not prevent all secret-bearing transaction failures or malicious enclosing transactions. The symmetric timing and disclosure rules in §7 remain mandatory. Do not carry the predecessor's reported 7,351-byte runtime or 106k/136k execution costs into this revision.


### A.1 `XmrSwapKernel.sol`

Save this block as `contracts/XmrSwapKernel.sol`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IShieldedETHPoolDeposit {
    function deposit(uint8 asset, uint256 partialCommitment, uint128 amount, bytes calldata ciphertext) external payable returns (uint40 entry);
    function poolId() external view returns (bytes32);
    function VERSION() external view returns (uint16);
    function assetToken(uint256 asset) external view returns (address);
}

/// @title XMR -> shielded ETH settlement kernel (E2, v0.7). Immutable, no owner.
/// ETH side of an Athanor-style shared-key swap. Claims and refunds commit internal credits only;
/// delivery into ShieldedETH is a separate, retryable transaction.
contract XmrSwapKernel {
    // secp256k1
    uint256 internal constant N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 internal constant HALF_N = N / 2;
    uint256 internal constant ED25519_L = 2**252 + 27742317777372353535851937790883648493;

    enum Stage { None, Funded, Ready, Claimed, Refunded }

    struct Swap {
        bytes32 termsHash;
        uint64 claimBlock;
        address provider;     // P: locks ETH, receives XMR
        address beneficiary;  // U's authorization key: controls the ETH credit after claim
        address claimKey;     // address(s_u * G)  on secp256k1
        address refundKey;    // address(s_p * G)
        uint64 tA;
        uint64 tB;
        uint128 amount;
        Stage stage;
    }

    struct ClaimAuth   { bytes32 swapId; uint128 fee; address feeRecipient; address executor; uint64 deadline; }
    struct DepositPlan { bytes32 swapId; bytes32 poolId; uint8 asset; uint64 nonce; uint256 partialCommitment; bytes32 ciphertextHash; uint128 D; uint128 tip;
                         uint128 fee; address feeRecipient; address executor; uint64 deadline; }
    struct WithdrawAuth { bytes32 swapId; uint64 nonce; address to; uint128 amount; uint128 fee; address feeRecipient;
                          address executor; uint64 deadline; }

    bytes32 internal constant CLAIM_TYPEHASH = keccak256(
        "ClaimAuth(bytes32 swapId,uint128 fee,address feeRecipient,address executor,uint64 deadline)");
    bytes32 internal constant DEPOSIT_TYPEHASH = keccak256(
        "DepositPlan(bytes32 swapId,bytes32 poolId,uint8 asset,uint64 nonce,uint256 partialCommitment,bytes32 ciphertextHash,uint128 D,uint128 tip,uint128 fee,address feeRecipient,address executor,uint64 deadline)");
    bytes32 internal constant WITHDRAW_TYPEHASH = keccak256(
        "WithdrawAuth(bytes32 swapId,uint64 nonce,address to,uint128 amount,uint128 fee,address feeRecipient,address executor,uint64 deadline)");

    uint16 public constant VERSION = 7;
    bytes32 public immutable profileId;
    IShieldedETHPoolDeposit public immutable pool;
    bytes32 public immutable poolId;
    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 internal immutable deployChainId;

    mapping(bytes32 => Swap) public swaps;
    mapping(bytes32 => uint128) public userCredit;   // per claimed swap, spendable only with beneficiary authorization
    mapping(bytes32 => uint64) public creditNonce;
    mapping(address => uint256) public addrCredit;   // relayer fees and provider refunds, pull-only
    uint256 public lockedTotal;
    uint256 public userCreditTotal;
    uint256 public addrCreditTotal;

    event Funded(bytes32 indexed swapId, bytes32 indexed profileId, bytes32 termsHash, address indexed provider, address beneficiary, address claimKey, address refundKey, uint64 tA, uint64 tB, uint128 amount);
    event Ready(bytes32 indexed swapId);
    event Claimed(bytes32 indexed swapId, uint256 secret, uint128 userCredit, uint128 fee, address feeRecipient);
    event Refunded(bytes32 indexed swapId, uint256 secret);
    event Settled(bytes32 indexed swapId, uint64 nonce, uint40 poolEntry, uint128 D, uint128 tip, uint128 fee);
    event Withdrawn(bytes32 indexed swapId, uint64 nonce, address to, uint128 amount, uint128 fee);
    event CreditClaimed(address indexed account, address to, uint256 amount);

    error Reentrancy(); error BadParams(); error BadStage(); error BadTime(); error BadSecret(); error BadSig();
    error NotProvider(); error NotExecutor(); error Expired(); error BadNonce(); error Insufficient(); error PayFailed(); error Backing();

    modifier nonReentrant() {
        uint256 locked;
        assembly { locked := tload(0) }
        if (locked != 0) revert Reentrancy();
        assembly { tstore(0, 1) }
        _;
        assembly { tstore(0, 0) }
    }

    constructor(IShieldedETHPoolDeposit pool_, bytes32 profileId_) {
        if (address(pool_).code.length == 0) revert BadParams();
        if (profileId_ == bytes32(0) || pool_.VERSION() != 7 || pool_.assetToken(0) != address(0)) revert BadParams();
        profileId = profileId_;
        pool = pool_;
        poolId = pool_.poolId();
        deployChainId = block.chainid;
        DOMAIN_SEPARATOR = _domain();
    }

    // ------------------------------------------------------------------ swap lifecycle
    function fund(address beneficiary, address claimKey, address refundKey, uint64 tA, uint64 tB, bytes32 salt, bytes32 termsHash)
        external payable nonReentrant returns (bytes32 swapId)
    {
        if (beneficiary == address(0) || claimKey == address(0) || refundKey == address(0) || claimKey == refundKey) revert BadParams();
        if (termsHash == bytes32(0)) revert BadParams();
        if (!(block.timestamp < tA && tA < tB)) revert BadTime();
        if (msg.value == 0 || msg.value >= 2**128) revert BadParams();
        swapId = keccak256(abi.encode(block.chainid, address(this), msg.sender, beneficiary, claimKey, refundKey, tA, tB, msg.value, salt, profileId, termsHash));
        if (swaps[swapId].stage != Stage.None) revert BadStage();
        swaps[swapId] = Swap(termsHash, 0, msg.sender, beneficiary, claimKey, refundKey, tA, tB, uint128(msg.value), Stage.Funded);
        lockedTotal += msg.value;
        emit Funded(swapId, profileId, termsHash, msg.sender, beneficiary, claimKey, refundKey, tA, tB, uint128(msg.value));
        _checkBacking();
    }

    /// Provider signals it verified the XMR lock; enables an early claim before tA.
    function markReady(bytes32 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        if (msg.sender != s.provider) revert NotProvider();
        if (s.stage != Stage.Funded) revert BadStage();
        if (block.timestamp >= s.tA) revert BadTime();
        s.stage = Stage.Ready;
        emit Ready(swapId);
    }

    /// Reveals s_u. Commits the ETH to a credit; makes no external call. Relayable with the beneficiary's signature.
    function claimToCredit(bytes32 swapId, uint256 secret, ClaimAuth calldata a, bytes calldata sig) external nonReentrant {
        Swap storage s = swaps[swapId];
        if (a.swapId != swapId) revert BadParams();
        if (a.executor != address(0) && a.executor != msg.sender) revert NotExecutor();
        if (block.timestamp > a.deadline) revert Expired();
        if (msg.sender != s.beneficiary) {
            bytes32 h = keccak256(abi.encode(CLAIM_TYPEHASH, a.swapId, a.fee, a.feeRecipient, a.executor, a.deadline));
            if (_recover(h, sig) != s.beneficiary) revert BadSig();
        }
        _claim(swapId, s, secret, a.fee, a.feeRecipient);
    }

    function _claim(bytes32 swapId, Swap storage s, uint256 secret, uint128 fee, address feeRecipient) internal {
        if (!(s.stage == Stage.Ready || (s.stage == Stage.Funded && block.timestamp >= s.tA))) revert BadStage();
        if (block.timestamp >= s.tB) revert BadTime();
        if (!_mulVerify(secret, s.claimKey)) revert BadSecret();
        uint128 amt = s.amount;
        if (fee >= amt || (fee > 0 && feeRecipient == address(0))) revert BadParams();
        if (block.number > type(uint64).max) revert BadParams();
        s.claimBlock = uint64(block.number);
        s.stage = Stage.Claimed;
        lockedTotal -= amt;
        uint128 net = amt - fee;
        userCredit[swapId] = net;
        userCreditTotal += net;
        if (fee > 0) { addrCredit[feeRecipient] += fee; addrCreditTotal += fee; }
        emit Claimed(swapId, secret, net, fee, feeRecipient);
        _checkBacking();
    }

    /// Reveals s_p. Early (Funded, before tA) or late (non-terminal, at/after tB). Credits the provider; no push payment.
    function refundToCredit(bytes32 swapId, uint256 secret) external nonReentrant {
        Swap storage s = swaps[swapId];
        if (msg.sender != s.provider) revert NotProvider();
        bool early = s.stage == Stage.Funded && block.timestamp < s.tA;
        bool late = (s.stage == Stage.Funded || s.stage == Stage.Ready) && block.timestamp >= s.tB;
        if (!(early || late)) revert BadStage();
        if (!_mulVerify(secret, s.refundKey)) revert BadSecret();
        s.stage = Stage.Refunded;
        lockedTotal -= s.amount;
        addrCredit[s.provider] += s.amount;
        addrCreditTotal += s.amount;
        emit Refunded(swapId, secret);
        _checkBacking();
    }

    // ------------------------------------------------------------------ delivery
    /// Second, separate transaction: moves credit into a ShieldedETH deposit. A failing deposit reverts only this call.
    function settleCreditToPool(DepositPlan calldata p, bytes calldata ciphertext, bytes calldata sig) external nonReentrant returns (uint40 entry) {
        Swap storage s = swaps[p.swapId];
        if (s.stage != Stage.Claimed) revert BadStage();
        if (block.number <= s.claimBlock) revert BadTime();
        if (p.poolId != poolId || p.asset != 0 || ciphertext.length != 109) revert BadParams();
        if (p.executor != address(0) && p.executor != msg.sender) revert NotExecutor();
        if (block.timestamp > p.deadline) revert Expired();
        if (p.nonce != creditNonce[p.swapId]) revert BadNonce();
        if (keccak256(ciphertext) != p.ciphertextHash) revert BadParams();
        if (p.fee > 0 && p.feeRecipient == address(0)) revert BadParams();
        bytes32 h = keccak256(abi.encode(DEPOSIT_TYPEHASH, p.swapId, p.poolId, p.asset, p.nonce, p.partialCommitment, p.ciphertextHash, p.D, p.tip, p.fee,
            p.feeRecipient, p.executor, p.deadline));
        if (_recover(h, sig) != s.beneficiary) revert BadSig();
        uint256 total = uint256(p.D) + p.tip + p.fee;
        uint128 c = userCredit[p.swapId];
        if (p.D == 0 || total > c) revert Insufficient();
        userCredit[p.swapId] = c - uint128(total);
        userCreditTotal -= total;
        creditNonce[p.swapId] = p.nonce + 1;
        if (p.fee > 0) { addrCredit[p.feeRecipient] += p.fee; addrCreditTotal += p.fee; }
        entry = pool.deposit{value: uint256(p.D) + p.tip}(0, p.partialCommitment, p.D, ciphertext);
        emit Settled(p.swapId, p.nonce, entry, p.D, p.tip, p.fee);
        _checkBacking();
    }

    /// Public fallback: withdraw credit to an ordinary address (relayable; fee comes out of the credit).
    function withdrawCredit(WithdrawAuth calldata w, bytes calldata sig) external nonReentrant {
        Swap storage s = swaps[w.swapId];
        if (s.stage != Stage.Claimed) revert BadStage();
        if (w.executor != address(0) && w.executor != msg.sender) revert NotExecutor();
        if (block.timestamp > w.deadline) revert Expired();
        if (w.nonce != creditNonce[w.swapId]) revert BadNonce();
        if (w.to == address(0) || w.to == address(this) || w.amount == 0 || (w.fee > 0 && w.feeRecipient == address(0))) revert BadParams();
        bytes32 h = keccak256(abi.encode(WITHDRAW_TYPEHASH, w.swapId, w.nonce, w.to, w.amount, w.fee, w.feeRecipient, w.executor, w.deadline));
        if (_recover(h, sig) != s.beneficiary) revert BadSig();
        uint256 total = uint256(w.amount) + w.fee;
        uint128 c = userCredit[w.swapId];
        if (total > c) revert Insufficient();
        userCredit[w.swapId] = c - uint128(total);
        userCreditTotal -= total;
        creditNonce[w.swapId] = w.nonce + 1;
        if (w.fee > 0) { addrCredit[w.feeRecipient] += w.fee; addrCreditTotal += w.fee; }
        (bool ok,) = w.to.call{value: w.amount}("");
        if (!ok) revert PayFailed();
        emit Withdrawn(w.swapId, w.nonce, w.to, w.amount, w.fee);
        _checkBacking();
    }

    function claimAddressCredit(address payable to, uint256 amount) external nonReentrant {
        uint256 c = addrCredit[msg.sender];
        if (to == address(0) || to == address(this) || amount == 0 || amount > c) revert Insufficient();
        addrCredit[msg.sender] = c - amount;
        addrCreditTotal -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayFailed();
        emit CreditClaimed(msg.sender, to, amount);
        _checkBacking();
    }

    // ------------------------------------------------------------------ helpers
    /// true iff scalar * G == Q, where claimOrRefundKey = address(Q). ecrecover trick (h = 0, R = G, s' = scalar * Gx).
    function _mulVerify(uint256 scalar, address key) internal pure returns (bool) {
        if (scalar == 0 || scalar >= ED25519_L) return false; // shared secret must be valid on both curves
        address q = ecrecover(bytes32(0), 27, bytes32(GX), bytes32(mulmod(scalar, GX, N)));
        return q != address(0) && q == key;
    }

    function _recover(bytes32 structHash, bytes calldata sig) internal view returns (address) {
        if (sig.length != 65) revert BadSig();
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > HALF_N || (v != 27 && v != 28)) revert BadSig();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", block.chainid == deployChainId ? DOMAIN_SEPARATOR : _domain(), structHash));
        address a = ecrecover(digest, v, r, s);
        if (a == address(0)) revert BadSig();
        return a;
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ShieldedETH XMR Kernel"), keccak256("7"), block.chainid, address(this)));
    }

    function _checkBacking() internal view {
        if (address(this).balance < lockedTotal + userCreditTotal + addrCreditTotal) revert Backing();
    }
}
```


## Appendix B: Executable integration-suite requirements

The predecessor's test harness uses a different pool ABI and different typed-data schema. Renaming a test does not establish compatibility with a changed protocol. Implement v7 fixtures with all of the following explicit assertions:

### B.1 ETH-only settlement fixture in a multi-asset pool

Deploy the actual v7 pool with native ETH at 0 and a test ERC-20 at 1. Verify Core VERSION 7, the full poolId, and immutable native asset mapping. Deploy the kernel with the approved test profileId. Fund U/P/relay test actors independently; U's beneficiary authorization account starts with zero ETH.

Create a verified test shared-key/DLEQ transcript or clearly label a kernel-only fixture as lacking a Monero leg. Fund with the exact terms digest. The test must distinguish kernel-only accounting success from an actual successful swap.

### B.2 Claim and delivery assertions

1. Assert a wrong/out-of-range secret rejects and leaves all obligations unchanged.
2. With correct secret and signature, assert terminal Claimed state, claimBlock, user credit, fee credit, lockedTotal decrement, and the aggregate backing inequality.
3. In the same block, assert pool settlement rejects with no debit and no nonce increment.
4. Advance the block, use a canonical v7 asset-0 plan/ciphertext, and assert the exact Core entry, amount, tip, partial, body, accumulator, and residual credit.
5. Replay the plan and assert nonce rejection. Change poolId, asset, ciphertext hash, fee, recipient/executor, version, or chain and assert rejection.
6. Use a plan above the current asset-0 cap and assert the whole delivery call reverts while the already committed user credit and nonce remain unchanged. A failure must not recreate a provider refund right.
7. Retry a valid plan, then test a signed public fallback of the residual credit with its authorized fee.
8. Use the real v7 batch/direct relation to reach spendability and make an onward private payment. Direct testing must actually consume the absorbed first deposit.

### B.3 Refund and disclosure assertions

Enumerate all stages at `tA-1`, `tA`, `tB-1`, and `tB`; verify each allowed transition and credit owner. Exercise missing-XMR early refund, Ready cancellation denial, and late refund. Test provider operating logic that refuses unsafe early/late broadcasts, not merely the kernel's timestamp comparisons.

Simulate a secret-bearing transaction that is exposed but reverts, expires, is replaced, or is reorganized out. Exposure flags must remain set. Demonstrate the both-chain consequences when either or both shares become known; never count an absent receipt as secrecy restoration.

### B.4 Required evidence artifacts

Archive compiler/toolchain hashes, runtime code hash/size, complete transaction receipts, contract state before/after, plaintext reference obligations, signed typed-data fixtures, DLEQ vectors, Monero output/spend proofs, and restored-journal runs. Fail CI on any unexpected rejection/acceptance, missing artifact, timeout, or skipped scenario.

**No results for this v7 integration suite are claimed in this document.** A static presence check for the new selector or block guard is not a substitute for the suite.
