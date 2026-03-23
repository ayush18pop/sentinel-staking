// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IRewardOracle {
    /// @notice Current rate at this block (informational).
    function getRewardRate() external view returns (uint256);

    /// @notice Cumulative sum of rates for each block in [fromBlock, toBlock).
    ///         Used by the staking contract to compute exact per-block reward accumulation.
    function getCumulativeRate(uint256 fromBlock, uint256 toBlock) external view returns (uint256);
}
