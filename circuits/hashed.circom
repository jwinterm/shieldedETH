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
