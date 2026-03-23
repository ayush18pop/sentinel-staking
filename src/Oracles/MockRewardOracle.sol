// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IRewardOracle} from "./IRewardOracle.sol";

/// @notice Mock oracle that simulates a reward rate that changes every block.
/// Rate cycles between 1 and 10 based on block.number: rate[b] = (b % 10) + 1.
contract MockRewardOracle is IRewardOracle {
    function getRewardRate() public view returns (uint256) {
        return (block.number % 10) + 1;
    }

    /// @notice Exact per-block cumulative sum of rate[b] for b in [fromBlock, toBlock).
    ///         Pure loop — safe for tests; a production oracle would expose an on-chain TWAP.
    function getCumulativeRate(uint256 fromBlock, uint256 toBlock) external pure returns (uint256 total) {
        for (uint256 b = fromBlock; b < toBlock; b++) {
            total += (b % 10) + 1;
        }
    }
}