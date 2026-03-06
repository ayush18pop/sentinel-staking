// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Stake} from "../src/Stake.sol";
import {LPToken} from "../src/ERC20Tokens/LPToken.sol";
import {nQToken} from "../src/ERC20Tokens/nQToken.sol";
import {MockRewardOracle} from "../src/Oracles/MockRewardOracle.sol";

contract StakeTest is Test {
    Stake internal stake;
    LPToken internal lpToken;
    nQToken internal nqToken;
    MockRewardOracle internal oracle;

    address internal owner1 = address(0x1);
    address internal owner2 = address(0x2);
    address internal owner3 = address(0x3);
    address internal alice;
    address internal bob;

    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 constant STAKE_AMOUNT = 100 ether;

    function setUp() public virtual {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

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

    function testStakeEth() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();
        vm.stopPrank();
        assertEq(stake.userToEthAmount(alice), STAKE_AMOUNT);
    }

    function testWithdrawRequest() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        assertEq(stake.withdrawRequested(alice), block.timestamp);
    }

    // ─── stakeToken ───────────────────────────────────────────────────────────

    function testStakeToken() public {
        _aliceStakesToken(STAKE_AMOUNT);
        assertEq(stake.userToTokenAmount(alice), STAKE_AMOUNT);
    }

    function testStakeTokenZeroAmountReverts() public {
        vm.startPrank(alice);
        lpToken.approve(address(stake), 0);
        vm.expectRevert(Stake.AmountMustBeGreaterThanZero.selector);
        stake.stakeToken(0);
        vm.stopPrank();
    }

    function testStakeTokenAlreadyStakedReverts() public {
        _aliceStakesToken(STAKE_AMOUNT);
        vm.startPrank(alice);
        lpToken.approve(address(stake), STAKE_AMOUNT);
        vm.expectRevert(Stake.AlreadyStaked.selector);
        stake.stakeToken(STAKE_AMOUNT);
        vm.stopPrank();
    }

    // ─── stakeEth ─────────────────────────────────────────────────────────────

    function testStakeEthZeroValueReverts() public {
        vm.prank(alice);
        vm.expectRevert(Stake.AmountMustBeGreaterThanZero.selector);
        stake.stakeEth{value: 0}();
    }

    function testStakeEthAlreadyStakedReverts() public {
        vm.startPrank(alice);
        stake.stakeEth{value: 1 ether}();
        vm.expectRevert(Stake.AlreadyStaked.selector);
        stake.stakeEth{value: 1 ether}();
        vm.stopPrank();
    }

    // ─── withdrawRequest ──────────────────────────────────────────────────────

    function testWithdrawRequestNoStakeReverts() public {
        vm.prank(alice);
        vm.expectRevert(Stake.NoActiveStake.selector);
        stake.withdrawRequest();
    }

    function testWithdrawRequestAlreadyRequestedReverts() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        vm.prank(alice);
        vm.expectRevert(Stake.WithdrawalAlreadyRequested.selector);
        stake.withdrawRequest();
    }

    // ─── withdrawEth ──────────────────────────────────────────────────────────

    function testWithdrawEth() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();

        vm.prank(alice);
        stake.withdrawRequest();

        _skipCooldown();

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        stake.withdrawEth(STAKE_AMOUNT);
        assertEq(stake.userToEthAmount(alice), 0);
        assertEq(alice.balance, balanceBefore + STAKE_AMOUNT);
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

    function testWithdrawEthNoRequestReverts() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();

        vm.prank(alice);
        vm.expectRevert(Stake.WithdrawalRequestNotFound.selector);
        stake.withdrawEth(STAKE_AMOUNT);
    }

    function testWithdrawEthInsufficientBalanceReverts() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();

        vm.prank(alice);
        stake.withdrawRequest();

        _skipCooldown();

        vm.prank(alice);
        vm.expectRevert(Stake.InsufficientBalance.selector);
        stake.withdrawEth(STAKE_AMOUNT + 1 ether);
    }

    // ─── withdrawToken ────────────────────────────────────────────────────────

    function testWithdrawToken() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        _skipCooldown();

        uint256 lpBalanceBefore = lpToken.balanceOf(alice);
        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT);

        assertEq(stake.userToTokenAmount(alice), 0);
        assertEq(lpToken.balanceOf(alice), lpBalanceBefore + STAKE_AMOUNT);
    }

    function testWithdrawTokenReceivesReward() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        _skipCooldown();

        uint256 nqBalanceBefore = nqToken.balanceOf(alice);
        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT);

        // reward must be > 0 (rate is always >= 1)
        assert(nqToken.balanceOf(alice) > nqBalanceBefore);
    }

    function testWithdrawTokenBeforeCooldownReverts() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        vm.prank(alice);
        vm.expectRevert(Stake.StakeStillLocked.selector);
        stake.withdrawToken(STAKE_AMOUNT);
    }

    function testWithdrawTokenResetsRequestWhenFullyWithdrawn() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        _skipCooldown();

        vm.prank(alice);
        stake.withdrawToken(STAKE_AMOUNT);

        assertEq(stake.withdrawRequested(alice), 0);
    }

    function testWithdrawTokenOverflowReverts() public {
        // Set block.number so rate = 2 (block.number % 10 == 1)
        vm.roll(1);

        // amount * 2 overflows uint256
        uint256 hugeAmount = type(uint256).max / 2 + 1;

        deal(address(lpToken), alice, hugeAmount);

        vm.startPrank(alice);
        lpToken.approve(address(stake), hugeAmount);
        stake.stakeToken(hugeAmount);
        stake.withdrawRequest();
        vm.stopPrank();

        _skipCooldown();

        // Yul revert(0,0) has no selector — bare expectRevert()
        vm.expectRevert();
        vm.prank(alice);
        stake.withdrawToken(hugeAmount);
    }

    // ─── ERC-1363 onTransferReceived ──────────────────────────────────────────

    function testStakeViaTransferAndCall() public {
        vm.startPrank(alice);
        lpToken.transferAndCall(address(stake), STAKE_AMOUNT, "");
        vm.stopPrank();

        assertEq(stake.userToTokenAmount(alice), STAKE_AMOUNT);
    }

    function testOnTransferReceivedUnknownTokenReverts() public {
        // Calling onTransferReceived directly from a non-lpToken address should revert
        vm.prank(alice);
        vm.expectRevert("Stake: unknown token");
        stake.onTransferReceived(alice, alice, STAKE_AMOUNT, "");
    }

    // ─── flagSuspiciousActivity ───────────────────────────────────────────────

    function testFlagSuspiciousActivity() public {
        _aliceStakesToken(STAKE_AMOUNT);

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);

        assertEq(stake.flaggedSuspicious(alice), true);
    }

    function testFlagSuspiciousResetsWithdrawRequest() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);

        assertEq(stake.withdrawRequested(alice), 0);
    }

    function testFlaggedUserCannotWithdrawEth() public {
        vm.prank(alice);
        stake.stakeEth{value: STAKE_AMOUNT}();

        vm.prank(alice);
        stake.withdrawRequest();
        _skipCooldown();

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);

        vm.prank(alice);
        vm.expectRevert("User is flagged as suspicious");
        stake.withdrawEth(STAKE_AMOUNT);
    }

    function testFlaggedUserCannotWithdrawToken() public {
        _aliceStakesToken(STAKE_AMOUNT);
        _aliceRequestsWithdraw();
        _skipCooldown();

        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);

        vm.prank(alice);
        vm.expectRevert("User is flagged as suspicious");
        stake.withdrawToken(STAKE_AMOUNT);
    }

    function testNonOwnerCannotFlag() public {
        vm.prank(alice);
        vm.expectRevert("Not an owner");
        stake.flagSuspiciousActivity(bob);
    }

    // ─── unflagSuspiciousActivity ─────────────────────────────────────────────

    function testUnflagSuspiciousActivity() public {
        // Flag alice first
        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.flagSuspiciousActivity(alice);
        assertEq(stake.flaggedSuspicious(alice), true);

        // Unflag alice
        vm.prank(owner1);
        stake.unflagSuspiciousActivity(alice);
        vm.prank(owner2);
        stake.unflagSuspiciousActivity(alice);
        assertEq(stake.flaggedSuspicious(alice), false);
    }

    function testUnflagNotFlaggedReverts() public {
        vm.prank(owner1);
        vm.expectRevert(Stake.UserNotFlagged.selector);
        stake.unflagSuspiciousActivity(alice);
    }

    function testDuplicateSignatureReverts() public {
        vm.prank(owner1);
        stake.flagSuspiciousActivity(alice);

        vm.prank(owner1);
        vm.expectRevert(Stake.AlreadySigned.selector);
        stake.flagSuspiciousActivity(alice);
    }

}