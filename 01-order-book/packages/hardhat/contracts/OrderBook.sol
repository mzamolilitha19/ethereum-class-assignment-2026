// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OrderBook {
    using SafeERC20 for IERC20;

    enum OrderType {
        Buy,
        Sell
    }

    struct Order {
        address owner;
        uint256 amount;
        uint256 remaining;
        uint256 price;
        address fromToken;
        address toToken;
        OrderType orderType;
        bool open;
    }

    address public immutable tokenA;
    address public immutable tokenB;
    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;

    error InvalidAmount();
    error InvalidPrice();
    error PriceMismatch();
    error UnauthorizedCancellation();
    error OrderNotOpen();
    error InvalidOrderType();

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        uint8 orderType,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 price
    );

    event OrderMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 amount,
        uint256 price
    );

    event OrderCanceled(uint256 indexed orderId);

    /// @notice Constructs the order book for the two trading tokens.
    /// @param _tokenA The first ERC20 token address (PNPToken).
    /// @param _tokenB The second ERC20 token address (FNBToken).
    constructor(address _tokenA, address _tokenB) {
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    /// @notice Place a buy order to purchase `tokenA` using `tokenB`.
    /// @param amount Amount of `tokenA` to buy.
    /// @param price Price in units of `tokenB` per `tokenA`.
    /// @return orderId The identifier for the newly created buy order.
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        uint256 totalCost = amount * price;
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), totalCost);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            owner: msg.sender,
            amount: amount,
            remaining: amount,
            price: price,
            fromToken: tokenB,
            toToken: tokenA,
            orderType: OrderType.Buy,
            open: true
        });

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Buy), tokenB, tokenA, amount, price);
    }

    /// @notice Place a sell order to sell `tokenA` in exchange for `tokenB`.
    /// @param amount Amount of `tokenA` to sell.
    /// @param price Price in units of `tokenB` per `tokenA`.
    /// @return orderId The identifier for the newly created sell order.
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amount);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            owner: msg.sender,
            amount: amount,
            remaining: amount,
            price: price,
            fromToken: tokenA,
            toToken: tokenB,
            orderType: OrderType.Sell,
            open: true
        });

        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Sell), tokenA, tokenB, amount, price);
    }

    /// @notice Match a buy order with a sell order and execute the trade.
    /// @param buyOrderId The buy order ID.
    /// @param sellOrderId The sell order ID.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];

        if (!buyOrder.open || !sellOrder.open) revert OrderNotOpen();
        if (buyOrder.orderType != OrderType.Buy || sellOrder.orderType != OrderType.Sell) revert InvalidOrderType();
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        uint256 matchedAmount = buyOrder.remaining < sellOrder.remaining ? buyOrder.remaining : sellOrder.remaining;
        uint256 executionPrice = sellOrder.price;
        uint256 quoteAmount = matchedAmount * executionPrice;

        buyOrder.remaining -= matchedAmount;
        sellOrder.remaining -= matchedAmount;

        if (buyOrder.remaining == 0) {
            buyOrder.open = false;
        }
        if (sellOrder.remaining == 0) {
            sellOrder.open = false;
        }

        // Refund the buyer if the resting sell order executes at a better price.
        uint256 buyerDeposit = matchedAmount * buyOrder.price;
        if (buyerDeposit > quoteAmount) {
            IERC20(tokenB).safeTransfer(buyOrder.owner, buyerDeposit - quoteAmount);
        }

        IERC20(tokenA).safeTransfer(buyOrder.owner, matchedAmount);
        IERC20(tokenB).safeTransfer(sellOrder.owner, quoteAmount);

        emit OrderMatched(buyOrderId, sellOrderId, matchedAmount, executionPrice);
    }

    /// @notice Cancel an open order and refund the remaining escrowed tokens.
    /// @param orderId The order identifier.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.owner != msg.sender) revert UnauthorizedCancellation();
        if (!order.open) revert OrderNotOpen();

        order.open = false;
        uint256 refundAmount = order.remaining;
        order.remaining = 0;

        if (order.orderType == OrderType.Buy) {
            uint256 refundValue = refundAmount * order.price;
            IERC20(order.fromToken).safeTransfer(order.owner, refundValue);
        } else {
            IERC20(order.fromToken).safeTransfer(order.owner, refundAmount);
        }

        emit OrderCanceled(orderId);
    }

    /// @notice Returns how much of the order is still open.
    /// @param orderId The order identifier.
    function remaining(uint256 orderId) external view returns (uint256) {
        return orders[orderId].remaining;
    }

    /// @notice Returns whether the order is still open.
    /// @param orderId The order identifier.
    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].open;
    }
}
