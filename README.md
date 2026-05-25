# sub2api-cca

Ethereum Sepolia contracts and scripts for launching **GCT** with Uniswap Continuous Clearing
Auction (CCA).

GCT is modeled here as an ERC20 token with EIP-3009 authorization transfers. The
AI.GG/sub2api backend can mirror user deposits in `users.gct_balance`, while the onchain token
sale and price discovery happen through Uniswap CCA.

## Scope

- Deploy an ERC20 GCT token on Ethereum Sepolia with `transferWithAuthorization` support for
  x402 facilitator settlement.
- Create a CCA auction for GCT through the Uniswap CCA factory.
- Keep auction configuration explicit and reproducible through Foundry scripts.
- Leave production launchpad strategy, Uniswap v4 migration, compliance gating, and backend indexer
  integration for later phases.

## References

- Uniswap CCA overview: https://developers.uniswap.org/docs/liquidity/liquidity-launchpad/overview
- Uniswap CCA setup: https://developers.uniswap.org/docs/liquidity/liquidity-launchpad/guides/setup
- Uniswap CCA example config: https://developers.uniswap.org/docs/liquidity/liquidity-launchpad/guides/example-configuration
- Uniswap CCA contracts: https://github.com/Uniswap/continuous-clearing-auction

## Install

Foundry is required.

```bash
forge install foundry-rs/forge-std
forge build
forge test
```

## Bootstrap GCT and CCA

```bash
cp .env.example .env
$EDITOR .env

make bootstrap-cca
```

`make bootstrap-cca` is the canonical Sepolia flow for e2e. It:

1. Deploys the GCT ERC20 contract.
2. Writes the emitted token address back to `.env` as `GCT_TOKEN`.
3. Creates the CCA distribution using `GCT_TOKEN`.
4. Writes the emitted auction address back to `.env` as `CCA_AUCTION`.

Use the generated `GCT_TOKEN` as `X402_GCT_ASSET` in `sub2api-listings`.

## Manual Deploy GCT CCA

Set `GCT_TOKEN` to the deployed token address, then run:

```bash
make deploy-cca
```

The script:

1. Builds an `AuctionParameters` struct compatible with Uniswap CCA.
2. Calls `ContinuousClearingAuctionFactory.initializeDistribution`.
3. Mints `GCT_AUCTION_SUPPLY` directly to the auction.
4. Calls `onTokensReceived()` so the auction registers the token inventory.

## Accounting Model

Onchain:

- GCT is an ERC20 token with EIP-3009 `transferWithAuthorization`,
  `receiveWithAuthorization`, and `cancelAuthorization`.
- CCA sells GCT and discovers the GCT/raise-currency price.

Backend:

- User onchain GCT deposits are mirrored into `users.gct_balance`.
- Usage billing computes the request's USD/USDC cost first.
- GCT spent = `usd_cost / GCT_USD_PRICE`.
- GCT balance is deducted before fallback to ordinary USD balance.

## Sepolia Defaults

- Chain ID: `11155111`
- Default RPC in `.env.example`: `https://ethereum-sepolia-rpc.publicnode.com`
- Uniswap CCA factory: `0x0000ccaDF55C911a2FbC0BB9d2942Aa77c6FAa1D`
- Default raise currency: `address(0)`, meaning Sepolia ETH

## Deployments

See [docs/deployments.md](docs/deployments.md) for deployed GCT addresses and transaction records.

## Joint E2E

See [docs/e2e-sepolia.md](docs/e2e-sepolia.md) for the end-to-end flow with
`sub2api-listings`, OKX Agentic Wallet, x402, CCA, and GCT consumption.
