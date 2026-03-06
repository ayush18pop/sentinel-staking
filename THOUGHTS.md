# THOUGHTS.md — Sentinel Staking
### `NOTE: I have allowed both native ETH and an ERC20 (LPToken) for staking`
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

but more importantly every function that touches user balances follows the **CEI pattern (Checks-Effects-Interactions)** — meaning all state changes happen before any external call (ETH transfer or ERC-20 transfer). so even if the lock somehow got bypassed, a re-entrant call would see the already-updated balance and revert on the `InsufficientBalance` check. two layers of protection.

the `onTransferReceived` callback (ERC-1363 entry point) also has the `nonReentrancyGuard` on it so a malicious token contract cant re-enter through the callback.

---

## Yul assembly for reward math

the reward formula is simple: `reward = stakedAmount * rate / 100`

solidity 0.8+ handles overflow automatically but the task asked for explicit Yul to handle it. the assembly block:
1. multiplies `amount * rate`
2. checks if `(product / rate) != amount` — if true, overflow happened → `revert(0, 0)`
3. divides by 100

the `revert(0, 0)` emits zero return data (no custom error selector), which is why the overflow test uses bare `vm.expectRevert()` instead of a typed selector.

---

## Gas report

ran `forge test --gas-report` twice — once with Yul, once with plain Solidity `(amount * rate) / 100` — to see the actual difference:

| | Yul | plain Solidity |
|---|---|---|
| `Stake` deployment cost | **2,477,285** | 2,510,475 |
| `Stake` deployment size | **12,817 bytes** | 12,972 bytes |
| `withdrawToken` avg gas | **51,813** | 78,679 |
| `withdrawToken` median gas | **51,113** | 75,958 |
| `withdrawToken` max gas | **101,086** | 111,054 |

Yul wins on every metric. the reason:
- plain Solidity 0.8+ wraps every multiply/divide in checked arithmetic... it adds extra opcodes under the hood to detect overflow and revert. that overhead shows up both at deployment (larger bytecode) and at runtime (~27k more gas per `withdrawToken` call on average)
- the Yul block does the overflow check manually with a single `div`+comparison, which is cheaper than what the Solidity compiler generates

so the Yul version is currently commented out in `Stake.sol` to keep the code readable, but the numbers above justify using it in production.

---

## ERC-1363

normally staking an ERC-20 requires two transactions: `approve` and then `stakeToken`. ERC-1363 adds a `transferAndCall` method to the token itself — when called, it transfers tokens AND immediately calls `onTransferReceived` on the receiving contract, all in one transaction.

`LPToken` inherits from OpenZeppelin's `ERC1363` to get this for free. `Stake` implements `IERC1363Receiver` and handles the callback.

the important guard in `onTransferReceived`:
```solidity
require(msg.sender == address(i_lpToken), "Stake: unknown token");
```
without this, anyone could call the callback directly and fake a deposit without actually sending tokens.

---

## Security notes

| threat | how its handled |
|---|---|
| re-entrancy on ETH withdrawal | CEI + manual `_locked` guard |
| re-entrancy via ERC-1363 callback | `nonReentrancyGuard` on `onTransferReceived` |
| flash loan inflate-and-withdraw | `AlreadyStaked` blocks doubling, 2-day cooldown makes same-block exit impossible |
| front-running reward harvest | cooldown makes block-level timing attacks pointless |
| multisig locking a user forever | flagging only resets cooldown, user can re-request after being unflagged (requires same 2-of-3 threshold) |
| duplicate multisig votes | `signaturesCollected` mapping prevents one owner from voting twice |
| reward math overflow | Yul overflow check reverts cleanly |

