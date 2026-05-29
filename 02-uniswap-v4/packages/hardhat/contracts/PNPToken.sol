// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// We inherit OpenZeppelin's audited ERC20 implementation so we get the full,
// standard-compliant fungible-token behaviour (balances, transfers, approvals,
// allowances and the Transfer/Approval events) without re-implementing it.
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PNPToken (PNPT)
/// @notice ERC20 reward token representing Pick n Pay "Smart Shopper" style points.
/// @dev    Fungible: every PNPT unit is identical in value/function to every other.
///         Uses the default 18 decimals provided by OpenZeppelin's ERC20.
contract PNPToken is ERC20 {
    /// @notice Deploys the token and mints the entire initial supply to the deployer.
    /// @param  initialSupply The total supply to create, expressed in base units
    ///         (i.e. already scaled by 10**18, e.g. 1_000_000 * 1e18 for 1,000,000 PNPT).
    /// @dev    - ERC20("PNP Token", "PNPT") sets the human-readable name and ticker symbol.
    ///         - _mint creates `initialSupply` tokens, increases totalSupply by the same
    ///           amount and credits the deployer's balance. It also emits a Transfer event
    ///           from the zero address (the canonical way ERC20 signals minting).
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        // Mint the whole supply to whoever deploys the contract (msg.sender).
        // This is a fixed-supply model: no further minting function is exposed.
        _mint(msg.sender, initialSupply);
    }
}
