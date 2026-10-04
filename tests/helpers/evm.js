"use strict";
const assert = require("node:assert/strict"), crypto = require("node:crypto"), path = require("node:path");
const fs = require("node:fs");
const { ethers } = require("ethers"), { VM } = require("@ethereumjs/vm");
const { Common, Chain, Hardfork } = require("@ethereumjs/common");
const { Address, Account } = require("@ethereumjs/util");
const { Block } = require("@ethereumjs/block"), { LegacyTransaction } = require("@ethereumjs/tx");
const { ROOT, BUILD, json, sha256 } = require("../../scripts/artifacts");
class EVM {
  static async create() {
    const e = new EVM();
    e.common = new Common({ chain: Chain.Mainnet, hardfork: Hardfork.Cancun });
    e.vm = await VM.create({ common: e.common });
    e.signingKey = crypto.randomBytes(32);
    e.sender = Address.fromPrivateKey(e.signingKey);
    e.address = e.sender.toString();
    await e.vm.stateManager.putAccount(e.sender, Account.fromAccountData({ balance: 10n ** 30n }));
    e.number = 1n; e.timestamp = 1800000000n; e.measurements = [];
    const build = json(path.join(BUILD, "contracts.json"));
    for (const [file, hash] of Object.entries(build.sourceHashes)) assert.equal(sha256(fs.readFileSync(path.join(ROOT, file))), hash, `${file}: compiled contracts are stale`);
    e.artifacts = build.contracts;
    return e;
  }
  block() {
    return Block.fromBlockData({ header: { number: this.number, timestamp: this.timestamp, gasLimit: 30_000_000n, baseFeePerGas: 1n } }, { common: this.common });
  }
  iface(name) { return new ethers.utils.Interface(this.artifacts[name].abi); }
  async raw(to, data, value = 0n, label) {
    const account = await this.vm.stateManager.getAccount(this.sender);
    const tx = LegacyTransaction.fromTxData({ nonce: account.nonce, gasPrice: 2n, gasLimit: 30_000_000n, ...(to ? { to } : {}), value: BigInt(value), data }, { common: this.common }).sign(this.signingKey);
    const result = await this.vm.runTx({ tx, block: this.block() });
    this.number++; this.timestamp += 12n;
    const row = { label, blockNumber: (this.number - 1n).toString(), success: !result.execResult.exceptionError,
      transactionHash: ethers.utils.hexlify(tx.hash()), totalGas: Number(result.totalGasSpent),
      executionGas: Number(result.execResult.executionGasUsed), intrinsicGas: Number(tx.getBaseFee()),
      gasRefund: Number(result.gasRefund || 0n), calldataBytes: tx.data.length,
      calldataSha256: sha256(tx.data), receiptStatus: result.receipt.status };
    if (label) this.measurements.push(row);
    return { result, row, ok: row.success, data: result.execResult.returnValue };
  }
  async deploy(name, args = [], label) {
    const iface = this.iface(name);
    const r = await this.raw(null, this.artifacts[name].bytecode + iface.encodeDeploy(args).slice(2), 0n, label);
    assert(r.ok, `Deploy ${name}: ${r.result.execResult.exceptionError?.error}`);
    const address = r.result.createdAddress.toString();
    return { address, iface, name };
  }
  async call(contract, fn, args = [], value = 0n, label) {
    const r = await this.raw(contract.address, contract.iface.encodeFunctionData(fn, args), value, label);
    if (r.ok) r.ret = contract.iface.decodeFunctionResult(fn, r.data);
    else { try { r.reason = contract.iface.parseError(r.data).name; } catch { r.reason = r.result.execResult.exceptionError.error; } }
    r.events = (r.result.execResult.logs || []).flatMap((l) => {
      try { return [contract.iface.parseLog({ topics: l[1].map((t) => ethers.utils.hexlify(t)), data: ethers.utils.hexlify(l[2]) })]; } catch { return []; }
    });
    return r;
  }
  async read(contract, fn, args = []) {
    // eth_call-style view isolation. Never let reads warm a later benchmark transaction.
    await this.vm.evm.journal.cleanup();
    this.vm.stateManager.originalStorageCache.clear();
    await this.vm.stateManager.checkpoint();
    try {
      const r = await this.vm.evm.runCall({ caller: this.sender, to: Address.fromString(contract.address), data: ethers.utils.arrayify(contract.iface.encodeFunctionData(fn, args)), gasLimit: 30_000_000n, block: this.block() });
      assert(!r.execResult.exceptionError, `Read ${fn} failed`);
      const decoded = contract.iface.decodeFunctionResult(fn, r.execResult.returnValue);
      return decoded.length === 1 ? decoded[0] : decoded;
    } finally {
      await this.vm.stateManager.revert();
      await this.vm.evm.journal.cleanup();
      this.vm.stateManager.originalStorageCache.clear();
    }
  }
  async balance(address) { return (await this.vm.stateManager.getAccount(Address.fromString(address)))?.balance || 0n; }
}
function vkArgs(vk) {
  const g2 = (v) => [v[0][1], v[0][0], v[1][1], v[1][0]];
  return [[vk.vk_alpha_1[0], vk.vk_alpha_1[1]], g2(vk.vk_beta_2), g2(vk.vk_gamma_2), g2(vk.vk_delta_2), vk.IC.flatMap((p) => p.slice(0, 2))];
}
const good = (r) => { assert(r.ok, r.reason || "transaction reverted"); return r; };
const rejected = (r, reason) => { assert(!r.ok, "expected rejection"); if (reason) assert.equal(r.reason, reason); return r; };
module.exports = { EVM, vkArgs, good, rejected };
