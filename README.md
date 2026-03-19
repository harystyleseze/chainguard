# ChainGuard: Cross-Chain Compliance Shield Hook

**A Uniswap v4 hook that enforces autonomous cross-chain compliance via a 4-tier risk system. When a sanctioned address on Ethereum sends funds to a fresh wallet, that wallet is automatically flagged on Unichain before its next swap — with no off-chain infrastructure or centralized relayers.**

## Problem

Illicit funds flow freely through DEXes. Existing compliance solutions are passive KYC gates that only check static lists. Sanctioned actors circumvent them by sending funds to fresh wallets ("dusting") and swapping immediately. This creates a compliance gap for regulated asset pools, institutional LPs, and RWA markets.

## Solution

ChainGuard introduces **Hook Safety as a Service** — a cross-chain risk monitoring system with four enforcement tiers. It:

1. **Monitors** Ethereum USDC transfers, Chainalysis oracle events, and Circle USDC blacklist events via 3 scoped Reactive Network subscriptions
2. **Propagates taint** when blacklisted addresses send USDC to new wallets (SuspiciousNew tier)
3. **Syncs OFAC sanctions** automatically when Chainalysis emits `SanctionedAddressesAdded`
4. **Auto-blocks** Circle-blacklisted addresses when USDC emits `Blacklisted(address)`
5. **Enforces** 4-tier risk on every Uniswap v4 swap and LP action on Unichain

### Risk Tiers

| Tier | Fee | LP | Description |
|------|-----|----|-------------|
| **Clean** | 0.30% | Allowed | No restrictions |
| **SuspiciousNew** | 0.75% | Allowed | USDC taint victim — may appeal or auto-expire after 30d |
| **Flagged** | 3.00% | Blocked | Confirmed taint recipient |
| **Blocked** | Reverts | Blocked | Directly sanctioned (OFAC / Circle) |

## Architecture

```
ETHEREUM                           REACTIVE NETWORK                    UNICHAIN
========                           ================                    ========

USDC Transfer                      GuardReactive.sol
  from: 0xBlacklisted  -------->   Subscription 1: USDC Transfer
  to:   0xFreshWallet              - Check sender against local blacklist
                                   - If tainted sender + clean recipient:
                                     1. blacklist[recipient] = true (local)
                                     2. emit TaintPropagated
                                     3. emit Callback → flagSuspicious()
                                                    |
Chainalysis oracle  ------------>  Subscription 2: SanctionedAddressesAdded
  SanctionedAddressesAdded         - Decode address[] from log.data
  (OFAC SDN list sync)             - Update local blacklist for new addresses
                                   - emit Callback → blockAddressBatch()
                                                    |
USDC Blacklisted    ------------>  Subscription 3: USDC Blacklisted(address)
  (Circle compliance)              - Add target to local blacklist
                                   - emit Callback → blockFromUsdcBlacklist()
                                                    |
                                                    v
                                              GuardCallback.sol ----------> RiskRegistry.sol
                                              (rvmIdOnly relay)             - flagSuspicious() → SuspiciousNew
                                                                            - flagAddress()    → Flagged
                                                                            - blockFromOracle() → Blocked
                                                                            - batchBlockFromOracle() → Blocked[]
                                                                                    |
                                                                                    v
                                                                            GuardHook.sol
                                                                            - beforeSwap:
                                                                              Whitelist/EAS   → base fee
                                                                              Chainalysis live → revert
                                                                              Blocked         → revert
                                                                              Flagged         → 3.00% surcharge
                                                                              SuspiciousNew   → 0.75% surcharge
                                                                              Clean           → 0.30% base fee
                                                                            - afterSwap:
                                                                              MEV tax (gasprice - basefee)
                                                                              Travel Rule ($1K USDC threshold)
                                                                              MoneyFlowRecorded audit event
                                                                            - beforeAddLiquidity:
                                                                              Paused/Blocked/Flagged → revert
                                                                              Record addedAt timestamp
                                                                            - afterAddLiquidity:
                                                                              Emit LPPositionTracked
                                                                            - beforeRemoveLiquidity:
                                                                              Enforce 24h holding period
```

## Contracts

| Contract | Network | Purpose |
|----------|---------|---------|
| `RiskRegistry.sol` | Unichain | On-chain 4-tier risk registry with appeal and expiry |
| `GuardHook.sol` | Unichain | Uniswap v4 hook — block/surcharge/pass + LP holding period |
| `GuardCallback.sol` | Unichain | Relays Reactive Network callbacks to RiskRegistry |
| `GuardReactive.sol` | Reactive Network | 3 scoped subscriptions — taint, OFAC, USDC Blacklisted |

