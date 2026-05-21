// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PNP Token
/// @notice ERC20 token representing Pick n Pay reward points used in the order book.
contract PNPToken is ERC20 {
    /// @notice Creates the token and mints the full initial supply to the deployer.
    /// @param initialSupply The total number of token units to mint at deployment.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}

