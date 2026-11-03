# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately to **contact@gasrescue.io** and give us time to fix them before
you publish anything. Include the contract, the chain and the steps to reproduce. We answer within a
few days.

## Scope

- GasRelay and SwapRelay at the addresses in [README.md](README.md)
- The website and API at https://gasrescue.io
- The MCP server at https://github.com/gasrescue/gasrescue-mcp

Out of scope: the tokens, routers and pools we call (USDC, USDT0, USDG, Uniswap, HyperSwap), wallet
software, and denial of service.

## Design notes

- Users sign EIP-3009 authorizations for an exact amount; recipient, fee and minimum are bound into the
  authorization nonce.
- Only allowed relayers can submit. The relayer pays gas and never receives user funds.
- The contracts hold no balances or allowances between transactions.
- There is no bug bounty program yet.
