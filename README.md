# Ember buyback and burn hook

Foundry implementation and real-PoolManager tests for the Sepolia Ember launch. The deliverables are `src/LaunchToken.sol`, `src/BuybackBurnHook.sol`, the tests, and `docs/abi/`. The launch label is `lab-buyback-burn-hook`.

## Contracts and accounting

`LaunchToken()` creates **Ember (EMBR)** with 18 decimals and exactly **1,000,000,000 EMBR**, all minted to `msg.sender`. There is no additional mint, owner, pause, tax, upgrade, or token burn function. Sending tokens to `0x000000000000000000000000000000000000dEaD` removes them from circulation by convention; ERC-20 `totalSupply()` remains unchanged.

`BuybackBurnHook(IPoolManager)` enables exactly `afterSwap` and `afterSwapReturnDelta`. OpenZeppelin BaseHook checks the address permissions in its constructor and restricts all external callbacks to that immutable manager. The implementation overrides the internal `_afterSwap`. It has no administrator, upgrade, pause, rescue, or arbitrary execution path.

The hook charges **100 basis points** on the absolute raw PoolManager delta of the **unspecified currency**, rounded down. The pool's static **3000** LP fee (0.3%) remains separate.

| Swap | Specified side | Hook fee currency | Trader effect | Settlement |
| --- | --- | --- | --- | --- |
| Exact-input buy | ETH input | EMBR output | Receives output minus 1% | `take` EMBR directly to dead |
| Exact-output buy | EMBR output | ETH input | Pays input plus 1% | Mint native ERC-6909 claims to hook |
| Exact-input sell | EMBR input | ETH output | Receives output minus 1% | Mint native ERC-6909 claims to hook |
| Exact-output sell | ETH output | EMBR input | Pays input plus 1% | `take` EMBR directly to dead |

In each case the returned unspecified delta is positive. Fee credits are settled during the callback, leaving no unsettled debt. Fee callbacks never send ETH. Dust fees can be zero. The very first buy works against a pool seeded entirely with EMBR and holding no ETH.

State is isolated by `PoolId = keccak256(abi.encode(PoolKey))`. A pool with non-native `currency0` returns zero hook delta and writes no hook state. Native pools using this hook share the implementation but have separate budgets and cooldowns; the token is learned from each key rather than hardcoded.

No user identity or rewards are tracked. `hookData` is ignored and unauthenticated. Putting the hook address or a router address in that data does not grant an exemption. The manager supplies the swap caller; only swaps actually made by the hook itself are fee exempt. The vendored manager also skips self-hook callbacks.

## Buyback lifecycle

Anyone calls `buyback(key)` using the full pool key. The key must reference this hook and native currency0, and its `accruedEth` must be at least **0.001 ETH**. At most one successful buyback per pool per block is allowed. The budget is `min(accruedEth, 0.05 ETH)`.

The hook unlocks the PoolManager, performs an exact-input ETH-to-token swap with `sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1`, burns only the ERC-6909 claims corresponding to the ETH actually spent, and takes all output straight to the dead address. Partial fills preserve unspent claims. Zero-output buybacks revert. State updates and the cooldown revert atomically if the swap or token transfer fails, permitting a retry. ETH never leaves the manager during this operation.

`unlockCallback` accepts only the manager and the one payload authorized by the active buyback. A guard rejects reentry during a buyback. An attempted buyback inside another swap or unlock fails at the manager's lock boundary. There are no external keepers with special rights and no keeper reward; callers pay their own gas.

Ordinary fee collection and buybacks preserve:

```
PoolManager.balanceOf(hook, 0) == sum(accruedEth[each native pool])
```

ERC-6909 claims are freely transferable, so unsolicited claim donations can create a surplus. They are not attributed to any pool and cannot expand its buyback budget; there is no rescue function. With donations the robust invariant is `claims >= sum(accruedEth)`. The tests explicitly cover this caveat. Direct/forced ETH and unrelated tokens likewise do not fund a buyback.

### Residual MEV and token assumptions

The specified buyback has no meaningful minimum output: the extreme price limit allows adverse execution. A searcher can move the price before a public buyback and reverse its trade afterward. The 0.05 ETH cap bounds the hook's expenditure per call and the cooldown bounds frequency per pool; neither guarantees a fair execution price or removes sandwich risk. One test demonstrates lower burned output after adverse price movement while enforcing the spending cap. Callers should inspect liquidity and current conditions and consider private transaction delivery; this is operational mitigation, not a contract guarantee.

