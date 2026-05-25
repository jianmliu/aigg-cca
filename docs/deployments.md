# Deployments

## Base Mainnet

### GCT EIP-3009 Token

- Chain ID: `8453`
- Network: `eip155:8453`
- Contract: `0x7CCb0D3F16C9Ea94a189E14C1d92f6561D707fa4`
- Deployer/owner: `0x30B10c22F2b136b3dCcFe8d5904A85FE45426b26`
- Transaction: `0xf0809b93af3c592da7084db94c13760e84ee8dfd2f33e748566c9ca4a71ab9a3`
- Block: `46443267`
- Timestamp: `2026-05-25T02:24:41Z`
- Name: `Guaranteed Capacity Token`
- Symbol: `GCT`
- Decimals: `18`
- Initial supply: `0`

This deployment includes the full EIP-3009 surface used by x402 facilitator settlement:

- `transferWithAuthorization`
- `receiveWithAuthorization`
- `cancelAuthorization`
- `authorizationState`

AI.GG production setting:

```text
X402_GCT_ASSET=0x7CCb0D3F16C9Ea94a189E14C1d92f6561D707fa4
X402_GCT_DECIMALS=18
X402_NETWORK=eip155:8453
```
