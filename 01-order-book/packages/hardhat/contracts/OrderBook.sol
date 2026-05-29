// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// IERC20 is the minimal interface we need to talk to the two reward tokens.
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// SafeERC20 wraps transfer/transferFrom so that tokens which return false (or
// nothing) on failure are handled safely; any failed transfer reverts the tx.
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  OrderBook
/// @notice A minimal on-chain order book DEX for trading two ERC20 reward tokens:
///         the "base" token (tokenA / PNPT) priced in the "quote" token (tokenB / FNBT).
/// @dev    Design summary:
///         - A BUY order wants to acquire `amount` of base token, paying in quote token.
///           The buyer escrows `amount * price` quote tokens up front.
///         - A SELL order wants to sell `amount` of base token for quote token.
///           The seller escrows `amount` base tokens up front.
///         - `price` is an integer ratio: quoteAmount = baseAmount * price
///           (so `amount` is always denominated in base-token units).
///         - Matching is permissionless: anyone may call matchOrders to pair a
///           compatible buy and sell order. Token settlement happens atomically.
///         - Orders support partial fills and can be cancelled by their maker,
///           which refunds the still-escrowed (unfilled) portion.
contract OrderBook {
    using SafeERC20 for IERC20;

    /// @notice The side of an order. Solidity encodes the first member as 0 and
    ///         the second as 1, so Buy == 0 and Sell == 1 in events/storage.
    enum Side {
        Buy, // 0
        Sell // 1
    }

    /// @notice Full state for a single resting order.
    /// @dev    `amount` and `filled` are both in base-token units. The remaining
    ///         (still-open) base amount is therefore `amount - filled`.
    struct Order {
        address maker; // who placed the order (and who escrowed the tokens)
        Side side; // Buy or Sell
        uint256 amount; // total base-token amount the order is for
        uint256 filled; // base-token amount already executed
        uint256 price; // quote-per-base ratio (quote = base * price)
        bool open; // true while the order can still be matched or cancelled
    }

    // --- Immutable token configuration -------------------------------------------------

    /// @notice The base token being traded (tokenA, e.g. PNPT). Orders are sized in this token.
    IERC20 public immutable baseToken;
    /// @notice The quote token used for payment (tokenB, e.g. FNBT).
    IERC20 public immutable quoteToken;

    // --- Order storage -----------------------------------------------------------------

    /// @notice Auto-incrementing id assigned to the next order (first order gets id 0).
    uint256 public nextOrderId;
    /// @notice Lookup of every order ever placed, keyed by its id.
    mapping(uint256 => Order) public orders;

    // --- Events (consumed by off-chain indexers / front-ends) --------------------------

    /// @notice Emitted whenever a new buy or sell order is created.
    /// @param orderId  The id assigned to the new order.
    /// @param maker    The address that placed the order.
    /// @param side     Buy (0) or Sell (1).
    /// @param tokenIn  The token the maker pays/escrows (quote for a buy, base for a sell).
    /// @param tokenOut The token the maker wants to receive (base for a buy, quote for a sell).
    /// @param amount   The base-token amount of the order.
    /// @param price    The quote-per-base price ratio.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        Side side,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 price
    );

    /// @notice Emitted on every (possibly partial) fill so the running fill state is observable.
    event OrderFilled(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 baseFilled, // base tokens moved to the buyer this fill
        uint256 quoteFilled, // quote tokens moved to the seller this fill
        uint256 execPrice // price the fill executed at
    );

    /// @notice Emitted once per successful matchOrders call summarising the trade.
    event OrderMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        address buyer,
        address seller,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 execPrice
    );

    /// @notice Emitted when a maker cancels an order; `refundedAmount` is the escrow returned.
    event OrderCanceled(uint256 indexed orderId, address indexed maker, uint256 refundedAmount);

    // --- Custom errors (cheaper than require strings and easy to test for) -------------

    error InvalidAmount(); // amount == 0
    error InvalidPrice(); // price == 0
    error OrderNotOpen(); // order already filled or cancelled
    error NotABuyOrder(); // buyOrderId did not reference a Buy order
    error NotASellOrder(); // sellOrderId did not reference a Sell order
    error PriceMismatch(); // buy price < sell price, so no trade is possible
    error NothingToFill(); // both orders have zero remaining amount
    error UnauthorizedCancellation(); // caller is not the order's maker

    /// @notice Wire up the two tradable tokens.
    /// @param _tokenA The base token (PNPT) – orders are denominated in this token.
    /// @param _tokenB The quote token (FNBT) – used to pay for the base token.
    constructor(address _tokenA, address _tokenB) {
        baseToken = IERC20(_tokenA);
        quoteToken = IERC20(_tokenB);
    }

    /// @notice Place a buy order: acquire `amount` base tokens, paying in quote tokens.
    /// @dev    The buyer must have approved this contract for `amount * price` quote tokens.
    ///         Those quote tokens are pulled into escrow immediately so settlement is guaranteed.
    /// @param amount The base-token amount the buyer wants to acquire (must be > 0).
    /// @param price  The quote-per-base price the buyer is willing to pay (must be > 0).
    /// @return orderId The id assigned to the newly created order.
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        // Reject economically meaningless orders early.
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Total quote tokens the buyer must lock = base amount * price.
        uint256 quoteAmount = amount * price;

        // Move the quote tokens from the buyer into this contract (escrow).
        // Requires prior approve(orderBook, quoteAmount) by the buyer.
        quoteToken.safeTransferFrom(msg.sender, address(this), quoteAmount);

        // Allocate the next id and persist the order as open with zero fills.
        orderId = nextOrderId++;
        orders[orderId] =
            Order({ maker: msg.sender, side: Side.Buy, amount: amount, filled: 0, price: price, open: true });

        // For a buy: tokenIn = quote (paid), tokenOut = base (received).
        emit OrderPlaced(orderId, msg.sender, Side.Buy, address(quoteToken), address(baseToken), amount, price);
    }

    /// @notice Place a sell order: sell `amount` base tokens for quote tokens.
    /// @dev    The seller must have approved this contract for `amount` base tokens,
    ///         which are pulled into escrow immediately.
    /// @param amount The base-token amount to sell (must be > 0).
    /// @param price  The quote-per-base price the seller wants (must be > 0).
    /// @return orderId The id assigned to the newly created order.
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Escrow the base tokens being offered for sale.
        // Requires prior approve(orderBook, amount) by the seller.
        baseToken.safeTransferFrom(msg.sender, address(this), amount);

        orderId = nextOrderId++;
        orders[orderId] =
            Order({ maker: msg.sender, side: Side.Sell, amount: amount, filled: 0, price: price, open: true });

        // For a sell: tokenIn = base (given), tokenOut = quote (received).
        emit OrderPlaced(orderId, msg.sender, Side.Sell, address(baseToken), address(quoteToken), amount, price);
    }

    /// @notice Match a buy order against a sell order and settle the overlapping amount.
    /// @dev    Permissionless: any address can submit a valid match (the matching engine is
    ///         conceptually off-chain; this function just executes a proposed pairing).
    ///         A trade is only possible when the buyer's price >= the seller's price.
    ///         The fill executes at the resting SELL (ask) price, and any difference between
    ///         what the buyer escrowed and what the seller is paid is refunded to the buyer
    ///         (price improvement). Follows checks-effects-interactions ordering.
    /// @param buyOrderId  Id of the buy order.
    /// @param sellOrderId Id of the sell order.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];

        // Validate the two ids really reference a buy and a sell respectively.
        if (buyOrder.side != Side.Buy) revert NotABuyOrder();
        if (sellOrder.side != Side.Sell) revert NotASellOrder();

        // Both orders must still be active.
        if (!buyOrder.open || !sellOrder.open) revert OrderNotOpen();

        // The buyer must be willing to pay at least the seller's ask price.
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        // Remaining base amounts on each side.
        uint256 buyRemaining = buyOrder.amount - buyOrder.filled;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled;

        // The fillable base amount is the smaller of the two remainders (partial-fill aware).
        uint256 baseFill = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;
        if (baseFill == 0) revert NothingToFill();

        // Settle at the seller's (ask) price; the buyer may have escrowed more (at buy.price).
        uint256 execPrice = sellOrder.price;
        uint256 quoteToSeller = baseFill * execPrice; // what the seller actually receives
        uint256 buyerEscrowUsed = baseFill * buyOrder.price; // what the buyer locked for this slice
        uint256 buyerRefund = buyerEscrowUsed - quoteToSeller; // price-improvement refund (>= 0)

        // --- Effects: update fill state before moving any tokens (reentrancy safety) ---
        buyOrder.filled += baseFill;
        sellOrder.filled += baseFill;
        // Close any order that is now completely filled.
        if (buyOrder.filled == buyOrder.amount) buyOrder.open = false;
        if (sellOrder.filled == sellOrder.amount) sellOrder.open = false;

        // --- Interactions: pay out from the escrow this contract already holds ---
        // Base tokens (from the seller's escrow) go to the buyer.
        baseToken.safeTransfer(buyOrder.maker, baseFill);
        // Quote tokens (from the buyer's escrow) go to the seller.
        quoteToken.safeTransfer(sellOrder.maker, quoteToSeller);
        // Return any over-escrow to the buyer when buy price exceeded the executed price.
        if (buyerRefund > 0) quoteToken.safeTransfer(buyOrder.maker, buyerRefund);

        emit OrderFilled(buyOrderId, sellOrderId, baseFill, quoteToSeller, execPrice);
        emit OrderMatched(
            buyOrderId, sellOrderId, buyOrder.maker, sellOrder.maker, baseFill, quoteToSeller, execPrice
        );
    }

    /// @notice Cancel an open order and refund the maker's still-escrowed (unfilled) tokens.
    /// @dev    Only the order's maker may cancel it. For a buy order we refund the unfilled
    ///         quote escrow (remainingBase * price); for a sell order we refund the unfilled
    ///         base escrow (remainingBase).
    /// @param orderId The id of the order to cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        // Can only cancel something that is still active.
        if (!order.open) revert OrderNotOpen();
        // Only the maker who escrowed the funds can cancel and reclaim them.
        if (order.maker != msg.sender) revert UnauthorizedCancellation();

        // The still-open base amount whose escrow must be returned.
        uint256 baseRemaining = order.amount - order.filled;

        // Effects first: mark closed so it cannot be matched/cancelled again.
        order.open = false;

        uint256 refunded;
        if (order.side == Side.Buy) {
            // Buyer escrowed quote tokens at their bid price for the whole order;
            // refund the portion that was never filled.
            refunded = baseRemaining * order.price;
            if (refunded > 0) quoteToken.safeTransfer(order.maker, refunded);
        } else {
            // Seller escrowed base tokens; refund the unfilled base amount.
            refunded = baseRemaining;
            if (refunded > 0) baseToken.safeTransfer(order.maker, refunded);
        }

        emit OrderCanceled(orderId, order.maker, refunded);
    }

    /// @notice Whether an order is still active (open) and therefore matchable/cancellable.
    /// @param orderId The order id to query.
    /// @return True if the order is open, false if filled or cancelled.
    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].open;
    }

    /// @notice The remaining unfilled base-token amount of an order.
    /// @param orderId The order id to query.
    /// @return The base-token amount still to be filled (amount - filled).
    function remaining(uint256 orderId) external view returns (uint256) {
        Order storage order = orders[orderId];
        return order.amount - order.filled;
    }
}
