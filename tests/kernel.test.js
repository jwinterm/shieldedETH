"use strict";
const test = require("node:test"), assert = require("node:assert/strict"), crypto = require("node:crypto");
const { ethers } = require("ethers");
const { EVM, good, rejected } = require("./helpers/evm");
const ZERO = ethers.constants.AddressZero;
const fields = (s) => s.split(",").map((v) => { const [type, name] = v.split(" "); return { name, type }; });
const TYPES = {
  ClaimAuth: fields("bytes32 swapId,uint128 fee,address feeRecipient,address executor,uint64 deadline"),
  DepositPlan: fields("bytes32 swapId,bytes32 poolId,uint8 asset,uint64 nonce,uint256 partialCommitment,bytes32 ciphertextHash,uint128 D,uint128 tip,uint128 fee,address feeRecipient,address executor,uint64 deadline"),
  WithdrawAuth: fields("bytes32 swapId,uint64 nonce,address to,uint128 amount,uint128 fee,address feeRecipient,address executor,uint64 deadline")
};
const word = () => ethers.utils.hexlify(crypto.randomBytes(32));
function sharedSecret() {
  const b = crypto.randomBytes(32); b[0] &= 7;
  return { scalar: BigInt(ethers.utils.hexlify(b)), address: ethers.utils.computeAddress(b) };
}
test("E2 v8 authorization, separated claim/delivery, retry, withdrawal and refund backing", async () => {
  const e = await EVM.create(), pool = await e.deploy("KernelPoolFixture");
  const kernel = await e.deploy("XmrSwapKernel", [pool.address, word()]);
  const beneficiary = new ethers.Wallet(crypto.randomBytes(32));
  const domain = { name: "ShieldedETH XMR Kernel", version: "8", chainId: 1, verifyingContract: kernel.address };
  assert.equal(await e.read(kernel, "DOMAIN_SEPARATOR"), ethers.utils._TypedDataEncoder.hashDomain(domain));
  const sign = (type, body, version = "8") => beneficiary._signTypedData({ ...domain, version }, { [type]: TYPES[type] }, body);
  const backing = async () => {
    const totals = await Promise.all(["lockedTotal", "userCreditTotal", "addrCreditTotal"].map((f) => e.read(kernel, f)));
    assert.equal(await e.balance(kernel.address), totals.reduce((v, n) => v + n.toBigInt(), 0n));
  };
  const claimKey = sharedSecret(), refundKey = sharedSecret();
  const fund = async () => {
    const r = good(await e.call(kernel, "fund", [beneficiary.address, claimKey.address, refundKey.address, e.timestamp + 1000n, e.timestamp + 3000n, word(), word()], 1000n));
    await backing(); return r.events.find((v) => v.name === "Funded").args.swapId;
  };
  const id = await fund(); good(await e.call(kernel, "markReady", [id]));
  const claim = { swapId: id, fee: 10, feeRecipient: e.address, executor: ZERO, deadline: e.timestamp + 2000n };
  rejected(await e.call(kernel, "claimToCredit", [id, claimKey.scalar, claim, await sign("ClaimAuth", claim, "7")]), "BadSig"); await backing();
  const ct = crypto.randomBytes(109), delivery = { swapId: id, poolId: await e.read(pool, "poolId"), asset: 0, nonce: 0, partialCommitment: 1, ciphertextHash: ethers.utils.keccak256(ct), D: 900, tip: 5, fee: 5, feeRecipient: e.address, executor: ZERO, deadline: claim.deadline };
  const deliverySig = await sign("DepositPlan", delivery);
  good(await e.call(pool, "setAccepting", [true]));
  const probe = await e.deploy("KernelSameBlockProbe");
  good(await e.call(probe, "probe", [kernel.address, kernel.iface.encodeFunctionData("claimToCredit", [id, claimKey.scalar, claim, await sign("ClaimAuth", claim)]), kernel.iface.encodeFunctionData("settleCreditToPool", [delivery, ct, deliverySig])]));
  assert.equal(await e.read(probe, "claimSucceeded"), true);
  assert.equal(await e.read(probe, "deliveryRefused"), true);
  assert.equal(BigInt(await e.read(kernel, "userCredit", [id])), 990n); await backing();
  good(await e.call(pool, "setAccepting", [false]));
  rejected(await e.call(kernel, "settleCreditToPool", [delivery, ct, deliverySig]));
  assert.equal(BigInt(await e.read(kernel, "userCredit", [id])), 990n);
  assert.equal(BigInt(await e.read(kernel, "creditNonce", [id])), 0n); await backing();
  good(await e.call(pool, "setAccepting", [true]));
  good(await e.call(kernel, "settleCreditToPool", [delivery, ct, deliverySig]));
  assert.equal(await e.balance(pool.address), 905n); await backing();
  rejected(await e.call(kernel, "settleCreditToPool", [delivery, ct, deliverySig]), "BadNonce");
  const refuse = await e.deploy("RejectETH");
  const withdrawal = { swapId: id, nonce: 1, to: refuse.address, amount: 80, fee: 0, feeRecipient: ZERO, executor: ZERO, deadline: claim.deadline };
  rejected(await e.call(kernel, "withdrawCredit", [withdrawal, await sign("WithdrawAuth", withdrawal)]), "PayFailed");
  assert.equal(BigInt(await e.read(kernel, "userCredit", [id])), 80n); await backing();
  withdrawal.to = e.address;
  good(await e.call(kernel, "withdrawCredit", [withdrawal, await sign("WithdrawAuth", withdrawal)])); await backing();
  const refundId = await fund();
  rejected(await e.call(kernel, "refundToCredit", [refundId, claimKey.scalar]), "BadSecret");
  good(await e.call(kernel, "refundToCredit", [refundId, refundKey.scalar])); await backing();
  const credits = BigInt(await e.read(kernel, "addrCredit", [e.address]));
  rejected(await e.call(kernel, "claimAddressCredit", [refuse.address, credits]), "PayFailed"); await backing();
  good(await e.call(kernel, "claimAddressCredit", [e.address, credits])); await backing();
  assert.equal(await e.balance(kernel.address), 0n);
  good(await e.call(pool, "setVersion", [7]));
  await assert.rejects(e.deploy("XmrSwapKernel", [pool.address, word()]));
});
