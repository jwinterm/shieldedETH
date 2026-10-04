// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IShieldedETHPoolDeposit {
    function deposit(uint8 asset, uint256 partialCommitment, uint128 amount, bytes calldata ciphertext) external payable returns (uint40 entry);
    function poolId() external view returns (bytes32);
    function VERSION() external view returns (uint16);
    function assetToken(uint256 asset) external view returns (address);
}

/// @title XMR -> shielded ETH settlement kernel (E2, v0.8). Immutable, no owner.
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

    uint16 public constant VERSION = 8;
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
        if (profileId_ == bytes32(0) || pool_.VERSION() != 8 || pool_.assetToken(0) != address(0)) revert BadParams();
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
            keccak256("ShieldedETH XMR Kernel"), keccak256("8"), block.chainid, address(this)));
    }

    function _checkBacking() internal view {
        if (address(this).balance < lockedTotal + userCreditTotal + addrCreditTotal) revert Backing();
    }
}
