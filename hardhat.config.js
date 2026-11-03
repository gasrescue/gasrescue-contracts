// Only used for the local test chain (`hardhat node` on 127.0.0.1) in test/contracts.js. No accounts,
// keys or remote networks. Contracts are compiled by scripts/compile.js.
module.exports = {
  solidity: '0.8.28',
  networks: {
    hardhat: {
      chainId: 31337,
      hardfork: 'cancun',
      initialBaseFeePerGas: 1_000_000,
      accounts: { count: 1 },
    },
  },
};
