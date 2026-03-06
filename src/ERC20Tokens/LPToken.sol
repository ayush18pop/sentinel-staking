//SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.30;

import {ERC1363} from "@openzeppelin/token/ERC20/extensions/ERC1363.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @notice LP token with ERC-1363 support — allows staking via a single transferAndCall.
contract LPToken is ERC1363 {
    constructor(uint256 initialSupply) ERC20("LPToken", "LP") {
        _mint(msg.sender, initialSupply);
    }
}