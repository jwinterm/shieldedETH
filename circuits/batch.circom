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
