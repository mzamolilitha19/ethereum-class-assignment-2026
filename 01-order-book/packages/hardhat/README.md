# Order Book Assignment

This folder contains the assignment implementation for the `01-order-book` project.

## Contracts

- `contracts/PNPToken.sol` — ERC20 token for Pick n Pay reward points (`PNPT`).
- `contracts/FNBToken.sol` — ERC20 token for eBucks (`FNBT`).
- `contracts/OrderBook.sol` — Order book smart contract for trading `PNPToken` and `FNBToken`.

## Features

- ERC20 token deployment with initial mint to deployer.
- Buy and sell order placement with token escrow.
- Matching logic that executes trades when buy price meets or exceeds sell price.
- Partial fills and remaining-order tracking.
- Order cancellation with refunds of remaining escrowed value.
- Events for order creation, matching, and cancellation.

## Running tests

From this folder, use the local Hardhat CLI:

```powershell
$env:CI='1'
$env:HARDHAT_DISABLE_TELEMETRY='1'
..\..\node_modules\.bin\hardhat.cmd test test/AssignmentSolution.ts --network hardhat
```

If you need only Part 1 tests:

```powershell
$env:CI='1'
$env:HARDHAT_DISABLE_TELEMETRY='1'
..\..\node_modules\.bin\hardhat.cmd test test/AssignmentSolution.ts --network hardhat --grep "Part 1"
```

## Notes

- The assignment test file is `test/AssignmentSolution.ts`.
- The order book uses `SafeERC20` for secure token transfers.
- The `cancelOrder` method supports both buy and sell orders.