### RiskRegistry

Central registry storing compliance tier and metadata for every address.

| Function | Access | Description |
|----------|--------|-------------|
| `addToBlacklist(target)` | Owner | Mark address as Blocked |
| `batchAddToBlacklist(targets[])` | Owner | Batch block addresses |
| `removeFromBlacklist(target)` | Owner | Clear address (resets all metadata) |
| `setWhitelist(account, status)` | Owner | Whitelist bypasses all risk checks |
| `setIdentityVerified(account, status)` | Owner | EAS/World ID positive identity layer (bypasses surcharges) |
| `setSuspiciousExpiryPeriod(period)` | Owner | Auto-expiry for SuspiciousNew (default 30 days; 0 = disabled) |
| `flagSuspicious(target, source, chainId)` | Callback | Set SuspiciousNew tier (USDC taint propagation) |
| `flagAddress(target, source, chainId)` | Callback | Set Flagged tier (never downgrades Blocked) |
| `blockFromOracle(target, oracleName)` | Callback | Block single address from named oracle |
| `batchBlockFromOracle(targets[], oracleName)` | Callback | Block batch of addresses from named oracle |
| `requestAppeal()` | Self (suspicious addr) | Emit AppealRequested for owner review |
| `expireSuspicious(target)` | Permissionless | Clear SuspiciousNew → Clean after expiry period |
| `getRiskLevel(account)` | View | Returns `Clean`, `SuspiciousNew`, `Flagged`, or `Blocked` |
| `isBlocked` / `isFlagged` / `isSuspicious` / `isClean` | View | Boolean tier checks |
| `batchGetRiskLevel(accounts[])` | View | Bulk tier lookup |

Key design: `callbackContract` can only be set once (immutable after initialization). Flagging a Blocked address does **not** downgrade it. `flagAddress` from SuspiciousNew does not double-count `totalFlagged`.

### GuardHook

Uniswap v4 hook enforcing compliance at the protocol level.

**Hook Permissions**: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeAddLiquidity`, `afterAddLiquidity`, `beforeRemoveLiquidity`

| Hook | Behavior |
|------|----------|
| `beforeInitialize` | Requires `DYNAMIC_FEE_FLAG` — enforces dynamic fee model |
| `beforeSwap` | 5-step risk check: whitelist/EAS → Chainalysis live → Blocked → Flagged (3%) → SuspiciousNew (0.75%) → Clean (0.3%) |
| `afterSwap` | Records MEV tax (`tx.gasprice - block.basefee`); emits `MoneyFlowRecorded` audit event; emits `TravelRuleThresholdExceeded` for swaps ≥ $1,000 USDC |
| `beforeAddLiquidity` | Blocks paused/Blocked/Flagged; records first-add timestamp for holding period |
| `afterAddLiquidity` | Emits `LPPositionTracked` with amount0/amount1 and timestamp |
| `beforeRemoveLiquidity` | Enforces 24h LP holding period (configurable; 0 = disabled) |

**Fee Constants**:
- Base fee: `3000` (0.30%) — Clean addresses
- Suspicious fee: `7500` (0.75%) — SuspiciousNew tier
- Surcharge fee: `30000` (3.00%) — Flagged tier (10× base)
- Travel Rule threshold: `1_000 * 1e6` USDC units ($1,000)

**Admin Functions**:
- `pause()` / `unpause()` — emergency circuit breaker (LP removes always allowed)
- `setHoldingPeriod(period)` — update LP lock duration
- `setChainalysisOracle(oracle)` — enable live per-swap Chainalysis check (optional)
- `setEasContracts(eas, indexer)` — enable Coinbase EAS positive identity checks (optional)
- `setCoinbaseAttester(attester)` — update Coinbase attester address per chain
- `setRequireHookData(bool)` — require explicit user address in hookData (for aggregators)
- `getProtocolStats()` — single call returning all protocol metrics for dashboard display

### GuardReactive

Deployed on Reactive Network. Replaces wildcard `address(0)` subscriptions (which would process ~5–10M events/day on mainnet) with **3 scoped subscriptions** that reduce event volume by orders of magnitude.

**Subscription 1: USDC Transfer events** (`USDC_ETHEREUM`, `Transfer`)
```
if blacklist[sender] && !blacklist[recipient]:
    1. blacklist[recipient] = true  (local VM state)
    2. emit TaintPropagated(from, to, chainId)
    3. emit BlacklistUpdated(to, true)
    4. emit Callback → GuardCallback.flagSuspicious(rvm_id, to, from, chainId)
