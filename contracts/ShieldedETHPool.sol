// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./SethGroth16Verifier.sol";

/// @title ShieldedETH v0.8 core pool: multi-asset, shared commitment tree, direct mode for idle-compatible queues.
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
        if (nextEntry >= MAX_ENTRIES) revert Full();
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
        if (uint256(nextEntry) + S.m > MAX_ENTRIES) revert Full();
        _batchVerify(proofs, S);
        for (uint256 i = 0; i < n; i++) if (S.mask & (uint256(1) << i) != 0) _batchApply(bodies[i], S.extHashes[i], S.encoded[i]);
        if (S.tipsSkipped != 0) { C += S.tipsSkipped; credit[msg.sender] += S.tipsSkipped; }
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
