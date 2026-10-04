pragma circom 2.1.9;
include "transfer.circom";
component main {public [noteDomain, numAssets, root, publicAmount, publicAsset, extHash, nf, cm]} = Transfer(2, 4, 32);
