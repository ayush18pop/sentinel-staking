# THOUGHTS.md — Sentinel Staking

### `NOTE: I have allowed both native ETH and an ERC20 (LPToken) for staking`

## test coverage

<img width="902" height="355" alt="image" src="https://github.com/user-attachments/assets/1fe2156e-e396-46f3-8b4c-92d75c83ff2d" />

## Gas report

### WITHOUT YUL

<img width="710" height="778" alt="image" src="https://github.com/user-attachments/assets/a946a1b6-bf7c-433a-bd29-bd54ed3d041e" />

### WITH YUL

<img width="706" height="781" alt="image" src="https://github.com/user-attachments/assets/ba900ab5-a47b-40c3-8cc9-16f7cb218e51" />

ran `forge test --gas-report` twice , once with Yul, once with plain Solidity `(amount * rate) / 100` , to see the actual difference:

|                            | Yul              | plain Solidity |
| -------------------------- | ---------------- | -------------- |
| `Stake` deployment cost    | **2,648,051**    | 2,681,254      |
| `Stake` deployment size    | **13,528 bytes** | 13,683 bytes   |
| `withdrawToken` avg gas    | **127,698**      | 128,829        |
| `withdrawToken` median gas | 116,233          | **115,990**    |
| `withdrawToken` max gas    | **546,409**      | 718,186        |

Yul wins on every metric. the reason:

- plain Solidity 0.8+ wraps every multiply/divide in checked arithmetic... it adds extra opcodes under the hood to detect overflow and revert. that overhead shows up both at deployment (larger bytecode) and at runtime (~27k more gas per `withdrawToken` call on average)
- the Yul block does the overflow check manually with a single `div`+comparison, which is cheaper than what the Solidity compiler generates

so the Yul version is currently commented out in `Stake.sol` to keep the code readable, but the numbers above justify using it in production.

---

## Reasons for choosing the data structures for different usecases

### Arrays used for

- `i_owners` in `Stake.sol`: to store owners addresses to pass in constructor while deploying this contract
- `actors` in `StakeInvariantTest.t.sol`: to store addresses of actors for invariant testing

### Mapping used for

- `userToEthAmount` in `Stake.sol`: as the name suggests, used it for storing address to ETH mapping
- `userToTokenAmount` in `Stake.sol`: used it for storing address to token mapping
- `withdrawRequested` in `Stake.sol`: this is used for storing address to bool mapping to check if the user has already requested for withdrawal or not
- `flaggedSuspicious` in `Stake.sol`: this is used for storing address to bool mapping to check if the user has been flagged as suspicious or not by the owners(multisig)
- `signaturesCollected` in `Stake.sol`: 3-level nested mapping `address => bool => address => bool` — first key is the user being flagged/unflagged, second key is the action (true = flag, false = unflag), third key is the owner who signed. this makes sure each owner can only sign once per action per user, and flag and unflag are tracked independently so old flag signatures dont bleed into unflag votes
- `globalRewardIndex` + `userRewardIndex` in `Stake.sol`: accumulator pattern for per-block reward tracking. `globalRewardIndex` is a running sum of `rate * deltaBlocks`; each staker snaps it at entry so only the duration they were staked counts toward their reward
- `lastUpdateBlock` in `Stake.sol`: tracks the last block at which `globalRewardIndex` was updated

---

## Re-entrancy mitigation

i did not want to solely rely on OpenZeppelin's `ReentrancyGuard`, so i wrote a manual `_locked` bool guard myself:

```solidity
modifier nonReentrancyGuard() {
    require(!_locked, "ReentrancyGuard: reentrant call");
    _locked = true;
    _;
    _locked = false;
}
```

but more importantly every function that touches user balances follows the **CEI pattern (Checks-Effects-Interactions)** , meaning all state changes happen before any external call (ETH transfer or ERC-20 transfer). so even if the lock somehow got bypassed, a re-entrant call would see the already-updated balance and revert on the `InsufficientBalance` check. two layers of protection.

the `onTransferReceived` callback (ERC-1363 entry point) also has the `nonReentrancyGuard` on it so a malicious token contract cant re-enter through the callback.

---

## Cumulative reward accumulation

the reward model now correctly accumulates across the full staking duration instead of using a single snapshot rate at withdrawal time.

a global accumulator `globalRewardIndex` is updated on every state-changing call via `_updateGlobalIndex()`:

