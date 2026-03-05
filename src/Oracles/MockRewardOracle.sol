//SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.30;

contract MockRewardOracle {
    function getRewardRate() public pure returns (uint256) {
        return 100;
    }
}