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
