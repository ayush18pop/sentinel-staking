//SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract nQToken is ERC20{
    constructor(uint256 initialSupply) ERC20("nQToken", "nQT") {
        _mint(msg.sender, initialSupply);
    }
}