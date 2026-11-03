# gasrescue contracts

The smart contracts behind [gasrescue.io](https://gasrescue.io): they move stablecoins out of wallets
that hold no gas. The user signs, our relayer submits the transaction and pays the network fee, and the
fees come out of the amount. Both contracts take exactly what the user signed, in one transaction, and
hold nothing afterwards.

## Deployed contracts

All contracts are source-verified on the block explorers (solc 0.8.28, optimizer 200 runs, EVM cancun).

| Chain | GasRelay | SwapRelay |
|---|---|---|
| Ethereum | [0x7129604E5295D64ec4b6d247BC2538F2FcC3868d](https://etherscan.io/address/0x7129604E5295D64ec4b6d247BC2538F2FcC3868d#code) | [0xCcEf1FE03257025f1081A563fEF9B19951186015](https://etherscan.io/address/0xCcEf1FE03257025f1081A563fEF9B19951186015#code) |
| Base | [0x7129604E5295D64ec4b6d247BC2538F2FcC3868d](https://basescan.org/address/0x7129604E5295D64ec4b6d247BC2538F2FcC3868d#code) | [0xCcEf1FE03257025f1081A563fEF9B19951186015](https://basescan.org/address/0xCcEf1FE03257025f1081A563fEF9B19951186015#code) |
| Arbitrum | [0x7129604E5295D64ec4b6d247BC2538F2FcC3868d](https://arbiscan.io/address/0x7129604E5295D64ec4b6d247BC2538F2FcC3868d#code) | [0x43d7CaD4b8F6F65C5f1c113dDCD8B25229aa15D6](https://arbiscan.io/address/0x43d7CaD4b8F6F65C5f1c113dDCD8B25229aa15D6#code) |
| HyperEVM | [0x7129604E5295D64ec4b6d247BC2538F2FcC3868d](https://hyperevmscan.io/address/0x7129604E5295D64ec4b6d247BC2538F2FcC3868d#code) | [0x43d7CaD4b8F6F65C5f1c113dDCD8B25229aa15D6](https://hyperevmscan.io/address/0x43d7CaD4b8F6F65C5f1c113dDCD8B25229aa15D6#code) |
| Robinhood Chain | [0x7129604E5295D64ec4b6d247BC2538F2FcC3868d](https://robinhoodchain.blockscout.com/address/0x7129604E5295D64ec4b6d247BC2538F2FcC3868d?tab=contract) | [0xCcEf1FE03257025f1081A563fEF9B19951186015](https://robinhoodchain.blockscout.com/address/0xCcEf1FE03257025f1081A563fEF9B19951186015?tab=contract) |
| Polygon | [0x7129604E5295D64ec4b6d247BC2538F2FcC3868d](https://polygonscan.com/address/0x7129604E5295D64ec4b6d247BC2538F2FcC3868d#code) | [0xbE72cf7ECBeFf0CFE4E56B51f468Ad8C857F7FeA](https://polygonscan.com/address/0xbE72cf7ECBeFf0CFE4E56B51f468Ad8C857F7FeA#code) (SwapRelay2) |

Roles, the same on every chain (also in [deployments.json](deployments.json)):

- Owner: `0x6333470B09437f978bC819121601D852fAab171A`
- Relayer, the only address that may submit: `0x2bDfF499d21EA25a7f93e26866027d9aC4FbeE6B`
- Fee wallet: `0x9Bca418539A69aF50D0d857B90deC3B345f105B0`

## How they work

**GasRelay** sends a stablecoin for a wallet without gas. The user signs an EIP-3009
`ReceiveWithAuthorization` for exactly the amount, payable to the GasRelay. Its nonce is the EIP-712 hash
of the whole transfer: sender, recipient, token, amount, fee, deadline and a random salt. So the token
signature itself fixes the recipient and the fee; nobody can change them, including us. In one
transaction the contract pulls the amount, pays the recipient `amount - fee` and the fee wallet `fee`.
For EIP-2612 tokens it takes a permit plus an EIP-712 signature of the same transfer instead.

**SwapRelay** swaps a stablecoin into the gas coin (or another accepted token) for a wallet without gas.
The authorization nonce is the hash of the swap: sender, both tokens, pool, amount, fee, minimum output,
deadline and salt. In one transaction the contract pulls the amount, pays the fee, sells the rest on the
fixed Uniswap v3 router (HyperSwap on HyperEVM) and pays the output to the sender, never anywhere else.
Below the signed minimum the whole transaction reverts.

**SwapRelay2** (Polygon) is SwapRelay plus `swapWithPermit`, for tokens that have an EIP-2612 permit but
no EIP-3009, such as USDT0 and the bridged USDC.e on Polygon. The user signs a permit for exactly the amount,
payable to the contract, and an EIP-712 signature of the swap itself (domain `SwapRelay`, version `2`). The
contract checks that signature before it uses the permit, so the permit alone moves nothing. Everything
else, including `swapWithAuthorization`, works as in SwapRelay. The chains deployed earlier keep SwapRelay.

All three contracts:

- accept a submission only from an allowed relayer, so a signature cannot be front-run by others,
- refuse a transfer id that was used before, an expired deadline, and a fee of the whole amount,
- check that the token really arrived (`PaymentMissing`) before paying anything out,
- hold no balance and no allowance between transactions.

## What the owner can and cannot do

The owner can pause the contracts, add or remove relayers and accepted tokens, change the fee wallet,
and recover tokens sent to a contract by mistake. The owner cannot move user funds, change a signed
transfer or swap, or change the swap router (it is immutable). Ownership uses OpenZeppelin `Ownable2Step`.

## Build and test

```bash
npm install
npm test
```

The tests start a local Hardhat node and check what a signature allows and what it does not: wrong
recipient, higher fee, lower minimum, other sender, replay, other submitter, pause, and for SwapRelay2 a
permit token with a salt in its domain, like USDT0 on Polygon. Nothing reaches a
public network.

## Security

See [SECURITY.md](SECURITY.md). Contact: contact@gasrescue.io

## License

MIT
