//SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.30;

/// @notice Mock oracle that simulates a reward rate that changes every block.
/// Rate cycles between 1 and 10 based on block.number.
contract MockRewardOracle {
    function getRewardRate() public view returns (uint256) {
        return (block.number % 10) + 1;
    }
}