```

**Subscription 2: Chainalysis SanctionedAddressesAdded** (`CHAINALYSIS_ORACLE`, `SanctionedAddressesAdded`)
```
for each newly-sanctioned address:
    blacklist[addr] = true
    emit OracleSanctionDetected
emit Callback → GuardCallback.blockAddressBatch(rvm_id, newAddresses)
```

**Subscription 3: USDC Blacklisted** (`USDC_ETHEREUM`, `Blacklisted`)
```
if !blacklist[target]:
    blacklist[target] = true
    emit UsdcBlacklistDetected
    emit Callback → GuardCallback.blockFromUsdcBlacklist(rvm_id, target)
```

The reactive contract maintains a local blacklist mirror for fast lookups and transitive taint chains (A→B→C). Taint propagates automatically through subsequent transfers.

### GuardCallback

Minimal relay contract on Unichain. Receives callbacks from Reactive Network and forwards to RiskRegistry. All functions use `rvmIdOnly` modifier to verify the Reactive VM ID.

| Function | Called by | Description |
|----------|-----------|-------------|
| `flagSuspicious(_rvm_id, target, source, chainId)` | Reactive Network | USDC taint → SuspiciousNew tier |
| `flagAddress(_rvm_id, target, source, chainId)` | Reactive Network | Confirmed taint → Flagged tier |
| `blockFromUsdcBlacklist(_rvm_id, target)` | Reactive Network | Circle compliance → Blocked tier, flagSource = "USDC_BLACKLIST" |
| `blockAddressBatch(_rvm_id, targets[])` | Reactive Network | OFAC batch sync → Blocked tier, flagSource = "CHAINALYSIS" |

## File Structure

```
chainguard/
├── src/
│   ├── RiskRegistry.sol           # 4-tier risk registry (Clean/SuspiciousNew/Flagged/Blocked)
│   ├── GuardHook.sol              # Uniswap v4 hook (6 permissions, MEV tax, Travel Rule, holding period)
│   ├── GuardCallback.sol          # Reactive Network relay (4 callback functions, rvmIdOnly)
│   └── GuardReactive.sol          # RSC: 3 scoped subscriptions, taint propagation
├── test/
│   ├── GuardHook.t.sol            # 47 tests (unit, fuzz, integration)
│   ├── RiskRegistry.t.sol         # 52 tests (unit, fuzz, edge cases)
│   ├── GuardReactive.t.sol        # 23 tests (unit, fuzz, event routing)
│   └── ChainGuardUserJourneys.t.sol  # 15 end-to-end user journey tests
├── script/
│   ├── DeployGuard.s.sol          # Unichain deployment (registry + hook + callback)
│   └── DeployGuardReactive.s.sol  # Reactive Network deployment
├── foundry.toml
├── remappings.txt
└── lib/
    ├── forge-std/
    ├── v4-periphery/              # includes v4-core, solmate, permit2
    └── reactive-lib/              # AbstractReactive, AbstractCallback
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
cd chainguard
forge build
```

### Test

```bash
# All 137 tests
forge test -vv

# User journey narrative tests only
forge test --match-path test/ChainGuardUserJourneys.t.sol -vv

# Gas report
forge test --gas-report
```

### Deploy

**Step 1 — Unichain Sepolia (Registry + Hook + Callback):**
```bash
PRIVATE_KEY=<key> \
USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
forge script script/DeployGuard.s.sol \
  --rpc-url <unichain-sepolia-rpc> --broadcast
```

This deploys all three Unichain contracts, links the callback to the registry, and optionally seeds an initial blacklist.

**Step 2 — Reactive Network (RSC):**

> **Pre-requisite:** The deployer wallet must have ≥ 1 ETH on Reactive Lasna. Fund it by sending ≥ 1.1 ETH to the Reactive faucet (`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`) from Ethereum Sepolia — it bridges automatically.

```bash
# Set env vars
export REACTIVE_PRIVATE_KEY=<reactive-key>
export CALLBACK_CONTRACT=<callback-address>
export ORIGIN_CHAIN_ID=11155111
export DEST_CHAIN_ID=1301
export USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

# Step 2a — deploy the contract (simulation-safe)
forge script script/DeployGuardReactive.s.sol \
  --rpc-url https://lasna-rpc.rnk.dev/ \
  --broadcast \
  --private-key $REACTIVE_PRIVATE_KEY
