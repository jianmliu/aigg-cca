# Sepolia Joint E2E With aigg-src

Goal:

```text
email login through OKX Agentic Wallet
  -> x402 USDC top-up into ordinary AI.GG balance
  -> participate in GCT CCA on Sepolia
  -> claim ERC20 GCT
  -> deposit GCT to AI.GG
  -> consume API with GCT deducted first
```

## 0. Remote Preflight

The existing `aigg-src` live environment uses:

```text
aigg-src/.env.local
aigg-src/sub2api.pem
```

Run this before attempting the live Sepolia e2e:

```bash
cd /Volumes/T7-Data/sub2api3/AIGG/aigg-cca
scripts/remote-aigg-src-preflight.sh
```

The script intentionally prints only env key names and setting value lengths, not secrets.

## 1. Bootstrap GCT and CCA

GCT's ERC20 contract address is produced by the Sepolia deployment flow. The deployed token
implements EIP-3009 `transferWithAuthorization`, so a compatible x402 facilitator can settle GCT
top-ups directly. Do not configure `X402_GCT_ASSET` in `aigg-src` until this step has
emitted `GCT_TOKEN`.

```bash
cd /Volumes/T7-Data/sub2api3/AIGG/aigg-cca
cp .env.example .env
$EDITOR .env

make bootstrap-cca
```

The bootstrap script writes both generated addresses back to `.env`:

```bash
GCT_TOKEN=<deployed ERC20 address>
CCA_AUCTION=<deployed CCA auction address>
```

## 2. Configure aigg-src

Set these env vars for the backend:

```bash
X402_ENABLED=true
X402_FACILITATOR_URL=<x402 facilitator>
X402_SELLER_ADDRESS=<seller wallet>
X402_NETWORK=eip155:11155111
X402_ASSET=<Sepolia USDC token accepted by facilitator>
X402_USDC_DECIMALS=6
X402_GCT_ASSET=<GCT_TOKEN emitted by make bootstrap-cca>
X402_GCT_DECIMALS=18
X402_GATEWAY_WALLET_ADDRESS=<GatewayWallet verifying contract>

GCT_ENABLED=true
GCT_PRICE_SOURCE=cca_sepolia
GCT_USD_PRICE=<initial CCA or manually pinned GCT/USDC price>

OKX_ONCHAINOS_BIN=onchainos
OKX_ONCHAINOS_HOME=<local isolated state dir>
OKX_E2E_EMAIL=liujm06@gmail.com
```

The backend now supports both x402 payment assets:

- `{"amount": 10}` or `{"amount": 10, "asset": "usdc"}` credits ordinary balance.
- `{"amount": 10, "asset": "gct"}` credits `users.gct_balance`.

## 3. OKX Agentic Wallet Login

Use the existing backend endpoints:

```bash
curl -X POST "$SUB2API_BASE_URL/api/v1/payment/x402/okx/login" \
  -H "Authorization: Bearer $SUB2API_JWT" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${OKX_E2E_EMAIL:-liujm06@gmail.com}\",\"locale\":\"en-US\"}"

curl -X POST "$SUB2API_BASE_URL/api/v1/payment/x402/okx/verify" \
  -H "Authorization: Bearer $SUB2API_JWT" \
  -H "Content-Type: application/json" \
  -d '{"otp":"123456"}'
```

## 4. x402 USDC Top-Up

```bash
curl -X POST "$SUB2API_BASE_URL/api/v1/payment/x402/okx/top-up" \
  -H "Authorization: Bearer $SUB2API_JWT" \
  -H "Content-Type: application/json" \
  -d '{"amount":10,"asset":"usdc"}'
```

Expected backend effect:

- `users.balance += amount * X402_BALANCE_RECHARGE_MULTIPLIER`
- `users.gct_balance` unchanged
- `x402_topups.credited_asset = 'balance'`

## 5. Participate in CCA

```bash
make bid-cca
```

Record `bidId` from the script output:

```bash
CCA_BID_ID=<bidId>
```

After `claimBlock`:

```bash
make claim-cca
```

## 6. Deposit GCT to sub2api

For the platform-controlled deposit-address flow:

```bash
SUB2API_GCT_DEPOSIT_ADDRESS=<platform GCT deposit wallet>
SUB2API_GCT_DEPOSIT_AMOUNT=1000000000000000000
make deposit-gct
```

For the x402 GCT flow:

The configured facilitator must advertise `X402_GCT_ASSET` under `/supported` and submit the
token's `transferWithAuthorization` transaction during `/settle`.

```bash
curl -X POST "$SUB2API_BASE_URL/api/v1/payment/x402/okx/top-up" \
  -H "Authorization: Bearer $SUB2API_JWT" \
  -H "Content-Type: application/json" \
  -d '{"amount":1,"asset":"gct"}'
```

Expected backend effect:

- `users.gct_balance += amount`
- `users.balance` unchanged
- `x402_topups.credited_asset = 'gct'`
- `x402_topups.asset = GCT_TOKEN`
- `x402_topups.payment_amount_atoms = amount * 10^18`

## 7. Consume API

Enable GCT billing:

```bash
GCT_ENABLED=true
GCT_USD_PRICE=<GCT/USDC price>
```

Usage billing behavior:

```text
billable USD cost -> GCTCost = USD / GCT_USD_PRICE
if users.gct_balance >= GCTCost:
  deduct GCT
else:
  deduct ordinary balance
```
