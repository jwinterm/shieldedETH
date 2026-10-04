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
