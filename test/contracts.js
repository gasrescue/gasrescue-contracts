// Local tests of GasRelay and SwapRelay on a Hardhat node at 127.0.0.1: what a signature allows and
// what it does not. All keys are random and live only in memory; nothing reaches a public network.
//   npm test
const fs = require('fs');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');
const { ethers } = require('ethers');

const ROOT = path.resolve(__dirname, '..');
const artifact = (name) => JSON.parse(fs.readFileSync(path.join(ROOT, 'build', `${name}.json`), 'utf8'));
const units = (value) => ethers.parseUnits(value, 6);
const ETH_PER_USD = ethers.parseEther('0.0005'); // ETH at $2,000, per 1e6 token units

let passed = 0;
let failed = 0;
function check(name, ok, detail) {
  if (ok) passed += 1; else failed += 1;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  (${String(detail).slice(0, 300)})`}`);
}

function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function startNode() {
  const port = await freePort();
  const cli = path.join(ROOT, 'node_modules', 'hardhat', 'internal', 'cli', 'cli.js');
  const child = spawn(process.execPath, [cli, 'node', '--hostname', '127.0.0.1', '--port', String(port)], { cwd: ROOT, stdio: 'ignore' });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 120; i += 1) {
    try {
      const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }) });
      if (response.ok) return { url, stop: () => child.kill() };
    } catch { /* not up yet */ }
    await new Promise((resolve) => { setTimeout(resolve, 500); });
  }
  child.kill();
  throw new Error('The Hardhat node does not start');
}

const AUTH_TYPES = {
  ReceiveWithAuthorization: [
    { name: 'from', type: 'address' }, { name: 'to', type: 'address' }, { name: 'value', type: 'uint256' },
    { name: 'validAfter', type: 'uint256' }, { name: 'validBefore', type: 'uint256' }, { name: 'nonce', type: 'bytes32' },
  ],
};

// Why a call reverts: the custom error name, the revert string, or null when it would succeed.
const revertOf = (promise) => promise.then(() => null, (error) => (error.revert && error.revert.name) || error.reason || error.shortMessage || 'revert');

