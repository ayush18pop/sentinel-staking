// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Stake} from "../src/Stake.sol";
import {LPToken} from "../src/ERC20Tokens/LPToken.sol";
import {nQToken} from "../src/ERC20Tokens/nQToken.sol";
import {MockRewardOracle} from "../src/Oracles/MockRewardOracle.sol";
import {IRewardOracle} from "../src/Oracles/IRewardOracle.sol";

contract ReturnFalseToken {
    bool private _transferFromReturn;
    bool private _transferReturn;

    constructor(bool transferFromReturn, bool transferReturn) {
        _transferFromReturn = transferFromReturn;
        _transferReturn = transferReturn;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        return _transferFromReturn;
    }

    function transfer(address, uint256) external returns (bool) {
        return _transferReturn;
    }

    function approve(address, uint256) external returns (bool) {
        return true;
    }
}

contract RejectEtherReceiver {
    Stake public stake;

    constructor(Stake _stake) {
        stake = _stake;
    }

    function stakeAndRequest() external payable {
        stake.stakeEth{value: msg.value}();
        stake.withdrawRequest();
    }

    function withdraw(uint256 amount) external {
        stake.withdrawEth(amount);
    }

    receive() external payable {
        revert("reject");
    }
}

contract ReentrantWithdrawer {
    Stake public stake;
    bool public reenterFailed;

    constructor(Stake _stake) {
        stake = _stake;
    }

    function stakeAndRequest() external payable {
        stake.stakeEth{value: msg.value}();
        stake.withdrawRequest();
    }

    function withdraw(uint256 amount) external {
        stake.withdrawEth(amount);
    }

    receive() external payable {
        try stake.withdrawEth(1) {
            // Should never succeed due to reentrancy guard.
        } catch {
            reenterFailed = true;
        }
    }
}

contract HugeRateOracle is IRewardOracle {
    uint256 public rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function getRewardRate() external view returns (uint256) {
        return rate;
    }

    function getCumulativeRate(uint256, uint256) external view returns (uint256) {
        return rate;
    }
}


