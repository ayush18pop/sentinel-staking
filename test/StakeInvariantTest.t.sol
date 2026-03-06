// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Stake} from "../src/Stake.sol";
import {LPToken} from "../src/ERC20Tokens/LPToken.sol";
import {nQToken} from "../src/ERC20Tokens/nQToken.sol";
import {MockRewardOracle} from "../src/Oracles/MockRewardOracle.sol";

/// @dev Handler exposes bounded actions so the fuzzer only calls valid entry points.
contract StakeHandler is Test {
    Stake public stake;
    LPToken public lpToken;
    nQToken public nqToken;

    address[] public actors;
    address internal _currentActor;

    // Track ghost sums to verify invariants
    uint256 public ghost_totalEthStaked;
    uint256 public ghost_totalTokenStaked;

    constructor(Stake _stake, LPToken _lpToken, nQToken _nqToken, address[] memory _actors) {
        stake = _stake;
        lpToken = _lpToken;
        nqToken = _nqToken;
        actors = _actors;
    }

    modifier useActor(uint256 actorSeed) {
        _currentActor = actors[actorSeed % actors.length];
        vm.startPrank(_currentActor);
        _;
        vm.stopPrank();
    }

    function stakeEth(uint256 actorSeed, uint96 amount) external useActor(actorSeed) {
        amount = uint96(bound(amount, 1, 10 ether));
        if (stake.userToEthAmount(_currentActor) != 0) return; // already staked
        vm.deal(_currentActor, amount);
        stake.stakeEth{value: amount}();
        ghost_totalEthStaked += amount;
    }

    function stakeToken(uint256 actorSeed, uint96 amount) external useActor(actorSeed) {
        amount = uint96(bound(amount, 1, 1_000 ether));
        if (stake.userToTokenAmount(_currentActor) != 0) return; // already staked
        deal(address(lpToken), _currentActor, amount);
        lpToken.approve(address(stake), amount);
        stake.stakeToken(amount);
        ghost_totalTokenStaked += amount;
    }

    function requestWithdraw(uint256 actorSeed) external useActor(actorSeed) {
        if (stake.userToEthAmount(_currentActor) == 0 && stake.userToTokenAmount(_currentActor) == 0) return;
        if (stake.withdrawRequested(_currentActor) != 0) return;
        stake.withdrawRequest();
    }

    function withdrawEth(uint256 actorSeed, uint96 amount) external useActor(actorSeed) {
        if (stake.withdrawRequested(_currentActor) == 0) return;
        if (block.timestamp - stake.withdrawRequested(_currentActor) < 2 days) return;
        if (stake.flaggedSuspicious(_currentActor)) return;
        uint256 bal = stake.userToEthAmount(_currentActor);
        if (bal == 0) return;
        amount = uint96(bound(amount, 1, bal));
        stake.withdrawEth(amount);
        ghost_totalEthStaked -= amount;
    }

    function withdrawToken(uint256 actorSeed, uint96 amount) external useActor(actorSeed) {
        if (stake.withdrawRequested(_currentActor) == 0) return;
        if (block.timestamp - stake.withdrawRequested(_currentActor) < 2 days) return;
        if (stake.flaggedSuspicious(_currentActor)) return;
        uint256 bal = stake.userToTokenAmount(_currentActor);
        if (bal == 0) return;
        // avoid overflow in Yul: rate is 1-10, so cap amount
        uint256 rate = (block.number % 10) + 1;
        if (bal > type(uint256).max / rate) return;
        amount = uint96(bound(amount, 1, bal > type(uint96).max ? type(uint96).max : bal));
        stake.withdrawToken(amount);
        ghost_totalTokenStaked -= amount;
    }

    function warpTime(uint32 secs) external {
        skip(bound(secs, 0, 3 days));
    }
}

contract StakeInvariantTest is StdInvariant, Test {
    Stake internal stake;
    LPToken internal lpToken;
    nQToken internal nqToken;
    MockRewardOracle internal oracle;
    StakeHandler internal handler;

    address internal owner1 = address(0x1);
    address internal owner2 = address(0x2);
    address internal owner3 = address(0x3);

    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;

    address[] internal actors;

    function setUp() public {
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

        actors.push(makeAddr("user0"));
        actors.push(makeAddr("user1"));
        actors.push(makeAddr("user2"));

        handler = new StakeHandler(stake, lpToken, nqToken, actors);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = StakeHandler.stakeEth.selector;
        selectors[1] = StakeHandler.stakeToken.selector;
        selectors[2] = StakeHandler.requestWithdraw.selector;
        selectors[3] = StakeHandler.withdrawEth.selector;
        selectors[4] = StakeHandler.withdrawToken.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The contract's ETH balance must always equal the sum of all user ETH stakes.
    function invariant_EthBalanceMatchesStakes() public view {
        uint256 sumEth;
        for (uint256 i; i < actors.length; i++) {
            sumEth += stake.userToEthAmount(actors[i]);
        }
        assertEq(address(stake).balance, sumEth);
    }

    /// @dev LP token balance of the contract must equal total token stakes (minus withdrawn).
    function invariant_LPBalanceMatchesStakes() public view {
        uint256 sumTokens;
        for (uint256 i; i < actors.length; i++) {
            sumTokens += stake.userToTokenAmount(actors[i]);
        }
        assertEq(lpToken.balanceOf(address(stake)), sumTokens);
    }

    /// @dev Ghost accounting: tracked sums must match on-chain state.
    function invariant_GhostEthMatchesOnChain() public view {
        uint256 sumEth;
        for (uint256 i; i < actors.length; i++) {
            sumEth += stake.userToEthAmount(actors[i]);
        }
        assertEq(handler.ghost_totalEthStaked(), sumEth);
    }

    function invariant_GhostTokenMatchesOnChain() public view {
        uint256 sumTokens;
        for (uint256 i; i < actors.length; i++) {
            sumTokens += stake.userToTokenAmount(actors[i]);
        }
        assertEq(handler.ghost_totalTokenStaked(), sumTokens);
    }

    /// @dev A flagged user must always have withdrawRequested == 0.
    function invariant_FlaggedUserHasNoWithdrawRequest() public view {
        for (uint256 i; i < actors.length; i++) {
            if (stake.flaggedSuspicious(actors[i])) {
                assertEq(stake.withdrawRequested(actors[i]), 0);
            }
        }
    }

    /// @dev A user can only have a withdrawal request if they have a non-zero stake.
    function invariant_WithdrawRequestRequiresActiveStake() public view {
        for (uint256 i; i < actors.length; i++) {
            if (stake.withdrawRequested(actors[i]) != 0) {
                bool hasStake = stake.userToEthAmount(actors[i]) > 0
                    || stake.userToTokenAmount(actors[i]) > 0;
                assertTrue(hasStake);
            }
        }
    }
}
