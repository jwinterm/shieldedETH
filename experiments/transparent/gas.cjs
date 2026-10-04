"use strict";
const assert = require("node:assert/strict"), fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
const { ethers } = require("ethers"), { createVM, runTx } = require("@ethereumjs/vm");
const { Common, Mainnet, Hardfork } = require("@ethereumjs/common");
const { createLegacyTx } = require("@ethereumjs/tx"), { createBlock } = require("@ethereumjs/block");
const { createAccount, createAddressFromPrivateKey, createAddressFromString } = require("@ethereumjs/util");
const { save, sha256 } = require("../../scripts/artifacts");
const BUILD = path.resolve(__dirname, "../../build/transparent");

function calldataCost(bytes) {
  let zero = 0; for (const b of bytes) if (b === 0) zero++;
  const nonzero = bytes.length - zero, tokens = zero + 4 * nonzero;
  return { bytes: bytes.length, zeroBytes: zero, nonzeroBytes: nonzero,
    intrinsicGas: 21000 + 4 * tokens, floorGas: 21000 + 10 * tokens };
}
async function makeVM() {
  const common = new Common({ chain: Mainnet, hardfork: Hardfork.Prague });
  const vm = await createVM({ common });
  const key = crypto.randomBytes(32), sender = createAddressFromPrivateKey(key);
  await vm.stateManager.putAccount(sender, createAccount({ balance: 10n ** 30n }));
  let number = 1n;
  async function send(to, data, label) {
    const account = await vm.stateManager.getAccount(sender);
    const bytes = typeof data === "string" ? ethers.utils.arrayify(data) : data;
    const tx = createLegacyTx({ nonce: account.nonce, gasPrice: 2n, gasLimit: 30000000n,
      ...(to ? { to } : {}), data: bytes }, { common }).sign(key);
    const block = createBlock({ header: { number: number++, timestamp: 1800000000n + number * 12n,
      gasLimit: 30000000n, baseFeePerGas: 1n } }, { common });
    const result = await runTx(vm, { tx, block });
    return { result, row: { label, hardfork: "Prague", ...calldataCost(bytes),
      executionGas: Number(result.execResult.executionGasUsed), totalGas: Number(result.totalGasSpent),
      receiptStatus: result.receipt.status, calldataSha256: sha256(bytes),
      transactionHash: ethers.utils.hexlify(tx.hash()) } };
  }
  return { vm, common, send, sender, createAddressFromString };
}
async function main() {
  assert.equal(calldataCost(Buffer.alloc(0)).floorGas, 21000);
  assert.equal(calldataCost(Buffer.from([0, 1])).floorGas, 21050);
  const proof = Buffer.concat([fs.readFileSync(path.join(BUILD, "proof/proof.narg.bin")), fs.readFileSync(path.join(BUILD, "proof/proof.hints.bin"))]);
  const native = JSON.parse(fs.readFileSync(path.join(BUILD, "proof/native.json")));
  const fixture = JSON.parse(fs.readFileSync(path.join(BUILD, "fixture.json")));
  assert(native.verified); assert.deepEqual(native.publicValues, fixture.publicValues);
  const e = await makeVM();
  // An ordinary no-code recipient measures only data admission. This transaction
  // performs NO proof verification and NO payment state transition.
  const sink = "0x0000000000000000000000000000000000001234";
  const { row } = await e.send(sink, proof, "raw proof transport only, no verifier");
  assert.equal(row.receiptStatus, 1); assert.equal(row.executionGas, 0);
  assert.equal(row.totalGas, row.floorGas, "Prague receipt must enforce the independently calculated calldata floor");
  const iface = new ethers.utils.Interface(["function pay(uint256[9] publicInputs,bytes proof,bytes hints,bytes delivery)"]);
  const framed = iface.encodeFunctionData("pay", [fixture.publicValues,
    fs.readFileSync(path.join(BUILD, "proof/proof.narg.bin")), fs.readFileSync(path.join(BUILD, "proof/proof.hints.bin")),
    Buffer.from(fixture.deliveryHex, "hex")]);
  const framedResult = await e.send(sink, framed, "payment-shaped payload transport only, no verifier");
  assert.equal(framedResult.row.totalGas, framedResult.row.floorGas);
  const gas = { hardfork: "Prague", targetGas: 500000, ceilingGas: 1000000,
    measuredScope: "transport only; neither transaction verifies a proof or executes a shielded payment",
    rawProof: row, paymentPayload: framedResult.row,
    rawEncodingExceedsCeiling: row.floorGas > 1000000,
    completePaymentGas: null, verifierGas: null, productionEligible: false };
  save(path.join(BUILD, "gas.json"), gas);
  console.log(`Proof transport: ${row.bytes} bytes, ${row.totalGas} gas (Prague receipt). Payment-shaped payload: ${framedResult.row.totalGas} gas. No verification included.`);
}
if (require.main === module) main().catch(e => { console.error(e.message); process.exitCode = 1; });
module.exports = { calldataCost, makeVM };
