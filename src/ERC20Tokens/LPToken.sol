//SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract LPToken is ERC20{
    constructor(uint256 initialSupply) ERC20("LPToken", "LP") {
        _mint(msg.sender, initialSupply);
    }
}