pragma circom 2.1.9;
include "transfer.circom";
component main {public [noteDomain, numAssets, root, publicAmount, publicAsset, extHash, nf, cm]} = Transfer(8, 4, 32);