```

After deploy, note the printed address and set `RSC_ADDR=<address>` in `.env`.

```bash
# Step 2b — register subscriptions via cast send (bypasses Forge simulation)
#
# WHY cast send: service.subscribe() internally calls address(0x64), a custom
# Reactive Network precompile that Forge's simulation EVM doesn't know about.
# Forge simulation returns 0 bytes → getSystemContractImpl() reverts "Failure".
# cast send skips simulation and sends directly to the real Lasna chain where
# the precompile exists and works correctly.
cast send $RSC_ADDR "subscribeAll()" \
  --rpc-url https://lasna-rpc.rnk.dev/ \
  --private-key $REACTIVE_PRIVATE_KEY \
  --gas 500000
```

> **Note:** `--gas 500000` skips `eth_estimateGas` (which is also a simulation). Without it, gas estimation hits the same `0x64` precompile issue and reverts before the transaction is sent.

**Step 3** — Fund the reactive contract with lREACT and call `coverDebt()`

### Deployed Contracts (Testnet)

| Contract | Network | Address |
|----------|---------|---------|
| **RiskRegistry** | Unichain Sepolia | `0x784b55846c052500c8fda5b36965ed3b8ca87792` |
| **GuardHook** | Unichain Sepolia | `0xa0510994afa4c109dcc6886ddc56446ec4eeeec0` |
| **GuardCallback** | Unichain Sepolia | `0xf936be2d36418f1e1d5d7ee58af4bbc6120b557b` |
| PoolManager | Unichain Sepolia | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Callback Proxy | Reactive Network | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Chainalysis Oracle | All major EVM chains | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| USDC | Ethereum Sepolia | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

## Tests

**137 tests across four files — all passing.**

### ChainGuardUserJourneys.t.sol (15 tests)

End-to-end user journey simulations proving the full architecture works as an integrated system:

| Journey | What It Proves |
|---------|---------------|
| 1. Clean user swaps | Base 0.30% fee, MoneyFlowRecorded emitted, zero surcharge counters |
| 2. Blocked user reverts | addToBlacklist → swap/LP add revert; removeFromBlacklist → clean again |
| 3. USDC taint propagation | Full Reactive→Callback→Registry→Hook path; SuspiciousNew enforcement |
| 4. SuspiciousNew → Flagged | Escalation, no double-count in totalFlagged, LP add blocked |
| 5. Chainalysis batch block | SanctionedAddressesAdded → blockAddressBatch → 3 Blocked, OracleSyncBatch event |
| 6. USDC Blacklisted | Circle compliance → blockFromUsdcBlacklist → Blocked, flagSource="USDC_BLACKLIST" |
| 7. LP holding period | Add at T → revert at T, T+12h; succeed at T+25h |
| 8. Travel Rule threshold | Exactly $1K USDC emits TravelRuleThresholdExceeded; $1K-1 does not |
| 9. MEV tax observation | Priority fee > 0 → MevTaxObserved event; zero priority fee → no event |
| 10. Emergency pause | Pause: swap/LP add blocked; LP remove still works; unpause resumes |
| 11. Whitelist bypass | Blocked address whitelisted → swaps at 0.30%; unwitelisted → blocked again |
| 12. Appeal + auto-expiry | requestAppeal() emits event; warp 31d → expireSuspicious() → Clean |
| 13. Three-hop taint chain | A→B→C transitive propagation; B and C pay 0.75%; A reverts |
| 14. Protocol stats dashboard | getProtocolStats() returns accurate counters after mixed operations |
| 15. Identity-verified + multi-oracle | identityVerified bypasses SuspiciousNew; CHAINALYSIS vs USDC_BLACKLIST flagSource |

### GuardHook.t.sol (47 tests)
- Hook permissions verification (all 6 flags)
- 4-tier fee enforcement (Clean / SuspiciousNew / Flagged / Blocked)
- LP holding period (block immediate exit, allow after 24h, disable with period=0)
- Per-pool isolation of holding period timestamps
- Emergency pause (scoped to swaps and LP adds; removes unaffected)
- Whitelist and identity-verified bypass paths
- MEV tax observation (priority fee > 0 increments counter; equality does not)
- hookData address override (smart contract wallet / aggregator pattern)
- Travel Rule threshold (exact boundary test)
- getProtocolStats() default and post-operation values
- MoneyFlowRecorded event correctness
- requireHookData enforcement
- Fuzz: flagged addresses always pay surcharge

### RiskRegistry.t.sol (52 tests)
- Add/remove/batch blacklist operations with correct totalBlocked accounting
- SuspiciousNew flagging and escalation to Flagged without double-counting
- Appeal request and auto-expiry lifecycle
- Identity-verified and whitelist state transitions
- Oracle sync functions (blockFromOracle, batchBlockFromOracle) with flagSource
- Callback-only and owner-only access control
- One-time callback contract setup (CallbackAlreadySet guard)
- Fuzz: add and remove random addresses; batch operations

### GuardReactive.t.sol (23 tests)
- USDC Transfer taint propagation (blacklisted sender → flag recipient)
- Scoped subscription enforcement (non-USDC contracts ignored)
- USDC Blacklisted event routing (correct contract guard)
- Chainalysis SanctionedAddressesAdded routing (batch decode, empty/duplicate guards)
- Transitive taint chain (A→B→C, 2 Callback events emitted)
- BlacklistUpdated event emission on all add paths
- No-duplicate-callback guard for already-blacklisted addresses
- Topic hash verification (Transfer, Blacklisted, SanctionedAddressesAdded)
- Fuzz: address extraction from topics

## Frontend Dashboard

A React/Vite/TypeScript/Tailwind dashboard for live interaction with the deployed contracts.

### Run locally

```bash
cd chainguard/dashboard
npm install
npm run dev
# → http://localhost:5173
```

### Tabs

| Tab | Description |
|-----|-------------|
| **Protocol Stats** | Live metrics: fees, surcharge counters, MEV tax, totalFlagged/Blocked, pause state. Auto-refreshes every 8s. |
| **Risk Checker** | Enter any address → see colour-coded risk badge (🟢 Clean / 🟡 SuspiciousNew / 🟠 Flagged / 🔴 Blocked), flaggedAt, flaggedBy, whitelist/KYC status, expiry countdown. No wallet needed. |
| **Batch Scanner** | Paste up to 50 addresses → calls `batchGetRiskLevel()` in one RPC call → summary + table. |
| **Admin Panel** | Owner actions (MetaMask on Unichain Sepolia required): block, unblock, whitelist, KYC toggle, flag, pause/unpause. |

### Stack

- [Vite](https://vite.dev/) + [React 18](https://react.dev/) + TypeScript
- [viem](https://viem.sh/) — contract reads via `createPublicClient`, writes via `eth_sendTransaction`
- [Tailwind CSS v3](https://tailwindcss.com/) — utility-first styling

### File Structure

```
dashboard/
├── src/
│   ├── constants.ts           # Addresses, ABIs, viem client, tx helpers
│   ├── App.tsx                # Tab shell + header
│   └── components/
│       ├── RiskChecker.tsx    # Single-address lookup
│       ├── BatchChecker.tsx   # Multi-address scan
│       ├── StatsPanel.tsx     # Protocol metrics (auto-refresh)
│       └── AdminPanel.tsx     # Owner write actions
├── package.json
├── vite.config.ts
└── tailwind.config.js
```

## Partner Integrations

### Reactive Network
- **`src/GuardReactive.sol`** — RSC deployed on Reactive Network; 3 scoped subscriptions replace the original wildcard `address(0)` subscriptions, reducing event volume by orders of magnitude while covering all compliance-relevant events
- **`src/GuardCallback.sol`** — deployed on Unichain; receives callbacks from GuardReactive via `rvmIdOnly` and writes to RiskRegistry
- Enables fully autonomous taint detection with zero off-chain infrastructure

### Unichain
- **`src/GuardHook.sol`** — Uniswap v4 hook deployed on Unichain Sepolia
- Leverages Unichain's TEE block building: `afterSwap` reads `tx.gasprice - block.basefee` (priority fee / MEV tax) to observe ordering pressure on compliance-flagged swaps
- `src/GuardCallback.sol` deployed at Unichain callback proxy `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`

### Chainalysis SanctionsList Oracle
- **`src/GuardReactive.sol`** — subscribes to `SanctionedAddressesAdded(address[])` at `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` (same address on all major EVM chains)
- Auto-syncs the OFAC SDN list into RiskRegistry without any manual intervention
- **`src/GuardHook.sol`** — optional live per-swap check via `ISanctionsList.isSanctioned()` (configurable; disabled by default)

### Circle USDC Compliance
- **`src/GuardReactive.sol`** — subscribes to `Blacklisted(address indexed _account)` on USDC contract
- Automatically blocks any address Circle legally blacklists (~2–60/year; zero false positives)
- flagSource = "USDC_BLACKLIST" distinguishes Circle blocks from OFAC blocks in RiskRegistry

### Coinbase EAS (optional)
- **`src/GuardHook.sol`** — checks Coinbase "Verified Account" attestation via `IAttestationIndexer` and `IEAS`
- Positive identity layer: verified addresses bypass all risk surcharges (treated as whitelisted)
- Gated by `easContract != address(0)` — disabled unless explicitly configured

## License

MIT
