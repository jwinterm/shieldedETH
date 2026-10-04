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