contract StakeTest is Test {
    Stake internal stake;
    LPToken internal lpToken;
    nQToken internal nqToken;
    MockRewardOracle internal oracle;

    address internal owner1 = address(0x1);
    address internal owner2 = address(0x2);
    address internal owner3 = address(0x3);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 constant STAKE_AMOUNT = 100 ether;

    function setUp() public virtual {
        oracle = new MockRewardOracle();
        lpToken = new LPToken(INITIAL_SUPPLY);
        nqToken = new nQToken(INITIAL_SUPPLY);

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        stake = new Stake(
            address(lpToken),
            address(nqToken),
            address(oracle),
            owners,
            2 // require 2-of-3 signatures
        );

        // Fund the stake contract with nQToken rewards
        nqToken.transfer(address(stake), INITIAL_SUPPLY / 2);

        // Give alice and bob LP tokens
        lpToken.transfer(alice, STAKE_AMOUNT * 10);
        lpToken.transfer(bob, STAKE_AMOUNT * 10);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /// @dev Fast-forward time past the 2-day cooldown
    function _skipCooldown() internal {
        skip(2 days + 1);
    }

    /// @dev Have alice stake via approve + stakeToken
    function _aliceStakesToken(uint256 amount) internal {
        vm.startPrank(alice);
        lpToken.approve(address(stake), amount);
        stake.stakeToken(amount);
        vm.stopPrank();
    }

    /// @dev Have alice request a withdrawal
    function _aliceRequestsWithdraw() internal {
        vm.prank(alice);
        stake.withdrawRequest();
    }

    // ─── Staking ───────────────────────────────────────────────────────────────

    function testStakeEth() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();
        assertEq(stake.userToEthAmount(alice), STAKE_AMOUNT);
    }

    function testStakeToken() public {
        _aliceStakesToken(STAKE_AMOUNT);
        assertEq(stake.userToTokenAmount(alice), STAKE_AMOUNT);
    }

    function testStakeTokenViaERC1363() public {
        vm.prank(alice);
        lpToken.transferAndCall(address(stake), STAKE_AMOUNT, "");
        assertEq(stake.userToTokenAmount(alice), STAKE_AMOUNT);
    }

    function testCannotDoubleStakeToken() public {
        _aliceStakesToken(STAKE_AMOUNT);
        vm.startPrank(alice);
        lpToken.approve(address(stake), STAKE_AMOUNT);
        vm.expectRevert(Stake.AlreadyStaked.selector);
        stake.stakeToken(STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testCannotStakeZeroEth() public {
        vm.prank(alice);
        vm.expectRevert(Stake.AmountMustBeGreaterThanZero.selector);
        stake.stakeEth{value: 0}();
    }

    // ─── Withdrawal request ────────────────────────────────────────────────────

    function testWithdrawRequest() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        assertEq(stake.withdrawRequested(alice), block.timestamp);
    }

    function testCannotRequestWithdrawTwice() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        vm.prank(alice);
        vm.expectRevert(Stake.WithdrawalAlreadyRequested.selector);
        stake.withdrawRequest();
    }

    function testCannotRequestWithdrawWithNoStake() public {
        vm.prank(alice);
        vm.expectRevert(Stake.NoActiveStake.selector);
        stake.withdrawRequest();
    }

    // ─── ETH withdrawal ────────────────────────────────────────────────────────

    function testWithdrawEth() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();

        vm.prank(alice);
        stake.withdrawRequest();

        _skipCooldown();

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        stake.withdrawEth(STAKE_AMOUNT);

        assertEq(alice.balance, balBefore + STAKE_AMOUNT);
        assertEq(stake.userToEthAmount(alice), 0);
    }

    function testWithdrawEthBeforeCooldownReverts() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();

        vm.prank(alice);
        stake.withdrawRequest();

        vm.prank(alice);
        vm.expectRevert(Stake.StakeStillLocked.selector);
        stake.withdrawEth(STAKE_AMOUNT);
    }

    // ─── Token withdrawal + cumulative rewards ─────────────────────────────────

    function testWithdrawTokenPaysReward() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        uint256 stakeBlock = block.number;
        _skipCooldown();
        // Roll forward some blocks so accumulator has non-zero delta
        vm.roll(block.number + 10);

        uint256 withdrawBlock = block.number;
        uint256 expectedDelta = _computeExpectedDelta(stakeBlock, withdrawBlock);
        uint256 expectedReward = STAKE_AMOUNT * expectedDelta / 100;

        uint256 nqBefore = nqToken.balanceOf(alice);
        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT);

        assertEq(nqToken.balanceOf(alice) - nqBefore, expectedReward);
        assertEq(stake.userToTokenAmount(alice), 0);
    }

    /// @dev Reward must be strictly larger when more blocks elapse between stake and withdraw.
    function testRewardAccumulatesWithBlocks() public {
        // Alice stakes at block B
        _aliceStakesToken(STAKE_AMOUNT);

        // Bob stakes 50 blocks later
        vm.roll(block.number + 50);
        vm.startPrank(bob);
        lpToken.approve(address(stake), STAKE_AMOUNT);
        stake.stakeToken(STAKE_AMOUNT);
        vm.stopPrank();

        // Both request withdrawal and wait the 2-day cooldown
        _aliceRequestsWithdraw();
        vm.prank(bob);
        stake.withdrawRequest();
        _skipCooldown();

        // Roll forward more blocks then both withdraw
        vm.roll(block.number + 100);

        uint256 nqAliceBefore = nqToken.balanceOf(alice);
        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT);

        uint256 nqBobBefore = nqToken.balanceOf(bob);
        vm.prank(bob);
        stake.withdrawToken(STAKE_AMOUNT);

        // Alice staked for more blocks so her reward must be strictly greater
        assertTrue(nqToken.balanceOf(alice) - nqAliceBefore > nqToken.balanceOf(bob) - nqBobBefore);
    }

    function testPartialWithdrawCarriesForwardSnapshot() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        _skipCooldown();
        vm.roll(block.number + 20);

        // Partial withdraw — half the stake
        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT / 2);

        // Roll more blocks then withdraw the rest
        vm.roll(block.number + 20);
        uint256 nqBefore = nqToken.balanceOf(alice);
        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT / 2);

        // Reward for second half should only cover the second 20-block window
        assertTrue(nqToken.balanceOf(alice) - nqBefore > 0);
    }

    // ─── Multisig: true M-of-N ────────────────────────────────────────────────

    /// @dev Signing must work with any combination of M owners, not just the first M.
    ///      Here owner3 (index 2) and owner1 (index 0) flag alice — previously only
    ///      owners[0..signaturesRequired-1] were checked so owner3 alone was insufficient.
    function testFlagWithAnyTwoOwners_owner2AndOwner3() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        // owner2 and owner3 sign — NOT owner1 (the "first" required owner under the buggy code)
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);
        assertFalse(stake.flaggedSuspicious(alice)); // not yet

        vm.prank(owner3);
        stake.flagSuspiciousActivity(alice);
        assertTrue(stake.flaggedSuspicious(alice)); // now flagged via owner2+owner3
    }

    function testFlagWithOwner1AndOwner3() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        assertFalse(stake.flaggedSuspicious(alice));

        vm.prank(owner3);
        stake.flagSuspiciousActivity(alice);
        assertTrue(stake.flaggedSuspicious(alice));
    }

    function testFlagResetsCooldown() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);

        assertEq(stake.withdrawRequested(alice), 0);
    }

    function testFlaggedUserCannotWithdraw() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);

        _skipCooldown();
        vm.prank(alice);
        vm.expectRevert("User is flagged as suspicious");
        stake.withdrawToken(STAKE_AMOUNT);
    }

    function testUnflagRestoresWithdrawalAbility() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        // Flag
        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);

        // Unflag
        vm.prank(owner2);
        stake.unflagSuspiciousActivity(alice);
        vm.prank(owner3);
        stake.unflagSuspiciousActivity(alice);

        assertFalse(stake.flaggedSuspicious(alice));

        // Alice re-requests and waits cooldown
        vm.prank(alice);
        stake.withdrawRequest();
        _skipCooldown();
        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT); // must not revert
    }

    function testDuplicateSignatureReverts() public {
        _aliceStakesToken(STAKE_AMOUNT);

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);

        vm.prank(owner1);
        vm.expectRevert(Stake.AlreadySigned.selector);
        stake.flagSuspiciousActivity(alice);
    }

    function testNonOwnerCannotFlag() public {
        _aliceStakesToken(STAKE_AMOUNT);
        vm.prank(alice);
        vm.expectRevert("Not an owner");
        stake.flagSuspiciousActivity(bob);
    }

    // ─── Coverage edge cases ──────────────────────────────────────────────────

    function testConstructorRevertsWithNoOwners() public {
        address[] memory owners = new address[](0);
        vm.expectRevert("No owners provided");
        new Stake(address(lpToken), address(nqToken), address(oracle), owners, 1);
    }

    function testConstructorRevertsWithZeroSignatures() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert("Invalid signaturesRequired");
        new Stake(address(lpToken), address(nqToken), address(oracle), owners, 0);
    }

    function testConstructorRevertsWithTooManySignatures() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert("Invalid signaturesRequired");
        new Stake(address(lpToken), address(nqToken), address(oracle), owners, 2);
    }

    function testStakeTokenTransferFromFalseReverts() public {
        ReturnFalseToken badLp = new ReturnFalseToken(false, true);
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        Stake s = new Stake(address(badLp), address(nqToken), address(oracle), owners, 1);

        vm.expectRevert(Stake.TransferFailed.selector);
        s.stakeToken(1 ether);
    }

    function testWithdrawEthTransferFailedReverts() public {
        RejectEtherReceiver rejector = new RejectEtherReceiver(stake);
        vm.deal(address(rejector), STAKE_AMOUNT);

        rejector.stakeAndRequest{value: STAKE_AMOUNT}();
        _skipCooldown();

        vm.expectRevert(Stake.TransferFailed.selector);
        rejector.withdraw(STAKE_AMOUNT);
    }

    function testReentrancyGuardBlocksWithdrawEth() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(stake);
        vm.deal(address(attacker), STAKE_AMOUNT);

        attacker.stakeAndRequest{value: STAKE_AMOUNT}();
        _skipCooldown();
        attacker.withdraw(STAKE_AMOUNT);

        assertTrue(attacker.reenterFailed());
    }

    function testReentrancyGuardRevertsWhenLocked() public {
        // _locked is at storage slot 9 (see forge inspect).
        vm.store(address(stake), bytes32(uint256(9)), bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        stake.stakeEth{value: 1 ether}();
    }

    function testWithdrawTokenWithoutRequestReverts() public {
        _aliceStakesToken(STAKE_AMOUNT);
        vm.prank(alice);
        vm.expectRevert(Stake.WithdrawalRequestNotFound.selector);
        stake.withdrawToken(STAKE_AMOUNT);
    }

    function testWithdrawTokenOverflowReverts() public {
        HugeRateOracle huge = new HugeRateOracle(type(uint256).max);
        LPToken lp = new LPToken(100 ether);
        nQToken nq = new nQToken(100 ether);
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        Stake s = new Stake(address(lp), address(nq), address(huge), owners, 1);

        nq.transfer(address(s), 100 ether);
        lp.transfer(alice, 2);

        vm.startPrank(alice);
        lp.approve(address(s), 2);
        s.stakeToken(2);
        s.withdrawRequest();
        vm.stopPrank();

        _skipCooldown();
        vm.roll(block.number + 1);

        // Cover getRewardRate as well.
        huge.getRewardRate();

        vm.prank(alice);
        vm.expectRevert();
        s.withdrawToken(2);
    }

    function testWithdrawTokenLpTransferFails() public {
        ReturnFalseToken badLp = new ReturnFalseToken(true, false);
        ReturnFalseToken goodNq = new ReturnFalseToken(true, true);
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        Stake s = new Stake(address(badLp), address(goodNq), address(oracle), owners, 1);

        vm.startPrank(alice);
        badLp.approve(address(s), 1);
        s.stakeToken(1);
        s.withdrawRequest();
        vm.stopPrank();

        _skipCooldown();

        vm.prank(alice);
        vm.expectRevert(Stake.TransferFailed.selector);
        s.withdrawToken(1);
    }

    function testWithdrawTokenNqTransferFails() public {
        ReturnFalseToken goodLp = new ReturnFalseToken(true, true);
        ReturnFalseToken badNq = new ReturnFalseToken(true, false);
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        Stake s = new Stake(address(goodLp), address(badNq), address(oracle), owners, 1);

        vm.startPrank(alice);
        goodLp.approve(address(s), 1);
        s.stakeToken(1);
        s.withdrawRequest();
        vm.stopPrank();

        _skipCooldown();

        vm.prank(alice);
        vm.expectRevert(Stake.TransferFailed.selector);
        s.withdrawToken(1);
    }

    function testOnTransferReceivedZeroValueReverts() public {
        vm.prank(address(lpToken));
        vm.expectRevert(Stake.AmountMustBeGreaterThanZero.selector);
        stake.onTransferReceived(address(0), alice, 0, "");
    }

    function testOnTransferReceivedAlreadyStakedReverts() public {
        _aliceStakesToken(STAKE_AMOUNT);
        vm.prank(address(lpToken));
        vm.expectRevert(Stake.AlreadyStaked.selector);
        stake.onTransferReceived(address(0), alice, STAKE_AMOUNT, "");
    }

    function testMockOracleCumulativeRate() public {
        uint256 total = oracle.getCumulativeRate(1, 4); // blocks 1,2,3
        assertEq(total, 2 + 3 + 4);
        assertTrue(oracle.getRewardRate() >= 1);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Mirrors _updateGlobalIndex logic for the oracle: rate = (blockNumber % 10) + 1.
    ///      Computes the cumulative rate-blocks integral from stakeBlock to withdrawBlock.
    function _computeExpectedDelta(uint256 fromBlock, uint256 toBlock) internal pure returns (uint256 delta) {
        for (uint256 b = fromBlock; b < toBlock; b++) {
            delta += (b % 10) + 1;
        }
    }
}
