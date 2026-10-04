# ShieldedETH v0.7: Extension E1: Transaction Capacity

> Historical v0.7 specification. The [current v0.8 specification](ShieldedETH_v0_8_Core_Delta.md) governs the executable implementation, production requirements and measured evidence. Embedded source candidates and proposed tests are retained for reference.

**Status:** Wallet/operator engineering specification. No new pool role, collateral source, or consensus rule. Not a deployed service or earnings promise.  
**Depends on:** [ShieldedETH v0.7 Core](ShieldedETH_v0_7_Core.md). XMR atomic onboarding additionally requires the independently approved [E2 v0.7](ShieldedETH_v0_7_E2_XMR_Settlement.md).  
**Supersedes:** `ShieldedETH_v0_5_E1_Capacity.md`, including its ETH-only payment-request format and shared-gift recovery behavior.


## Contents

- [0. Scope and changes](#0-scope-and-changes)
- [1. Funding decision flow](#1-funding-decision-flow)
- [2. E1.A: Multi-asset gift links](#2-e1a-multi-asset-gift-links)
- [3. E1.B: Asset-aware payment requests and fee headroom](#3-e1b-asset-aware-payment-requests-and-fee-headroom)
- [4. E1.C: Broadcasters and insertion operators](#4-e1c-broadcasters-and-insertion-operators)
- [5. E1.D: Optional XMR mining and external earning](#5-e1d-optional-xmr-mining-and-external-earning)
- [6. Existing assets, sponsorship, and small-budget alternatives](#6-existing-assets-sponsorship-and-small-budget-alternatives)
- [7. Interfaces and local state](#7-interfaces-and-local-state)
- [8. Failure and privacy matrix](#8-failure-and-privacy-matrix)
- [9. Tests, gates, and evidence](#9-tests-gates-and-evidence)
- [10. Sources and scope of assertions](#10-sources-and-scope-of-assertions)
- [Appendix A: Format and economic helpers](#appendix-a-format-and-economic-helpers)
- [Appendix B: Helper unit tests and evidence](#appendix-b-helper-unit-tests-and-evidence)
- [Appendix C: Multi-asset onboarding acceptance scenarios](#appendix-c-multi-asset-onboarding-acceptance-scenarios)


## 0. Scope and changes

“Transaction capacity” means having usable value in a supported asset and an available way to fund the Ethereum operation that spends it. It is not a new token, an entitlement to free gas, or a guaranteed number of future transactions.

Multi-asset support is required. A user holding a token note can pay a willing broadcaster with a fee note in that token; the broadcaster supplies ETH for gas and any insertion tip. A user who already has spendable notes does not need to mine, receive a gift, or first buy public ETH merely to choose that service route. No provider is required to quote every approved asset.

### 0.1 Changes from the supplied E1

| Area | v0.7 decision |
|---|---|
| Gift assets | Any core-approved asset, with fee/headroom quoted in that asset's base units |
| Gift identity | Full poolId in the link, strict canonical decoding, bounded entry/slot hints |
| Exclusive control | A gift seed is shared bearer authority until a successful sweep to independently generated keys |
| Sweep recovery | Use the recipient's main recovery key; never use the sender-known gift ovk or gift-controlled padding |
| Browser privacy | Fragments are readable by page scripts; verified offline/local client is preferred, telemetry prohibited |
| Direct first-note | Use the corrected intermediate-root direct relation only for eligible pending deposits; pending transfer gifts still require insertion |
| Payment requests | Asset ID/address/units/decimals and fee headroom are explicit; no ETH-only `amountWei` assumption |
| Provider economics | ETH-funded execution versus same-asset private fee, with rational conversion quotes and inventory costs |
| Mining | Gross accumulation, usable payout, and economic profit are separate; negative profit is not “never receives XMR” |
| GPU/hashpower | Optional external resource-to-value adapters are permitted, but no required marketplace, custodial ledger, or mining reward inside the protocol |
| Tests | Assertion-based expected outcomes; no logging-only “passes” |

These are proposed revisions to the supplied E1 and adaptations to Core v0.7. No inherited test log is a v0.7 execution result. The embedded helper code covers format/arithmetic helpers, not the complete wallet, broadcaster, miner, or E2 swap.

## 1. Funding decision flow

### 1.1 Wallet classification

The wallet first classifies:

1. **Spendable shielded value plus public ETH:** self-submit or compare provider quotes.
2. **Spendable shielded value without public ETH:** obtain a same-asset private-fee quote.
3. **Funded but queued note:** select valid insertion/direct-absorption route; do not call the balance generally spendable yet.
4. **Public ETH or supported public tokens:** ordinary deposit, with approval/permit where appropriate and explicit fee funding.
5. **XMR:** independently approved E2 or explicitly labelled non-atomic sponsored service.
6. **No present funded value:** gift, payer-provided fee allowance, funded sponsor, or optional external work/mining.

There is no automatic value creation for an empty wallet. A sponsor, customer, miner reward, provider, or other actual source funds every benefit. Pending earnings are not shielded collateral.

### 1.2 Default UI lanes

| Lane | Who supplies ETH | How paid | Main condition |
|---|---|---|---|
| Self-submit | User's selected account | Actual Ethereum fee | Sufficient upfront ETH |
| Private-fee broadcast | User-selected provider | Fixed fee note in the payment asset | Sufficient note value and an accepted quote |
| Gift | Sender/provider for creation; recipient/provider for sweep | Gift includes sweep/headroom allowance | Shared credential remains at risk until swept |
| Payer headroom | Payer adds value | One larger ordinary note | Headroom is an estimate, not reserved gas |
| External sponsor | Merchant/community/friend/service | Disclosed subsidy or external payment | Funded terms and availability |
| Mining/compute proceeds | User or conversion/sponsor after earnings mature | Resource costs, conversion, then execution | Actual redeemable payout, not an earnings dashboard |

Testnet faucets belong in the development UI only. They do not fund mainnet operations.

## 2. E1.A: Multi-asset gift links

### 2.1 Meaning and limitations

A gift link contains a throwaway wallet seed. The sender, recipient, and anyone who obtains that seed can authorize spends of that wallet's notes. It is not an irreversible transfer of exclusive control, a time-locked gift, or a guarantee against sender reclamation.

The recipient obtains independently controlled notes only after sweeping into addresses generated from the recipient's unrelated wallet seed. Current nullifiers ensure at most one competing spend of a gift occurrence succeeds.

### 2.2 Create and fund

The sender:

1. Generates a fresh random 32-byte gift seed, never reused as a main wallet.
2. Derives Core v0.7 keys and `d=SHA256("SETH/v7/gift-d"||giftSeed)[0:11]`; checks the resulting address normally. In the negligible identity-base case, regenerate the gift seed rather than silently alter the deterministic gift address derivation.
3. Selects an approved asset and amount that covers the intended net gift, estimated sweep fee, insertion/fallback needs, and explicitly chosen future headroom.
4. Funds one gift note through an ordinary private transfer or public deposit. Deposits reveal amount and asset; an internal gift transfer does not publish them directly.
5. Waits for accepted chain history under its policy and creates the link using the actual entry/slot. A pending deposit may be direct-absorbable; a pending transfer entry is not.
6. Keeps the gift seed only under the sender's disclosed retention/reclaim policy.

The sender must not label the net value guaranteed when future service rates are unknown. Show gross gift value and the last checked expected usable remainder separately.

### 2.3 Canonical link format

```text
payload = u8(7)
          || poolId[32]
          || giftSeed[32]
          || u40be(entryHint)
          || u8(slotHint)
check = SHA256("SETH/v7/gift" || payload)[0:8]
fragment = "seth7gift:" || Base64URL_NoPad(payload || check)
link = <user-selected verified client URL> || "#" || fragment
```

The payload is 71 bytes, checked bytes 79, and the Base64URL component 106 characters. The fragment including `seth7gift:` is 116 characters. `entryHint` is either an entry below `2^30` or `2^40-1` for unknown. `slotHint` is 0–3 or 255 for unknown; an unknown entry requires an unknown slot. Hints are retrieval aids, never authorization or proof of inclusion.

Reject bad checksum, noncanonical Base64URL, extra bytes, wrong version, wrong full poolId, invalid hints, and unexpected nested query/fragment forms. Do not resolve a pool from a prefix collision. The checksum detects corruption; it does not authenticate the sender or protect a maliciously substituted valid link.

No plaintext asset/value field is needed in the link. Determine those from authenticated note data after decryption. Never infer a gift's economic value from an unauthenticated link preview.

### 2.4 Client and website security

A URL fragment is not automatically included in the HTTP request target, but JavaScript on the page can read `location.hash`. Treat an untrusted frontend as able to steal the gift. [R-FRAGMENT]

Gift handling must have no third-party scripts, analytics, crash payloads containing links, link preview service, remote proof generation with the seed, or automatic clipboard/history logging. Prefer a verified local wallet or pinned static bundle. Clear the fragment from visible browser history after local parsing where supported, without claiming this erases prior browser, extension, OS, clipboard, screenshot, or messaging copies.

Do not prompt users to paste the link into a support chat or provider quote form. Send only the final public envelope/proof to a broadcaster. Local storage of the seed/journal must be encrypted and explicitly disposable after successful reconciliation.

### 2.5 Claim and independently controlled sweep

The recipient:

1. Verifies the client and selected chain/pool before parsing the seed.
2. Strictly decodes, derives the gift address, and verifies the hinted accepted body/accumulator from an authenticated chain view.
3. Decrypts and checks the note's value, asset, randomness, key, commitment, position, and current nullifier status.
4. Generates or opens an **independent main wallet**. Never use the gift seed as that wallet's seed.
5. Obtains a same-asset fee quote and checks usable remainder. If no provider accepts that asset, offer self-submission with independently funded ETH or wait; do not claim every gift is gaslessly redeemable.
6. Constructs one single-asset sweep with gift `sk` for the input and independent main-wallet receiving addresses for all recipient-controlled outputs, including padding.
7. Encrypts outgoing recovery with the recipient main wallet's `ovk`, not the shared gift `ovk`.
8. Proves locally, simulates, submits, and confirms the outcome. Only then report exclusive control of the new notes.

**GIFT-RECOVERY-01.** The original gift key holder must not decrypt the sweep's outgoing batch or detect its padding through the gift incoming key. They still know the original note and can associate its derived nullifier with the sweep transaction. They do not thereby gain the independent output openings.

### 2.6 Insertion modes

| Gift state | Supported operation |
|---|---|
| Already inserted | Ordinary queued sweep, or direct sweep in an eligible current queue |
| Pending DEPOSIT and full pending prefix has at most one deposit plus exits, total <=4 | Corrected Core direct proof inserts it, spends under R1, and self-inserts new outputs |
| Pending TRANSFER | Prefix insertion first; direct mode cannot absorb this transfer entry |
| Busy/unsupported prefix | Normal batch insertion and then sweep |
| Reorganization changes hint/position | Reconcile complete history, invalidate stale local paths, and rebuild; do not keep an old position-derived nullifier as canonical |

The provider can charge for both insertion and sweep if those are genuinely separate jobs. Quotes must disclose the operations and prevent double billing for the same insertion reward/cost.

### 2.7 Reclaim, races, and privacy

The sender may attempt a later reclaim only under its disclosed policy. A date written in a message is not an on-chain expiry and does not disable the sender before that date. Show “shared bearer gift; sender can still reclaim” until a sweep succeeds.

Anyone who later learns the seed can recover the gift wallet's matching history, amounts, assets, and nullifiers. They may decrypt any outgoing records improperly encrypted under that wallet's recovery key. The corrected sweep prevents this additional output disclosure, but cannot erase what the sender already knew about the gift or its creation.

Do not make blanket statements that the link reveals “only that it was swept.”

## 3. E1.B: Asset-aware payment requests and fee headroom

### 3.1 Logical request schema

```json
{
  "format": "seth7req",
  "poolId": "0x...32 bytes...",
  "chainId": "1",
  "address": "seth7:...",
  "assetId": 1,
  "tokenAddress": "0x...20 bytes...",
  "amountBaseUnits": "100000000",
  "feeHeadroomBaseUnits": "2000000",
  "displayDecimals": 6,
  "requestId": "0x...32 random bytes...",
  "validUntil": "...unix seconds...",
  "memo": "optional off-chain text"
}
```

This example uses an abstract six-decimal asset; it is not a production token assignment. Core token identity comes from the selected full manifest. Validate asset ID, token address, chain, pool, display decimals, and receiving-address pool tag together. A memo never overrides structured payment fields.

The human request amount is converted to an integer using the manifest's decimals, not IEEE-754 arithmetic. Reject scientific notation, negative values, excess decimals, ambiguous separators, and values beyond the note bounds. JSON fee and value fields remain strings.

### 3.2 Headroom semantics

Pay `amountBaseUnits + feeHeadroomBaseUnits` as one ordinary note. Headroom is the same asset, not a separate fee token or locked reserve. The recipient owns it and may spend it otherwise.

Wallets may suggest capacity for one or two recently quoted operations, with the quote time, asset, mode, and uncertainty shown. They must not express token headroom as wei or promise a fixed number of transactions. A provider's conversion rate and availability can change before the recipient spends.

For a payment already denominated in ETH, the same rules apply with 18 display decimals. Public gas funding and private headroom remain separate balances.

## 4. E1.C: Broadcasters and insertion operators

### 4.1 Asset-aware quote economics

A provider pays network costs and insertion tips in ETH but may receive a different token note. Let:

```text
Bwei = quoted complete ETH cost allowance, including disclosed risk/redemption costs
rateNum / rateDen = asset base units per wei
Fasset = ceil(Bwei * rateNum / rateDen), then any explicitly quoted asset-unit margin
```

Use exact integers/rationals for signed quotes. Price displays can use decimal arithmetic, never binary floats to construct on-chain values. `Fasset` must fit the output amount range and the user's budget.

A quote must bind full pool/chain identity, asset ID and token address, mode/circuit, exact fee amount/address, executor, direct reward beneficiary, public insertion tip, expiry, terms hash, and quote ID. A provider may disclose a breakdown but the user approves one fixed total. It cannot retroactively increase the fee after seeing a receipt.

Changing fee asset, amount, address, direct beneficiary, tip, or execution restrictions requires the wallet to rebuild bound fields and prove again. Ethereum transaction fee replacement alone need not change the pool statement.

### 4.2 What the provider checks and learns

The broadcaster locally checks its exact prospective fee note, the complete proof, current roots/nullifiers, quote validity, canonical body, direct expectations where relevant, and simulation. It receives no input openings, spend key, incoming key, or main outgoing recovery key.

It necessarily learns the transaction's asset from its same-asset fee note, its fee amount/output, and session metadata. It does not learn all private payment amounts merely by verifying the proof. Use privacy-aware transport and minimize stable identifiers, but do not describe network metadata as hidden by the SNARK.

### 4.3 Float, redemption, and failure

A private fee note does not replenish a public gas account immediately. Providers need ETH working capital and may need per-asset consolidation, withdrawal, and external conversion. Frozen or impaired fee tokens can make a previously attractive quote uneconomic. Those risks are theirs under the fixed quote unless the user authorizes different terms before proving.

The provider bears mined failed-attempt gas when no fee output is created. It may refuse before submission; it gains no right to spend later user notes to bill a failure. Existing mutually conflicting authorizations can still execute until expiry or common inputs are consumed.

### 4.4 Batcher economics

A batcher's reward is public ETH credit, not note value. It evaluates the entire available prefix step, tip sum, top-ups, actual batch size, proof-generation cost, submission cost, expected failed races, and later credit redemption.

```text
quotedCostWei = gasLimitEstimate * quotedEffectiveGasPrice
                + provingCostWei + expectedRaceCostWei + redemptionAllowanceWei
requiredRewardWei = ceil(quotedCostWei * (10000 + marginBps) / 10000)
perEntryBreakEvenWei = ceil(requiredRewardWei / k)
```

No default 250k/260k gas or “seconds of CPU” is a measurement of v0.7. Use real receipts and full-batch proving data from Core G3. A current job's gas allowance and actual receipt are separate quantities.

Use `nextBatchWindow`, authenticate all public records, and verify expected start/root/accumulator before submission. Public witness computation can be independently checked; never confuse it with remote spending-witness processing. Batches bind the beneficiary. Direct proofs bind the direct beneficiary. Zero-only skip races provide no exclusive proof-work entitlement.

Earnings depend on actual activity and competition. Running an operator is not a guaranteed income source, and the project does not commit to operating or funding providers.

## 5. E1.D: Optional XMR mining and external earning

### 5.1 Separation from the pool

Mining produces XMR or another external reward, not ETH gas, a pool credit, or an unbacked shielded note. The optional adapter cannot mint note principal, write liabilities, reserve insertion priority, or spend private user notes.

The original E1 kept direct-to-wallet XMR mining and removed a built-in compute marketplace. v0.7 retains that launch scope. It additionally permits independently chosen hashpower/GPU services through an **off-protocol adapter boundary**, not a project-operated wage ledger or consensus feature. This is an explicit optional product allowance; it is not necessary for Core or gift onboarding.

### 5.2 Direct-to-wallet mining route

```text
user-authorized compute
→ accepted mining work
→ confirmed reward under selected mining/payout rules
→ unlocked and actually spendable XMR in the user's wallet
→ approved E2 swap, or separately disclosed conversion/sponsorship
→ funded ETH note, insertion, and ordinary onward payment
```

Pin supported miner/node/pool versions and actual network behavior when enabling a route. P2Pool's own documentation describes decentralized mining and warns that mining addresses can be public on its sidechain; a dedicated mining address is appropriate. [R-P2POOL]

Do not freeze a predicted Monero fork date, payout threshold, synchronization duration, or conversion minimum in this protocol. Fetch current service/network conditions and record versions. A Monero spend-profile change must pass E2's compatibility gate before the automatic swap path is enabled.

### 5.3 Correct economics: three different questions

For accepted user hashrate `h`, network hashrate `H`, average block reward `R`, block interval `tau`, active hours per day `hours`, and applicable sequential miner/pool deductions:

```text
expectedXmrPerDay = (h/H) * (86400/tau) * (hours/24) * R
                   * (1 - minerFee) * (1 - poolFee)
grossUsdPerDay = expectedXmrPerDay * xmrUsd
powerUsdPerDay = incrementalWatts / 1000 * hours * usdPerKWh
operatingProfitBeforeConversion = grossUsdPerDay - powerUsdPerDay - otherDailyCosts
```

Then model conversion and payout availability separately. For percentage conversion cost `f` and fixed settlement cost `c`:

```text
requiredGrossUsd = max(payoutMinimumUsd, conversionMinimumUsd,
                       (targetUsableUsd + c)/(1-f))
daysGrossAccumulation = requiredGrossUsd / grossUsdPerDay
netAfterVariableConversionPerDay = grossUsdPerDay*(1-f) - powerUsdPerDay - otherDailyCosts
```

An economic target after operating expenses has no finite positive-progress estimate when that last quantity is nonpositive. Gross accumulation can nevertheless be positive and eventually meet the payout requirement. Never label both results “never” merely because electricity exceeds revenue. Conversely, do not label accumulated gross XMR as profit.

The estimate is conditional expectation, not a payout deadline. Account maturity, pool variance, conversion availability, minimum withdrawal sizes, fixed fees, electricity payment timing, and changed exchange rates can postpone usable capacity. When no viable conversion exists, display **route unavailable**, not an invented finite ETA.

### 5.4 Illustrative sensitivity, not live data

At hypothetical `h=10 kH/s`, `H=5 GH/s`, 720 blocks/day, `R=0.6 XMR`, and `$300/XMR`, continuous gross value is `$0.2592/day` before deductions. At 100 W and `$0.15/kWh`, electricity is `$0.36/day`. Gross XMR still accumulates; economic profit is negative. A helper can display both facts without making a recommendation to mine.

Do not recommend buying or renting hardware merely to obtain a few dollars of gas. Do not assume shared machines, free cloud credits, or someone else's electricity are authorized. Claims about waste heat or surplus power must reflect the user's actual alternative costs.

### 5.5 Optional NiceHash-style / useful-GPU adapters

An adapter may represent hashpower sales, rendering, inference, proof computation, or another independently contracted service. It must expose:

```text
provider identity and terms version
job/work identifier and accepted-work evidence
reward asset and unit
estimated, accepted, credited, withdrawable, and settled balances separately
fees, minimum payout, timing, custody/identity requirements
actual destination asset/network and settlement method
resource/uptime requirements and cancellation behavior
```

No service is presumed available, profitable, identity-free, noncustodial, or able to settle a $1–2 reward. Do not copy stale vendor fees/thresholds into the wallet. “NiceHash-style” describes a business model, not an integration or endorsement of a particular service.

Untrusted compute workloads must not share a security boundary with spend keys. Use a dedicated sandbox/process or preferably a separate worker machine; reject requests for wallet files or seeds. A provider balance is a claim on that provider until redeemed. Advancing gas against such a balance is credit supplied by someone and must be disclosed as such.

A third party may pay for public insertion proofs, but full v0.7 proving and demand must be measured before claiming a viable proof-work market. Core gives no exclusive job right and no subsidy for redundant proofs.

### 5.6 Consent and long waits

Mining/compute is off by default. Require explicit permission for the device and electricity, visible activity, CPU/GPU/thread/power/temperature/battery limits, one-action stop, and no automatic restart without consent. Verify installed binaries and isolate secrets.

A weeks-long earning process stores an unsigned intent, not an old proof, short-lived quote, or signed transaction. Do not lock notes for weeks. Once the reward is unlocked and a real route is available, re-sync, re-price, choose current inputs, and authorize a fresh operation.

## 6. Existing assets, sponsorship, and small-budget alternatives

E1 may offer a friend/merchant-funded transaction, a bounty or legitimate task payment, an asset conversion selected by the user, or a service accepting an external payment. These are funding policies outside the pool. Every route identifies who provides real principal and ETH and what happens if the service fails.

A token's permit/authorization support can help a separately reviewed adapter, but the generic core `deposit` pulls tokens from its caller. A permit authorizing the pool does not by itself let an arbitrary relayer substitute that caller or choose a destination. Any adapter must bind owner, asset, amount, destination, tip, fees, nonce, and deadline under the correct token signature dialect. Unsupported tokens need ordinary approval/self-funding or another reviewed route.

An XMR invoice followed by a promise to submit is prepaid sponsorship, not E2 atomic exchange. A gifted public-ETH balance exposes its funding path. A subsidy can be bounded to a particular authorized operation rather than issuing an unrestricted account top-up. None of these choices is universally preferable; the wallet shows actual total cost, privacy exposure, and dependencies.

## 7. Interfaces and local state

Suggested CLI surface:

```text
gift create --asset --gross-amount --expected-net --headroom --client
gift inspect <fragment> --local-only
gift claim <fragment> --mode auto|queued|direct --max-fee --provider|--self-submit
gift reclaim <local-id> --show-race-warning
request create --asset --amount --headroom --expiry
quote compare --asset --mode --max-fee
operator estimate --live --asset
operator batch --max-k --min-margin
operator credit claim --amount --to
earn estimate --adapter --freshness-limit
earn start|pause|stop --limits
```

CLI flags are a suggested interface, not additional contract functions. Secret fragments must not enter shell history in production usage; provide secure stdin/local QR/import support rather than encouraging a literal seeded command line.

Local records distinguish shared gift seed, main seed, quote, pending proof variants, earning credit, actual asset balance, kernel credit, queued note, inserted note, and public ETH. An unfinished E2 journal is separate from both gift and main-wallet state.

## 8. Failure and privacy matrix

| Event | Required behavior |
|---|---|
| Bad gift checksum/manifest | Reject without contacting a broadcaster |
| Malformed hint/ciphertext | Continue safe local inspection or report invalid; never accept a preview as payment |
| Sender reclaims first | Show spent/conflict; do not bill an uncreated fee note |
| Gift value too small | Refuse a sweep that consumes the promised net without explicit new approval |
| Provider rejects fee token | Offer another provider/self-funding; do not silently convert or withdraw |
| Direct proof becomes stale | Re-sync; if the gift is still pending, insert or construct a new valid direct proof |
| Failed sweep transaction | Pool effects revert; submitting account bears gas under agreed terms |
| Main recovery key lost | Do not imply the gift seed restores independent recipient history |
| Mining unprofitable but gross positive | Show gross ETA and negative profit separately |
| Payout locked/below minimum | Not usable capacity |
| E2 unavailable | Disable automatic atomic route; clearly separate any trusted alternative |
| External work provider disappears | Report its credit exposure; no claim on pool collateral |

Gift hints, claim timing, provider requests, and the known gift nullifier can link an onboarding session. Removing a URL fragment after parsing does not undo prior disclosure. E1 must not promise anonymity solely because core transfers use a proof.

## 9. Tests, gates, and evidence

All expectations must assert and fail on mismatch. The helper appendix is not a full wallet security audit.

| Area | Required tests |
|---|---|
| Link format | Round trip; canonical re-encode; every truncation; padding/whitespace/invalid alphabet; checksum; full pool mismatch; wrong version; bounds and unknown hint |
| Gift spend | ETH and a token; sender/recipient race; multiple observations; no privileged reclaim date; too-small gift; no provider for asset |
| Corrected direct onboarding | Pending deposit is actually the consumed input under R1; pending transfer refuses absorption; busy queue fallback |
| Recovery separation | Shared gift ovk fails to open sweep recovery; recipient ovk succeeds; gift ivk cannot detect independent padding |
| Secret handling | Malicious webpage fixture reads fragment; production client blocks unintended scripts/telemetry; no seed in quotes, logs, crashes, or shell history |
| Quotes | Unit/asset/address mismatch, stale rational rate, invalid signature, expiry, changed executor/beneficiary, fixed total, no retrospective billing |
| Arithmetic | Ceil rounding, 0/negative/nonfinite inputs, unit bounds, >53-bit amounts, zero activity, absent conversion, negative net with finite gross accumulation |
| Operators | Every k, stale race, credit claims, reward copying, quiet pool, unpaid prefix |
| Earning | Off-by-default, stop/restart policy, permission, resource isolation, malicious binary/workload, payout floor, immature funds |
| Recovery | Independent client restores a gift and then main-wallet notes; E2 journal required only for its own unfinished route |

**E1-G0:** Freeze formats and approve gift/key/privacy behavior.  
**E1-G1:** Helper/parser tests and end-to-end wallet tests fail closed.  
**E1-G2:** Public testnet gift → independent sweep → onward payment for ETH and at least one token, with no public ETH in the recipient account and independent services. Include direct and queued paths.  
**E1-G3:** Frontend/secret-handling review and real fee-quote/insertion behavior.  
**E1-M:** Mining or compute adapters pass separate consent, custody, payout, and isolation review. Automatic E2 settlement is enabled only after E2's gates.

## 10. Sources and scope of assertions

**Source baseline:** `ShieldedETH_v0_5_E1_Capacity.md`, particularly §§1–4, and the v0.6 core delta's multi-asset and direct-mode sections. The gift recovery, parser, economics, and service revisions above are new v0.7 requirements, not predecessor test results.

- **R-FRAGMENT:** [MDN Location.hash](https://developer.mozilla.org/en-US/docs/Web/API/Location/hash), showing script access to fragments.
- **R-P2POOL:** [P2Pool upstream documentation](https://github.com/SChernykh/p2pool), deployment/version/payout/privacy conditions must be checked when the adapter is enabled.
- **R-712:** [EIP-712](https://eips.ethereum.org/EIPS/eip-712), quote authentication does not provide automatic replay protection.

No current vendor rate, payout minimum, mining revenue, or fork schedule is asserted here. Illustrations are labelled assumptions. Legal status is not decided by a label such as “noncustodial” or by which component runs a service.


## Appendix A: Format and economic helpers

Save the Python blocks into the indicated relative files. They use the standard library and require Python 3.10 or later. These helpers implement the explicit gift-fragment format and arithmetic, **not note cryptography, secret storage, a miner, a wallet, or an earning service**.

Only pass a fragment payload to the decoder, never an arbitrary URL from a clipboard without separate safe URL parsing. A production client must apply the secret-handling requirements above. Stationary expected earnings are not a payout guarantee or a current market quote.


### A.1 `e1_helpers.py`

Save this block as `ref/e1_helpers.py`.

```python
"""Format and estimate helpers for the v0.7 specification, not a wallet or miner.
All signed/on-chain amounts remain integers. Decimal estimates are illustrative.
"""
from __future__ import annotations
import base64
import hashlib
import hmac
import re
from dataclasses import dataclass
from decimal import Decimal, localcontext
from typing import Optional

GIFT_PREFIX = "seth7gift:"
UNKNOWN_ENTRY = (1 << 40) - 1
UNKNOWN_SLOT = 255

def ceil_div(n: int, d: int) -> int:
    if type(n) is not int or type(d) is not int or n < 0 or d <= 0:
        raise ValueError("ceil_div requires nonnegative numerator and positive denominator")
    return (n + d - 1) // d

def quote_asset_fee(eth_budget_wei: int, rate_num: int, rate_den: int,
                    margin_bps: int = 0, flat_asset_units: int = 0) -> int:
    """rate_num/rate_den is asset base units per wei; rounding is upward."""
    if any(type(x) is not int or x < 0 for x in
           (eth_budget_wei, rate_num, margin_bps, flat_asset_units)) or rate_num == 0:
        raise ValueError("invalid quote inputs")
    cost = ceil_div(eth_budget_wei * rate_num, rate_den)
    fee = ceil_div(cost * (10000 + margin_bps), 10000) + flat_asset_units
    if fee >= 1 << 128:
        raise ValueError("fee exceeds note range")
    return fee

def _hints(entry: int, slot: int) -> None:
    if type(entry) is not int or type(slot) is not int:
        raise ValueError("integer hints required")
    if entry != UNKNOWN_ENTRY and not 0 <= entry < 1 << 30:
        raise ValueError("entry out of range")
    if slot not in (0, 1, 2, 3, UNKNOWN_SLOT):
        raise ValueError("slot out of range")
    if entry == UNKNOWN_ENTRY and slot != UNKNOWN_SLOT:
        raise ValueError("unknown entry requires unknown slot")

def encode_gift(pool_id: bytes, seed: bytes, entry: int, slot: int) -> str:
    if len(pool_id) != 32 or len(seed) != 32:
        raise ValueError("32-byte pool identity and seed required")
    _hints(entry, slot)
    payload = b"\x07" + pool_id + seed + entry.to_bytes(5, "big") + bytes([slot])
    check = hashlib.sha256(b"SETH/v7/gift" + payload).digest()[:8]
    return GIFT_PREFIX + base64.urlsafe_b64encode(payload + check).decode("ascii").rstrip("=")

@dataclass(frozen=True)
class Gift:
    pool_id: bytes
    seed: bytes
    entry_hint: int
    slot_hint: int

def decode_gift(fragment: str, expected_pool_id: bytes) -> Gift:
    """Accept exactly a fragment payload, not arbitrary URLs or query strings."""
    if len(expected_pool_id) != 32 or not fragment.startswith(GIFT_PREFIX):
        raise ValueError("invalid gift context")
    encoded = fragment[len(GIFT_PREFIX):]
    if len(encoded) != 106 or re.fullmatch(r"[A-Za-z0-9_-]+", encoded) is None:
        raise ValueError("noncanonical base64url")
    raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    if len(raw) != 79 or base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != encoded:
        raise ValueError("noncanonical gift bytes")
    payload, checksum = raw[:71], raw[71:]
    if not hmac.compare_digest(hashlib.sha256(b"SETH/v7/gift" + payload).digest()[:8], checksum):
        raise ValueError("gift checksum")
    if payload[0] != 7 or not hmac.compare_digest(payload[1:33], expected_pool_id):
        raise ValueError("wrong version or pool")
    entry, slot = int.from_bytes(payload[65:70], "big"), payload[70]
    _hints(entry, slot)
    return Gift(payload[1:33], payload[33:65], entry, slot)

def batch_decision(k: int, reward_wei: int, gas_estimate: int, price_wei: int,
                   proving_cost_wei: int = 0, race_cost_wei: int = 0,
                   redemption_wei: int = 0, margin_bps: int = 0) -> dict[str, int | bool]:
    if type(k) is not int or not 1 <= k <= 16:
        raise ValueError("batch size 1..16 required")
    values = (reward_wei, gas_estimate, price_wei, proving_cost_wei,
              race_cost_wei, redemption_wei, margin_bps)
    if any(type(x) is not int or x < 0 for x in values):
        raise ValueError("negative or noninteger quote input")
    cost = gas_estimate * price_wei + proving_cost_wei + race_cost_wei + redemption_wei
    required = ceil_div(cost * (10000 + margin_bps), 10000)
    return {"costWei": cost, "requiredWei": required,
            "perEntryWei": ceil_div(required, k), "submit": reward_wei >= required}

def _d(value: str | int | Decimal, name: str) -> Decimal:
    if isinstance(value, (float, bool)):
        raise ValueError(f"{name}: use a decimal string, integer, or Decimal")
    x = Decimal(value)
    if not x.is_finite() or x < 0:
        raise ValueError(f"{name}: finite nonnegative value required")
    return x

def mining_estimate(*, hashrate, network_hashrate, reward_xmr, interval_seconds,
                    hours_per_day, xmr_usd, incremental_watts, electricity_usd_kwh,
                    target_usable_usd, fixed_settlement_usd, conversion_fraction="0",
                    miner_fraction="0", pool_fraction="0", other_daily_usd="0",
                    payout_min_usd="0", conversion_min_usd="0") -> dict[str, Optional[Decimal]]:
    """Expected stationary accumulation/profit only; does not simulate payout variance.
    Amount-based payout/conversion minima must be converted using the same dated inputs.
    """
    items = locals().copy()
    with localcontext() as ctx:
        ctx.prec = 60
        v = {k: _d(x, k) for k, x in items.items()}
        if v["network_hashrate"] <= 0 or v["interval_seconds"] <= 0:
            raise ValueError("network hashrate and interval must be positive")
        if v["hours_per_day"] > 24:
            raise ValueError("hours must be 0..24")
        for k in ("conversion_fraction", "miner_fraction", "pool_fraction"):
            if v[k] >= 1:
                raise ValueError("fractions must be less than one")
        xmr = (v["hashrate"] / v["network_hashrate"] * Decimal(86400) / v["interval_seconds"]
               * v["hours_per_day"] / 24 * v["reward_xmr"]
               * (1-v["miner_fraction"]) * (1-v["pool_fraction"]))
        gross = xmr * v["xmr_usd"]
        power = v["incremental_watts"] / 1000 * v["hours_per_day"] * v["electricity_usd_kwh"]
        net_before = gross - power - v["other_daily_usd"]
        net_after = gross * (1-v["conversion_fraction"]) - power - v["other_daily_usd"]
        threshold = max(v["payout_min_usd"], v["conversion_min_usd"])
        required = max(threshold, (v["target_usable_usd"] + v["fixed_settlement_usd"])
                       / (1-v["conversion_fraction"]))
        days_gross = required / gross if gross > 0 else None
        days_net = (max(threshold/gross, (v["target_usable_usd"]+v["fixed_settlement_usd"])/net_after)
                    if gross > 0 and net_after > 0 else None)
        return {"expectedXmrPerDay": +xmr, "grossUsdPerDay": +gross, "powerUsdPerDay": +power,
                "profitBeforeConversionUsdPerDay": +net_before,
                "profitAfterVariableConversionUsdPerDay": +net_after,
                "grossUsdNeededForUsableTarget": +required,
                "daysGrossAccumulation": days_gross, "daysEconomicTarget": days_net}
```


## Appendix B: Helper unit tests and evidence

The following suite was run against Appendix A during preparation: **20 tests passed**. This is limited evidence about gift encoding/checksums and estimation arithmetic. It does not exercise the core circuits, recipient encryption, gift sweeping, services, mining software, or cross-chain settlement.

After extracting the blocks, run from the project root:

```bash
python tests/test_helpers.py
```


### B.1 `test_helpers.py`

Save this block as `tests/test_helpers.py`.

```python
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'ref'))
import unittest
from decimal import Decimal
from e1_helpers import *

class HelperTests(unittest.TestCase):
    def setUp(self):
        self.pool=bytes(range(32)); self.seed=bytes(range(32,64))
        self.args=dict(hashrate="10000",network_hashrate="5000000000",reward_xmr="0.6",
            interval_seconds="120",hours_per_day="24",xmr_usd="300",incremental_watts="100",
            electricity_usd_kwh="0.15",target_usable_usd="2",fixed_settlement_usd="1")
    def test_gift_roundtrip(self):
        text=encode_gift(self.pool,self.seed,12345,2)
        self.assertEqual(len(text),116); g=decode_gift(text,self.pool)
        self.assertEqual((g.seed,g.entry_hint,g.slot_hint),(self.seed,12345,2))
    def test_unknown_hint(self):
        self.assertEqual(decode_gift(encode_gift(self.pool,self.seed,UNKNOWN_ENTRY,UNKNOWN_SLOT),self.pool).entry_hint,UNKNOWN_ENTRY)
    def test_wrong_pool(self):
        with self.assertRaises(ValueError): decode_gift(encode_gift(self.pool,self.seed,0,0),b'x'*32)
    def test_bad_alphabet(self):
        t=encode_gift(self.pool,self.seed,0,0)
        for bad in (t+'=',t+' ',t[:-1],t[:20]+'+'+t[21:]):
            with self.assertRaises(ValueError): decode_gift(bad,self.pool)
    def test_corruption(self):
        t=encode_gift(self.pool,self.seed,0,0)
        bad=t[:40]+('A' if t[40]!='A' else 'B')+t[41:]
        with self.assertRaises(ValueError): decode_gift(bad,self.pool)
    def test_hint_bounds(self):
        for entry,slot in ((-1,0),(1<<30,0),(0,4),(UNKNOWN_ENTRY,0)):
            with self.assertRaises(ValueError): encode_gift(self.pool,self.seed,entry,slot)
    def test_big_integer_fee(self): self.assertEqual(quote_asset_fee(10**30,1,10**15),10**15)
    def test_round_up(self): self.assertEqual(quote_asset_fee(1,1,3),1)
    def test_invalid_fee_denominator(self):
        with self.assertRaises(ValueError): quote_asset_fee(1,1,0)
    def test_fee_note_bound(self):
        with self.assertRaises(ValueError): quote_asset_fee(1<<128,1,1)
    def test_batch_round_up(self): self.assertEqual(batch_decision(16,20,1,17)['perEntryWei'],2)
    def test_zero_batch(self):
        with self.assertRaises(ValueError): batch_decision(0,1,1,1)
    def test_negative_profit_positive_gross(self):
        x=mining_estimate(**self.args)
        self.assertEqual(x['grossUsdPerDay'],Decimal('0.2592'))
        self.assertEqual(x['powerUsdPerDay'],Decimal('0.36'))
        self.assertIsNotNone(x['daysGrossAccumulation']); self.assertIsNone(x['daysEconomicTarget'])
    def test_hours_scale_rewards(self):
        a=mining_estimate(**self.args); b=mining_estimate(**(self.args|{'hours_per_day':'12'}))
        self.assertEqual(b['expectedXmrPerDay']*2,a['expectedXmrPerDay'])
    def test_zero_hashrate(self):
        x=mining_estimate(**(self.args|{'hashrate':'0'})); self.assertIsNone(x['daysGrossAccumulation'])
    def test_invalid_number(self):
        for value in ('NaN','Infinity','-1',float('1')):
            with self.assertRaises(ValueError): mining_estimate(**(self.args|{'hashrate':value}))
    def test_fraction_limit(self):
        with self.assertRaises(ValueError): mining_estimate(**self.args,conversion_fraction='1')
    def test_payout_threshold(self):
        x=mining_estimate(**self.args,payout_min_usd='20')
        self.assertEqual(x['grossUsdNeededForUsableTarget'],20)
    def test_zero_electricity(self):
        x=mining_estimate(**(self.args|{'electricity_usd_kwh':'0'})); self.assertIsNotNone(x['daysEconomicTarget'])
    def test_sequential_deductions(self):
        a=mining_estimate(**self.args); b=mining_estimate(**self.args,miner_fraction='0.1',pool_fraction='0.2')
        self.assertEqual(b['expectedXmrPerDay'],a['expectedXmrPerDay']*Decimal('.72'))
if __name__=='__main__': unittest.main(verbosity=2)
```

### B.2 Recorded output

```text
test_bad_alphabet (__main__.HelperTests.test_bad_alphabet) ... ok
test_batch_round_up (__main__.HelperTests.test_batch_round_up) ... ok
test_big_integer_fee (__main__.HelperTests.test_big_integer_fee) ... ok
test_corruption (__main__.HelperTests.test_corruption) ... ok
test_fee_note_bound (__main__.HelperTests.test_fee_note_bound) ... ok
test_fraction_limit (__main__.HelperTests.test_fraction_limit) ... ok
test_gift_roundtrip (__main__.HelperTests.test_gift_roundtrip) ... ok
test_hint_bounds (__main__.HelperTests.test_hint_bounds) ... ok
test_hours_scale_rewards (__main__.HelperTests.test_hours_scale_rewards) ... ok
test_invalid_fee_denominator (__main__.HelperTests.test_invalid_fee_denominator) ... ok
test_invalid_number (__main__.HelperTests.test_invalid_number) ... ok
test_negative_profit_positive_gross (__main__.HelperTests.test_negative_profit_positive_gross) ... ok
test_payout_threshold (__main__.HelperTests.test_payout_threshold) ... ok
test_round_up (__main__.HelperTests.test_round_up) ... ok
test_sequential_deductions (__main__.HelperTests.test_sequential_deductions) ... ok
test_unknown_hint (__main__.HelperTests.test_unknown_hint) ... ok
test_wrong_pool (__main__.HelperTests.test_wrong_pool) ... ok
test_zero_batch (__main__.HelperTests.test_zero_batch) ... ok
test_zero_electricity (__main__.HelperTests.test_zero_electricity) ... ok
test_zero_hashrate (__main__.HelperTests.test_zero_hashrate) ... ok

----------------------------------------------------------------------
Ran 20 tests in 0.001s

OK
```


## Appendix C: Multi-asset onboarding acceptance scenarios

**C1: inserted token gift.** The sender funds an approved token gift; the recipient authenticates its history, pays a provider in that token, uses an independent recovery key, and receives usable change. Confirm that the shared gift key can identify the consumed gift but cannot decrypt the sweep's recovery batch or new private padding.

**C2: first pending deposit gift.** Starting from an otherwise empty pool, the only input is the pending token deposit. The v7 direct proof must consume it under the derived intermediate root and immediately insert all new outputs. This must use a real direct verifier, not a mock accepting the reference's public array.

**C3: no provider quotes the token.** The wallet does not promise gasless capacity merely because the token is allowlisted. It offers self-funded submission or explicitly waits; it neither silently exchanges the token nor spends a different asset for the fee.

**C4: variable fees after gift creation.** If the updated quote consumes the intended usable remainder, require new user approval, external sponsorship, or a larger gift. No historical $1/$2 target overrides the live budget.

**C5: mining loses economic value but accumulates currency.** Show finite gross accumulation where applicable and negative economic profit separately. Apply actual payout maturity/minimums and E2 availability before reporting usable capacity.

These acceptance scenarios are specified requirements; their successful execution is not established here.
