# AI.GG ERC-8257 Base Deployment

Canonical Base contracts:

- ToolRegistry: `0x265BB2DBFC0A8165C9A1941Eb1372F349baD2cf1`
- SubscriptionPredicate: `0xCBe0cd9B1d99d95Baa9c58f2767246C52e461f25`

## GCC Deployment (Active)

GCC (Guaranteed Capacity Credit) is the platform capacity token that
replaces the deprecated GCT. ERC-20 + ERC-2612 (Permit) + EIP-3009 surface
used by the AI.GG x402 facilitator.

- Chain: Base mainnet (8453)
- GCC ERC-20: `0x135fc92fbd260931bee1c412e87170fad30d7779`
- Owner: `0x30B10c22F2b136b3dCcFe8d5904A85FE45426b26`
- name: `Guaranteed Capacity Credit`
- symbol: `GCC`
- decimals: `18`
- maxSupply: `1_000_000_000` GCC (1e27 atoms)
- mintingFinalized: `false` (operator can still mint up to maxSupply)
- Deploy tx: `0xf8b5c3d8d78054796d2dcf1ad174d85e55422525e02d741f6d76349048e0ba1d`
- Deployed: 2026-05-28

basescan:
- Contract — https://basescan.org/address/0x135fc92fbd260931bee1c412e87170fad30d7779
- Deploy tx — https://basescan.org/tx/0xf8b5c3d8d78054796d2dcf1ad174d85e55422525e02d741f6d76349048e0ba1d

The CCA auction for GCC is intentionally not yet deployed. Open a separate
`DeployGCCCCA.s.sol --broadcast` job once the auction duration / floor
price are decided.

## GCT Deployment (Deprecated)

- GCT ERC-20: `0x7CCb0D3F16C9Ea94a189E14C1d92f6561D707fa4`
- GCT CCA auction: `0x5107cc753cc9d246de31ec999d549257cde3ae6d`

These contracts predate the 2026-05-28 GCC rebrand and remain on-chain only
for historical reference. They hold an immaterial residual balance and the
platform no longer interacts with either.

---

Deploy AI.GG SubscriptionPass:

```bash
cd /Volumes/T7-Data/sub2api3/AIGG/aigg-cca
SUBSCRIPTION_PASS_OWNER="$BASE_DEPLOYER_ADDRESS" \
forge script script/DeploySubscriptionPass.s.sol:DeploySubscriptionPass \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$BASE_DEPLOYER_PRIVATE_KEY" \
  --broadcast
```

Validate manifest and compute hash:

```bash
cd /Volumes/T7-Data/sub2api3/AIGG/aigg-src/frontend
npx @opensea/tool-sdk validate public/.well-known/ai-tool/aigg-gateway.json
npx @opensea/tool-sdk hash public/.well-known/ai-tool/aigg-gateway.json
```

Register AI.GG tool:

```bash
cd /Volumes/T7-Data/sub2api3/AIGG/aigg-cca
AIGG_TOOL_METADATA_URI="https://www.ai.gg/.well-known/ai-tool/aigg-gateway.json" \
AIGG_TOOL_MANIFEST_HASH="$AIGG_TOOL_MANIFEST_HASH" \
forge script script/RegisterAIGGTool.s.sol:RegisterAIGGTool \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$BASE_DEPLOYER_PRIVATE_KEY" \
  --broadcast
```

Configure subscription predicate:

```bash
cd /Volumes/T7-Data/sub2api3/AIGG/aigg-cca
AIGG_TOOL_ID="$AIGG_TOOL_ID" \
AIGG_SUBSCRIPTION_PASS="$AIGG_SUBSCRIPTION_PASS" \
AIGG_MIN_SUBSCRIPTION_TIER=1 \
forge script script/ConfigureAIGGSubscriptionPredicate.s.sol:ConfigureAIGGSubscriptionPredicate \
  --rpc-url "$BASE_RPC_URL" \
  --private-key "$BASE_DEPLOYER_PRIVATE_KEY" \
  --broadcast
```

SDK verification:

```bash
cd /Volumes/T7-Data/sub2api3/AIGG/aigg-src/frontend
npx @opensea/tool-sdk inspect --tool-id "$AIGG_TOOL_ID" --network base
npx @opensea/tool-sdk inspect --tool-id "$AIGG_TOOL_ID" --network base --check-access "$USER_ADDRESS"
```

The generic `tool-sdk set-collections` command configures the SDK's ERC-721 collection
predicate. AI.GG subscription access uses the SubscriptionPredicate above, so predicate
configuration should be done with `ConfigureAIGGSubscriptionPredicate`.

Set `ALLOW_NON_BASE_ERC8257=true` only for local forks or explicit non-Base dry runs. The
deployment and registry scripts otherwise require `block.chainid == 8453`.