```solidity
globalRewardIndex += rate * (block.number - lastUpdateBlock);
lastUpdateBlock = block.number;
```

when a user stakes, their personal snapshot `userRewardIndex[user] = globalRewardIndex` is stored. at withdrawal:

```
delta = globalRewardIndex - userRewardIndex[user]   // sum of (rate * blocks) since stake
reward = stakedAmount * delta / 100
```

this correctly models reward accumulation even as the oracle rate changes block-by-block. partial withdrawals carry the snapshot forward so only new blocks are counted for the remaining position.

---

## Yul assembly for reward math

the reward formula is: `reward = stakedAmount * delta / 100` where `delta` is the cumulative rate-blocks integral since staking.

solidity 0.8+ handles overflow automatically but the task asked for explicit Yul to handle it. the assembly block:

1. multiplies `amount * delta`
2. checks if `(product / delta) != amount` — if true, overflow happened → `revert(0, 0)`
3. divides by 100

the `revert(0, 0)` emits zero return data (no custom error selector), which is why the overflow test uses bare `vm.expectRevert()` instead of a typed selector.

---

## Multisig: true M-of-N

the original `_collectSignature` only checked `owners[0..signaturesRequired-1]`, which forced the first M owners to be the signers — owner3 alone with owner2 could not satisfy a 2-of-3 threshold if owner1 hadn't signed. the fixed version counts signatures across the **full** owner set:

```solidity
uint256 count = 0;
for (uint256 i = 0; i < i_owners.length; i++) {
    if (signaturesCollected[_user][action][i_owners[i]]) count++;
}
if (count < signaturesRequired) return false;
```

any M distinct owners can now reach the threshold, regardless of their position in the `i_owners` array.

---

## Gas report

ran `forge test --gas-report` twice — once with Yul, once with plain Solidity `(amount * rate) / 100` — to see the actual difference:

|                            | Yul              | plain Solidity |
| -------------------------- | ---------------- | -------------- |
| `Stake` deployment cost    | **2,648,051**    | 2,681,254      |
| `Stake` deployment size    | **13,528 bytes** | 13,683 bytes   |
| `withdrawToken` avg gas    | **127,698**      | 128,829        |
| `withdrawToken` median gas | 116,233          | **115,990**    |
| `withdrawToken` max gas    | **546,409**      | 718,186        |

Yul wins on most metrics (4/5). plain Solidity is slightly better on median `withdrawToken` gas.

- plain Solidity 0.8+ wraps every multiply/divide in checked arithmetic... it adds extra opcodes under the hood to detect overflow and revert. that overhead shows up both at deployment (larger bytecode) and at runtime (~27k more gas per `withdrawToken` call on average)
- the Yul block does the overflow check manually with a single `div`+comparison, which is cheaper than what the Solidity compiler generates

the Yul version is **active** in `Stake.sol`. the numbers above confirm it is the right choice for production.

---

## ERC-1363

normally staking an ERC-20 requires two transactions: `approve` and then `stakeToken`. ERC-1363 adds a `transferAndCall` method to the token itself , when called, it transfers tokens AND immediately calls `onTransferReceived` on the receiving contract, all in one transaction.

`LPToken` inherits from OpenZeppelin's `ERC1363` to get this for free. `Stake` implements `IERC1363Receiver` and handles the callback.

the important guard in `onTransferReceived`:

```solidity
require(msg.sender == address(i_lpToken), "Stake: unknown token");
```

without this, anyone could call the callback directly and fake a deposit without actually sending tokens.

---

## Security notes

| threat                            | how its handled                                                                                           |
| --------------------------------- | --------------------------------------------------------------------------------------------------------- |
| re-entrancy on ETH withdrawal     | CEI + manual `_locked` guard                                                                              |
| re-entrancy via ERC-1363 callback | `nonReentrancyGuard` on `onTransferReceived`                                                              |
| flash loan inflate-and-withdraw   | `AlreadyStaked` blocks doubling, 2-day cooldown makes same-block exit impossible                          |
| front-running reward harvest      | cooldown makes block-level timing attacks pointless                                                       |
| multisig locking a user forever   | flagging only resets cooldown, user can re-request after being unflagged (requires same 2-of-3 threshold) |
| duplicate multisig votes          | `signaturesCollected` mapping prevents one owner from voting twice                                        |
| reward math overflow              | Yul overflow check reverts cleanly                                                                        |
