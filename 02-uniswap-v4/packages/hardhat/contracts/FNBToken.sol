// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Inherit the standard, audited OpenZeppelin ERC20 base contract so this token
// is fully interoperable with wallets, exchanges and our OrderBook DEX.
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FNBToken (FNBT)
/// @notice ERC20 reward token representing FNB "eBucks" style rewards.
/// @dev    Fungible token with the default 18 decimals. It is functionally
///         identical to PNPToken but carries its own name/symbol so the two
///         reward currencies can be told apart and traded against each other.
contract FNBToken is ERC20 {
    /// @notice Deploys the token and mints the full initial supply to the deployer.
    /// @param  initialSupply Total supply in base units (already scaled by 10**18).
    /// @dev    ERC20("FNB Token", "FNBT") fixes the name and symbol; _mint credits
    ///         the deployer and emits a Transfer event from address(0) (mint signal).
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        // Fixed-supply mint: everything goes to the deployer at construction time.
        _mint(msg.sender, initialSupply);
    }
}
