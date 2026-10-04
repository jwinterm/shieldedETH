pragma circom 2.1.9;
include "../../circuits/transfer.circom";

// Research relation only. Full depth, one real input, recipient and change.
// The caller must bind the public fields and enforce pool state transitions.
component main {public [noteDomain, numAssets, root, publicAmount, publicAsset, extHash, nf, cm]} = Transfer(1, 2, 32);
