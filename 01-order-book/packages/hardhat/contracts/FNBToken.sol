// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FNB Token
/// @notice ERC20 token representing eBucks used in the order book.
contract FNBToken is ERC20 {
    /// @notice Creates the token and mints the full initial supply to the deployer.
    /// @param initialSupply The total number of token units to mint at deployment.
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply);
    }
}

