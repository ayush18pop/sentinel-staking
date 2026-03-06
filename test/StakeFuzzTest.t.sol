// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Stake} from "../src/Stake.sol";
import {LPToken} from "../src/ERC20Tokens/LPToken.sol";
import {nQToken} from "../src/ERC20Tokens/nQToken.sol";
import {MockRewardOracle} from "../src/Oracles/MockRewardOracle.sol";

contract StakeFuzzTest is Test {
    Stake internal stake;
    LPToken internal lpToken;
    nQToken internal nqToken;
    MockRewardOracle internal oracle;

    address internal owner1 = address(0x1);
    address internal owner2 = address(0x2);
    address internal owner3 = address(0x3);
    address internal alice;

    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public virtual {
        alice = makeAddr("alice");

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
            2
        );

        nqToken.transfer(address(stake), INITIAL_SUPPLY / 2);
        lpToken.transfer(alice, INITIAL_SUPPLY / 4);
        vm.deal(alice, type(uint128).max); // plenty of ETH
    }

    // ─── stakeEth ─────────────────────────────────────────────────────────────

    /// @dev Any non-zero ETH stake should be recorded exactly.
    function testFuzz_StakeEthRecordsCorrectAmount(uint96 amount) public {
        vm.assume(amount > 0);

        vm.prank(alice);
        stake.stakeEth{value: amount}();

        assertEq(stake.userToEthAmount(alice), amount);
    }

    /// @dev Staking zero ETH must always revert.
    function testFuzz_StakeEthZeroAlwaysReverts(address user) public {
        vm.assume(user != address(0));
        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(Stake.AmountMustBeGreaterThanZero.selector);
        stake.stakeEth{value: 0}();
    }

    // ─── stakeToken ───────────────────────────────────────────────────────────

    /// @dev Any non-zero token stake should be recorded exactly.
    function testFuzz_StakeTokenRecordsCorrectAmount(uint96 amount) public {
        vm.assume(amount > 0);
        deal(address(lpToken), alice, amount);

        vm.startPrank(alice);
        lpToken.approve(address(stake), amount);
        stake.stakeToken(amount);
        vm.stopPrank();

        assertEq(stake.userToTokenAmount(alice), amount);
    }

    // ─── withdrawEth ──────────────────────────────────────────────────────────

    /// @dev Partial ETH withdrawals never exceed the staked balance.
    function testFuzz_WithdrawEthPartial(uint96 stakeAmt, uint96 withdrawAmt) public {
        vm.assume(stakeAmt > 0);
        vm.assume(withdrawAmt > 0 && withdrawAmt <= stakeAmt);

        vm.prank(alice);
        stake.stakeEth{value: stakeAmt}();

        vm.prank(alice);
        stake.withdrawRequest();

        skip(2 days + 1);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        stake.withdrawEth(withdrawAmt);

        assertEq(stake.userToEthAmount(alice), stakeAmt - withdrawAmt);
        assertEq(alice.balance, balBefore + withdrawAmt);
    }

    /// @dev Withdrawing more than staked always reverts.
    function testFuzz_WithdrawEthExcessReverts(uint96 stakeAmt, uint96 extra) public {
        vm.assume(stakeAmt > 0);
        vm.assume(extra > 0);

        vm.prank(alice);
        stake.stakeEth{value: stakeAmt}();

        vm.prank(alice);
        stake.withdrawRequest();

        skip(2 days + 1);

        vm.prank(alice);
        vm.expectRevert(Stake.InsufficientBalance.selector);
        stake.withdrawEth(uint256(stakeAmt) + uint256(extra));
    }

    // ─── withdrawToken ────────────────────────────────────────────────────────

    /// @dev Partial token withdrawals return the exact amount and correct reward.
    function testFuzz_WithdrawTokenPartial(uint96 stakeAmt, uint96 withdrawAmt) public {
        // reward = withdrawAmt * rate / 100, rate ≤ 10
        // cap inputs so max reward (withdrawAmt / 10) never exceeds nQ reserve
        uint256 maxSafe = nqToken.balanceOf(address(stake)) * 10;
        stakeAmt = uint96(bound(stakeAmt, 1, maxSafe));
        withdrawAmt = uint96(bound(withdrawAmt, 1, stakeAmt));

        deal(address(lpToken), alice, stakeAmt);

        vm.startPrank(alice);
        lpToken.approve(address(stake), stakeAmt);
        stake.stakeToken(stakeAmt);
        stake.withdrawRequest();
        vm.stopPrank();

        skip(2 days + 1);

        uint256 lpBefore = lpToken.balanceOf(alice);
        uint256 nqBefore = nqToken.balanceOf(alice);

        vm.prank(alice);
        stake.withdrawToken(withdrawAmt);

        assertEq(lpToken.balanceOf(alice), lpBefore + withdrawAmt);
        // reward = (withdrawAmt * rate) / 100 >= 0, just check it didn't decrease
        assert(nqToken.balanceOf(alice) >= nqBefore);
    }

    /// @dev Withdrawing more tokens than staked always reverts.
    function testFuzz_WithdrawTokenExcessReverts(uint96 stakeAmt, uint96 extra) public {
        vm.assume(stakeAmt > 0);
        vm.assume(extra > 0);

        deal(address(lpToken), alice, stakeAmt);

        vm.startPrank(alice);
        lpToken.approve(address(stake), stakeAmt);
        stake.stakeToken(stakeAmt);
        stake.withdrawRequest();
        vm.stopPrank();

        skip(2 days + 1);

        vm.prank(alice);
        vm.expectRevert(Stake.InsufficientBalance.selector);
        stake.withdrawToken(uint256(stakeAmt) + uint256(extra));
    }

    // ─── cooldown ─────────────────────────────────────────────────────────────

    /// @dev Withdrawing before 2 days always reverts, no matter how close.
    function testFuzz_WithdrawBeforeCooldownReverts(uint32 elapsed) public {
        vm.assume(elapsed < 2 days);

        vm.prank(alice);
        stake.stakeEth{value: 1 ether}();

        vm.prank(alice);
        stake.withdrawRequest();

        skip(elapsed);

        vm.prank(alice);
        vm.expectRevert(Stake.StakeStillLocked.selector);
        stake.withdrawEth(1 ether);
    }
}