The approved EMBR token is a plain ERC-20. Fee-on-transfer, rebasing, blocklisting, or callback-enabled tokens are not supported deployment choices. Adversarial callback tokens are tested to check reentrancy rejection and atomic rollback, not to promise support for arbitrary tokens. Anyone can initialize another pool using the hook; its state remains isolated. The native pool key should be explicitly pinned by clients.

## Reproducible build and tests

Requires Foundry, **Solidity 0.8.26**, and a Cancun-capable EVM. `foundry.toml` pins the compiler, enables the optimizer at 200 runs, and sets `bytecode_hash = "none"`. FFI and filesystem permissions are not enabled. Dependencies are ordinary vendored files, with no submodules or network dependency at build/test time. See `docs/dependencies.json` for the source snapshot and hashes.

```
forge build
forge test
forge fmt --check
python3 scripts/export_abi.py
```

Tests do not use RPC endpoints, environment variables, private keys, or funded accounts. `test/BaseHookTest.sol` is adapted from the pinned Identity-md launch harness to construct the fixed no-argument token and select this hook. It uses an actual deployed PoolManager, static-fee native pools, one-sided token liquidity, and real swap/settlement routers. Hook installation uses the harness's address-aware deployment helper; a separate test also verifies real CREATE2 deployment and rejection of incorrect flags.

Coverage includes all four fee paths and their wallet balances, raw manager swap events, LP fees, fee events, floor rounding, first buys, permission bits, callback authorization, spoofed hookData, cap and threshold, cooldown, self-swap exemption, multi-pool isolation, non-native exclusions, partial fills, missing liquidity, transfer failure, reentrancy, adverse price movement, and token supply/allowances. Stateful fuzzing exercises two pools through all four swap types, buybacks and block changes, checking claim accounting, settled deltas, dead balances, and conservation of ETH and tokens. Invariants use 128 runs of 64 actions with unexpected reverts treated as failures.

The supplied floor suite can be exercised locally from temporary `test/scratch/` copies using compiled creation code and literal metadata instead of environment reads. Those temporary copies are not deliverables and are not required to build this project. The permanent suite independently covers their substantive checks, including the enabled `afterSwap` callback omitted by the floor's callback loop.

## Deployment parameters and handoff

| Parameter | Value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Token artifact | `src/LaunchToken.sol:LaunchToken` |
| Token constructor arguments | None |
| Hook artifact | `src/BuybackBurnHook.sol:BuybackBurnHook` |
| Hook's sole constructor argument | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Required hook address bits | `0x0044` under mask `0x3FFF` |
| Pool currency0 | Native ETH, `address(0)` |
| Pool currency1 | Deployed EMBR address |
| Pool LP fee / tick spacing | `3000` / `60` |
| Liquidity seed | EMBR only, below the initial price |
| Local rehearsal starting tick | `138000` (about 984,000 EMBR per ETH) |

The launch factory must mine CREATE2 using its **actual deploying address**, the final hook creation bytecode, and `abi.encode(PoolManager)`; changing any input changes the required salt/address. `HookMiner` is included in the vendored periphery subset. Confirm `(uint160(hook) & 0x3FFF) == 0x0044`, `getHookPermissions()`, the immutable manager, and the resulting pool key before seeding. Deployment services must verify the configured Sepolia manager and pool parameters against the live chain. Final factory address, salt, deployed addresses, seed amounts, price and block numbers belong to the service deployment record.

The separate manifest assignment writes `launch.json`, including the manager **literal** in `constructorArgs`; it is not generated here. Independent reviewers must inspect the accepted source and manifest, focusing on delta signs, exemption abuse, claim settlement, reentry, and buyback sandwich exposure. Source publication, attestation, policy admission, signed artifact linkage, deployment and frontend hosting are service responsibilities after this stage. Passing local tests is not an independent security review or a live-chain rehearsal.

The frontend service should use a public Sepolia RPC and the ABI exports to display `burnedTotal`, `accruedEth`, eligibility (`accruedEth >= 0.001 ETH` and `lastBuybackBlock != currentBlock`), a public buyback button, and the latest 20 `Buyback` logs filtered by hook and PoolId. Eligibility is a snapshot, not a guarantee that execution will succeed. Export the single page to `dist/index.html` after deployment; no backend is needed.