async function main() {
  const node = await startNode();
  try {
    const provider = new ethers.JsonRpcProvider(node.url, 31337, { staticNetwork: true, cacheTimeout: -1 });
    const wallet = () => ethers.Wallet.createRandom().connect(provider);
    const [owner, relayer, feeWallet, stranger, alice, bob] = Array.from({ length: 6 }, wallet);
    for (const [account, eth] of [[owner, '100'], [relayer, '1'], [stranger, '1']]) {
      await provider.send('hardhat_setBalance', [account.address, ethers.toQuantity(ethers.parseEther(eth))]);
    }
    const deploy = async (name, args = []) => {
      const { abi, bytecode } = artifact(name);
      const contract = await new ethers.ContractFactory(abi, bytecode, owner).deploy(...args);
      await contract.waitForDeployment();
      return contract;
    };
    const usdc = await deploy('SimToken', ['USDC']);
    const weth = await deploy('SimWrapped');
    const router = await deploy('SimRouter');
    const [usdcAddress, wethAddress, routerAddress] = await Promise.all([usdc, weth, router].map((contract) => contract.getAddress()));
    const relay = await deploy('GasRelay', [owner.address, relayer.address, feeWallet.address]);
    const swapRelay = await deploy('SwapRelay', [owner.address, relayer.address, feeWallet.address, routerAddress, wethAddress]);
    const [relayAddress, swapAddress] = await Promise.all([relay.getAddress(), swapRelay.getAddress()]);
    await (await relay.setToken(usdcAddress, true)).wait();
    for (const token of [usdcAddress, wethAddress]) await (await swapRelay.setToken(token, true)).wait();
    await (await owner.sendTransaction({ to: wethAddress, value: ethers.parseEther('10') })).wait();
    await (await weth.transfer(routerAddress, ethers.parseEther('10'))).wait();
    await (await router.setRate(usdcAddress, wethAddress, 500, ETH_PER_USD)).wait();
    await (await usdc.mint(alice.address, units('100'))).wait();
    const usdcDomain = { name: 'USDC', version: '1', chainId: 31337, verifyingContract: usdcAddress };
    const { timestamp } = await provider.getBlock('latest');
    const deadline = BigInt(timestamp + 600);

    // GasRelay: alice signs one authorization; the relayer sends 25 USDC to bob, 0.25 of it as fee.
    const transfer = { sender: alice.address, recipient: bob.address, token: usdcAddress, amount: units('25'), fee: units('0.25'), deadline, salt: ethers.hexlify(ethers.randomBytes(32)) };
    const id = await relay.transferId(transfer);
    const sig = ethers.Signature.from(await alice.signTypedData(usdcDomain, AUTH_TYPES, { from: alice.address, to: relayAddress, value: transfer.amount, validAfter: 0n, validBefore: deadline, nonce: id }));
    const relayAs = (signer, t) => relay.connect(signer).relayWithAuthorization.staticCall(t, sig.v, sig.r, sig.s);
    check('GasRelay: only the relayer may submit', (await revertOf(relayAs(stranger, transfer))) === 'NotRelayer');
    check('GasRelay: another recipient than signed is refused', (await revertOf(relayAs(relayer, { ...transfer, recipient: stranger.address }))) !== null);
    check('GasRelay: a higher fee than signed is refused', (await revertOf(relayAs(relayer, { ...transfer, fee: transfer.fee + 1n }))) !== null);
    check('GasRelay: a fee of the whole amount is refused', (await revertOf(relayAs(relayer, { ...transfer, fee: transfer.amount }))) === 'FeeTooHigh');
    await (await relay.connect(relayer).relayWithAuthorization(transfer, sig.v, sig.r, sig.s)).wait();
    check('GasRelay: bob gets amount minus fee, the fee wallet the fee', (await usdc.balanceOf(bob.address)) === units('24.75') && (await usdc.balanceOf(feeWallet.address)) === units('0.25'));
    check('GasRelay: alice paid exactly the signed amount and still holds no ETH', (await usdc.balanceOf(alice.address)) === units('75') && (await provider.getBalance(alice.address)) === 0n);
    check('GasRelay: the contract keeps nothing', (await usdc.balanceOf(relayAddress)) === 0n && (await provider.getBalance(relayAddress)) === 0n);
    check('GasRelay: the same transfer cannot run twice', (await revertOf(relayAs(relayer, transfer))) === 'AlreadyUsed');
    await (await relay.pause()).wait();
    check('GasRelay: paused, nothing runs', (await revertOf(relayAs(relayer, { ...transfer, salt: ethers.ZeroHash }))) === 'EnforcedPause');
    await (await relay.unpause()).wait();
    check('GasRelay: only the owner can redirect fees', (await revertOf(relay.connect(stranger).setFeeRecipient.staticCall(stranger.address))) === 'OwnableUnauthorizedAccount');

    // SwapRelay: alice swaps 20 USDC for ETH; 0.25 fee, the rest at $2,000, paid back to alice only.
    const swap = { sender: alice.address, tokenIn: usdcAddress, tokenOut: wethAddress, poolFee: 500, amount: units('20'), fee: units('0.25'), minOut: (units('19.75') * ETH_PER_USD) / 1_000_000n, deadline, salt: ethers.hexlify(ethers.randomBytes(32)) };
    const swapId = await swapRelay.swapId(swap);
    const swapSig = ethers.Signature.from(await alice.signTypedData(usdcDomain, AUTH_TYPES, { from: alice.address, to: swapAddress, value: swap.amount, validAfter: 0n, validBefore: deadline, nonce: swapId }));
    const swapAs = (signer, s) => swapRelay.connect(signer).swapWithAuthorization.staticCall(s, swapSig.v, swapSig.r, swapSig.s);
    check('SwapRelay: only the relayer may submit', (await revertOf(swapAs(stranger, swap))) === 'NotRelayer');
    check('SwapRelay: a lower minimum than signed is refused', (await revertOf(swapAs(relayer, { ...swap, minOut: 1n }))) !== null);
    check('SwapRelay: a higher fee than signed is refused', (await revertOf(swapAs(relayer, { ...swap, fee: swap.fee + 1n }))) !== null);
    check('SwapRelay: another sender than signed is refused', (await revertOf(swapAs(relayer, { ...swap, sender: stranger.address }))) !== null);
    check('SwapRelay: a minimum of zero is refused', (await revertOf(swapAs(relayer, { ...swap, minOut: 0n }))) === 'NoMinimum');
    await (await router.setRate(usdcAddress, wethAddress, 500, ETH_PER_USD / 2n)).wait();
    check('SwapRelay: a pool below the signed minimum makes the whole swap fail', (await revertOf(swapAs(relayer, swap))) !== null);
    await (await router.setRate(usdcAddress, wethAddress, 500, ETH_PER_USD)).wait();
    await (await swapRelay.connect(relayer).swapWithAuthorization(swap, swapSig.v, swapSig.r, swapSig.s)).wait();
    check('SwapRelay: alice gets the ETH, never anyone else', (await provider.getBalance(alice.address)) === swap.minOut);
    check('SwapRelay: alice paid exactly 20 USDC, the fee wallet got 0.25', (await usdc.balanceOf(alice.address)) === units('55') && (await usdc.balanceOf(feeWallet.address)) === units('0.5'));
    check('SwapRelay: the contract keeps nothing', (await usdc.balanceOf(swapAddress)) === 0n && (await weth.balanceOf(swapAddress)) === 0n && (await provider.getBalance(swapAddress)) === 0n);
    check('SwapRelay: the same swap cannot run twice', (await revertOf(swapAs(relayer, swap))) === 'AlreadyUsed');
    check('SwapRelay: plain ETH sent to it is refused', (await revertOf(stranger.sendTransaction({ to: swapAddress, value: 1n }))) !== null);
  } finally {
    node.stop();
  }
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
