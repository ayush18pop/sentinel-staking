# Ayush Submission Audit & Scorecard

## Verdict
**Pass (conditional)** — **74 / 100**.

The submission demonstrates good effort and includes several advanced requirements (manual reentrancy guard, Yul math with overflow checks, ERC-1363 integration, fuzz + invariant suites, and a documented gas comparison). However, one major functional requirement is only partially met (true reward accumulation), and there is a multisig-threshold correctness issue in signature collection.

## Scoring Rubric

### 1) Core staking + dynamic reward source (30 pts)
- **What was required**: LP staking with rewards accumulating against a block-varying oracle rate.
- **What was delivered**:
  - LP staking is implemented (`stakeToken`) and rewards are paid on token withdrawal (`withdrawToken`).
  - Oracle changes by block (`MockRewardOracle.getRewardRate()`).
  - **Gap**: reward is computed from a single rate at withdrawal time (`amount * currentRate / 100`) rather than accumulating across staking duration / changing rates.
- **Score**: **18 / 30**

### 2) Cooldown + suspicious-withdrawal control (25 pts)
- **What was required**: 2-day cooldown after withdrawal request; multisig can flag suspicious requests and reset cooldown.
- **What was delivered**:
  - 2-day cooldown enforced before withdrawal.
  - Multisig flagging exists and zeroes withdrawal request.
  - **Issue**: `_collectSignature` checks only the first `signaturesRequired` owners, not any arbitrary `M-of-N`, causing threshold semantics to be incorrect when more owners exist than required signatures.
- **Score**: **18 / 25**

### 3) Anti-AI component: Yul math + ERC-1363 (20 pts)
- **What was required**: use Yul in withdrawal for gas optimization with safe overflow handling + rarely used ERC standard.
- **What was delivered**:
  - Yul-based reward math with manual overflow detection and revert.
  - ERC-1363 implemented through LP token + receiver callback.
- **Score**: **20 / 20**

### 4) Test quality (including fuzz/invariants) + coverage (15 pts)
- **What was required**: 100% coverage including fuzzing/invariant tests.
- **What was delivered**:
  - Unit tests, fuzz tests, and invariant tests are present.
  - `lcov.info` indicates 100% line coverage for contract files.
  - **Gap**: no test appears to catch the multisig first-N-owner threshold bug.
- **Score**: **14 / 15**

### 5) Deliverables quality: gas report + THOUGHTS.md rationale (10 pts)
- **What was required**: gas report + design/security rationale.
- **What was delivered**:
  - THOUGHTS explains mapping/arrays, reentrancy posture, and gas comparisons.
  - Minor inconsistency in THOUGHTS says Yul is commented out, while Yul is currently active in `Stake.sol`.
- **Score**: **4 / 10**

## Key Findings

### High impact
1. **Reward accumulation is not time-based / per-block cumulative**
   - Current implementation calculates reward only at withdrawal from the *instantaneous* oracle rate, which does not model accumulation as rate changes over staking duration.

2. **Multisig threshold logic is not true M-of-N**
   - `_collectSignature` checks only owners in `[0..signaturesRequired-1]`, effectively forcing signatures from a fixed subset.

### Medium impact
3. **Oracle is tightly coupled to concrete mock type**
   - `Stake` stores `MockRewardOracle` directly, not an interface-based oracle abstraction.

### Low impact
4. **Documentation inconsistency**
   - THOUGHTS states Yul code is commented out; code currently has active Yul block.

## Pass/Fail Recommendation
- **Pass (conditional)** at **74/100**.
- Candidate demonstrates strong Solidity capability and security awareness, but should be asked to fix:
  1) cumulative reward accounting model,
  2) multisig threshold correctness (true M-of-N over full owner set),
  before production acceptance.
