// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////////////////
                                  IMPORTS
//////////////////////////////////////////////////////////////////////////*/

// --- OpenZeppelin ---------------------------------------------------------
// IERC20  : minimal token interface so we can pull/refund PNPT & FNBT.
// Ownable : restricts pool *creation* to an administrator (the deployer).
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// --- Uniswap v4 core ------------------------------------------------------
// IPoolManager   : the singleton that holds every pool's state; we call
//                  initialize(key, sqrtPriceX96) on it to create our pool.
// IHooks         : the hook interface; we use the zero address (no hooks).
// Currency       : a `type Currency is address` value type wrapping a token.
// PoolKey        : the 5-field struct that uniquely identifies a pool.
// PoolId/Library : PoolId is `bytes32`; toId(key) derives it from a PoolKey.
// StateLibrary   : read helpers over the PoolManager (e.g. getSlot0).
// TickMath       : tick <-> sqrtPriceX96 conversions and tick bounds.
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

// --- Uniswap v4 periphery -------------------------------------------------
// LiquidityAmounts : converts desired token amounts -> liquidity units.
// Actions          : opcode constants for the PositionManager command buffer.
// IPositionManager : the NFT-position router; we drive it via modifyLiquidities.
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @notice Minimal local view of the Uniswap v4 PositionManager.
/// @dev    We declare only the functions this contract actually calls, rather
///         than importing the full v4-periphery IPositionManager interface.
///         That heavier interface transitively imports "permit2/...", a
///         foundry remapping the npm package does not ship, so importing it
///         would force every consumer to vendor Permit2 just to compile. The
///         selectors here match the real PositionManager exactly, so calls
///         are ABI-compatible.
interface IPositionManagerMinimal {
    /// @notice Executes an encoded batch of liquidity actions before `deadline`.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice The id that will be assigned to the next minted position NFT.
    function nextTokenId() external view returns (uint256);

    /// @notice The liquidity currently held by a given position.
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @notice The Permit2 contract the PositionManager settles payments through.
    /// @dev    Backed by `IAllowanceTransfer public immutable permit2` on the
    ///         concrete PositionManager; the getter returns it as an address.
    function permit2() external view returns (address);
}

/*//////////////////////////////////////////////////////////////////////////
                            REWARD TOKENS MANAGER
//////////////////////////////////////////////////////////////////////////*/

/// @title  RewardTokensManager
/// @notice Creates a single canonical Uniswap v4 pool for the PNPT/FNBT reward
///         token pair and lets users mint concentrated-liquidity positions into
///         it through the official PositionManager.
/// @dev    Two responsibilities:
///         1. createPool(...)    — admin seeds the canonical market once.
///         2. mintLiquidity(...) — any liquidity provider adds liquidity and
///            receives an ERC721 position NFT from the PositionManager.
contract RewardTokensManager is Ownable {
    // Attach toId() to PoolKey and the StateLibrary read-helpers to IPoolManager
    // so we can write `key.toId()` and `poolManager.getSlot0(id)` fluently.
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////////////
                              POOL CONFIGURATION
    //////////////////////////////////////////////////////////////////////*/

    /// @notice The 0.30% fee tier, expressed in hundredths of a bip (pips).
    /// @dev    3000 pips = 0.30%. This is the classic Uniswap "standard" tier.
    uint24 public constant FEE_TIER = 3000;

    /// @notice Tick spacing paired with the 0.30% tier (only multiples of 60
    ///         are valid tick boundaries for this pool).
    int24 public constant TICK_SPACING = 60;

    /// @notice This pool runs without a hooks contract.
    address public constant HOOKS = address(0);

    /// @notice Magnitude of the tick that corresponds to an exchange rate of
    ///         10x (or 1/10x) between the two tokens.
    /// @dev    Uniswap encodes price as 1.0001^tick. Solving 1.0001^tick = 10
    ///         gives tick = ln(10) / ln(1.0001) ≈ 23027.  We store the positive
    ///         magnitude and apply the correct sign in getTargetTick() based on
    ///         which token sorted as currency0.
    int24 public constant TARGET_TICK_MAGNITUDE = 23027;

    /*//////////////////////////////////////////////////////////////////////
                                  IMMUTABLES
    //////////////////////////////////////////////////////////////////////*/

    /// @notice The Uniswap v4 PoolManager singleton.
    IPoolManager public immutable poolManager;

    /// @notice The Uniswap v4 PositionManager (mints/holds the position NFTs).
    IPositionManagerMinimal public immutable positionManager;

    /// @notice The two reward tokens this manager pairs together.
    IERC20 public immutable pnpToken;
    IERC20 public immutable fnbToken;

    /// @notice The same two tokens wrapped as Uniswap `Currency` values and,
    ///         crucially, sorted ascending by address. Uniswap REQUIRES
    ///         currency0 < currency1, so we fix the ordering once at deploy.
    Currency public immutable currency0;
    Currency public immutable currency1;

    /*//////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Tracks which pool ids have been created by this manager.
    /// @dev    Keyed by the bytes32 PoolId. Lets the test assert createdPools(id).
    mapping(bytes32 => bool) public createdPools;

    /*//////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted once when the canonical pool is initialized.
    event PoolCreated(
        bytes32 indexed poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    /// @notice Emitted after a liquidity position NFT has been successfully minted.
    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /*//////////////////////////////////////////////////////////////////////
                                CUSTOM ERRORS
    //////////////////////////////////////////////////////////////////////*/

    error PoolAlreadyCreated();                  // createPool called twice for same key
    error PoolNotInitialized();                  // mint before createPool
    error InvalidAmounts();                       // both desired amounts are zero
    error InvalidTickRange();                     // tickLower >= tickUpper
    error TicksNotSpaced();                       // a tick is not a multiple of TICK_SPACING
    error TickOutOfBounds();                      // a tick exceeds TickMath min/max
    error TickRangeDoesNotCoverAssignmentPrice(); // range excludes the implied target tick
    error ZeroLiquidity();                        // amounts too small to mint any liquidity
    error MintFailed();                           // PositionManager did not record the position

    /*//////////////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////*/

    /// @param _poolManager     Address of the deployed v4 PoolManager.
    /// @param _positionManager Address of the deployed v4 PositionManager.
    /// @param _pnpToken        Address of the PNPT ERC20.
    /// @param _fnbToken        Address of the FNBT ERC20.
    /// @dev    Ownable(msg.sender) makes the deployer the admin allowed to call
    ///         createPool. We also compute the canonical (sorted) currency order
    ///         here so every later PoolKey we build is identical and valid.
    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManagerMinimal(_positionManager);
        pnpToken = IERC20(_pnpToken);
        fnbToken = IERC20(_fnbToken);

        // Uniswap mandates currency0 < currency1 (strict address ordering).
        // Sort the two token addresses so the PoolKey is always canonical.
        if (_pnpToken < _fnbToken) {
            currency0 = Currency.wrap(_pnpToken);
            currency1 = Currency.wrap(_fnbToken);
        } else {
            currency0 = Currency.wrap(_fnbToken);
            currency1 = Currency.wrap(_pnpToken);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                                 VIEW HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the two pool currencies as plain addresses, in canonical
    ///         (sorted) order — i.e. (currency0, currency1).
    function getCanonicalCurrencies() public view returns (address, address) {
        return (Currency.unwrap(currency0), Currency.unwrap(currency1));
    }

    /// @notice Builds the canonical PoolKey for the PNPT/FNBT pool.
    /// @dev    Internal because the struct contains value types that are clearer
    ///         to assemble in one place; all external entry points reuse this.
    function _poolKey() internal view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: FEE_TIER,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(HOOKS)
            });
    }

    /// @notice Returns the bytes32 PoolId derived from the canonical PoolKey.
    /// @dev    `view` is required: the test reads it as a value before/after
    ///         pool creation and compares it inside event assertions.
    function getPoolId() public view returns (bytes32) {
        return PoolId.unwrap(_poolKey().toId());
    }

    /// @notice The tick that encodes this assignment's implied 10x price ratio.
    /// @dev    Uniswap price = token1/token0 = 1.0001^tick.
    ///         We intend a 10:1 economic relationship between the reward tokens.
    ///         - If PNPT sorted as currency0 (token0), then a price of
    ///           FNBT-per-PNPT = 0.1 implies a NEGATIVE tick (-23027).
    ///         - Otherwise PNPT is token1 and the price of PNPT-per-FNBT = 10
    ///           implies a POSITIVE tick (+23027).
    ///         The sign is chosen so the target tick is economically consistent
    ///         with the canonical ordering; the test derives its mint ranges
    ///         directly from this value, so the coverage logic stays consistent
    ///         regardless of which token sorted first.
    function getTargetTick() public view returns (int24) {
        if (Currency.unwrap(currency0) == address(pnpToken)) {
            return -TARGET_TICK_MAGNITUDE;
        }
        return TARGET_TICK_MAGNITUDE;
    }

    /*//////////////////////////////////////////////////////////////////////
                               CREATE THE POOL
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Initializes the canonical PNPT/FNBT pool on the PoolManager.
    /// @param  sqrtPriceX96 The starting price as a Q64.96 sqrt price.
    /// @return poolId The bytes32 id of the newly created pool.
    /// @dev    onlyOwner: creating the canonical market is an administrative,
    ///         one-time action. Subsequent liquidity provision is open to all.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        PoolKey memory key = _poolKey();
        poolId = PoolId.unwrap(key.toId());

        // Guard against re-initializing the same pool (the PoolManager would
        // revert anyway, but this gives a clear, named error).
        if (createdPools[poolId]) revert PoolAlreadyCreated();

        // Create + price the pool in one call. v4's initialize takes exactly
        // (key, sqrtPriceX96) and returns the starting tick (ignored here).
        poolManager.initialize(key, sqrtPriceX96);

        createdPools[poolId] = true;

        emit PoolCreated(
            poolId,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            FEE_TIER,
            TICK_SPACING,
            HOOKS,
            sqrtPriceX96
        );
    }

    /*//////////////////////////////////////////////////////////////////////
                              MINT LIQUIDITY
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Adds a concentrated-liquidity position to the canonical pool and
    ///         mints the corresponding ERC721 position NFT to the caller.
    /// @param  tickLower      Lower tick of the position range (multiple of 60).
    /// @param  tickUpper      Upper tick of the position range (multiple of 60).
    /// @param  amount0Desired Max amount of currency0 the caller will provide.
    /// @param  amount1Desired Max amount of currency1 the caller will provide.
    /// @return positionId The token id of the minted position NFT.
    /// @return poolId     The id of the pool the liquidity was added to.
    /// @dev    Open to any LP (not onlyOwner). High-level flow:
    ///         validate -> price-coverage check -> compute liquidity -> pull
    ///         tokens -> approve Permit2 -> drive PositionManager -> verify ->
    ///         refund dust -> emit.
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {
        // ---- (1) Validate inputs ----------------------------------------
        // At least one token must be supplied, ticks must form a real range,
        // be aligned to the pool's spacing and sit within TickMath's bounds.
        // NOTE: order matters — these structural checks must run BEFORE the
        // price-coverage check so malformed ranges fail with precise errors.
        if (amount0Desired == 0 && amount1Desired == 0) revert InvalidAmounts();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0) revert TicksNotSpaced();
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert TickOutOfBounds();

        // ---- (2) Price-coverage check -----------------------------------
        // The position's range must straddle the assignment's implied price
        // tick, otherwise the position would not be active at the canonical
        // price and is rejected.
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || tickUpper < targetTick) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // ---- (3) Resolve the pool and ensure it exists ------------------
        PoolKey memory key = _poolKey();
        poolId = PoolId.unwrap(key.toId());
        if (!createdPools[poolId]) revert PoolNotInitialized();

        // ---- (4) Convert desired amounts into a liquidity figure --------
        // Read the live price from the PoolManager, then ask LiquidityAmounts
        // how much liquidity the supplied maxima can support across the range.
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            amount0Desired,
            amount1Desired
        );
        if (liquidity == 0) revert ZeroLiquidity();

        // ---- (5) Pull the tokens from the caller into this contract -----
        // The PositionManager will later pull from US (the msgSender of
        // modifyLiquidities) via Permit2, so the funds must live here first.
        if (amount0Desired > 0) {
            IERC20(Currency.unwrap(currency0)).transferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(Currency.unwrap(currency1)).transferFrom(msg.sender, address(this), amount1Desired);
        }

        // ---- (6) Approve Permit2 to move our tokens ---------------------
        // v4's PositionManager settles debts through Permit2's transferFrom,
        // which itself calls the token's transferFrom(from = this contract).
        // So we grant the Permit2 contract an ERC20 allowance over both tokens.
        address permit2 = positionManager.permit2();
        IERC20(Currency.unwrap(currency0)).approve(permit2, amount0Desired);
        IERC20(Currency.unwrap(currency1)).approve(permit2, amount1Desired);

        // ---- (7) Encode and execute the PositionManager command buffer --
        // Two actions:
        //   MINT_POSITION : create the position and assign it an NFT.
        //   SETTLE_PAIR   : pay the two owed currencies to the PoolManager.
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        // MINT_POSITION parameters (decoded by the PositionManager as):
        // (PoolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0Desired),
            uint128(amount1Desired),
            msg.sender,        // the position NFT is minted to the caller (the LP)
            bytes("")          // no hook data
        );
        // SETTLE_PAIR parameters: the two currencies to settle.
        params[1] = abi.encode(currency0, currency1);

        // The next NFT id the PositionManager will assign IS our position id.
        positionId = positionManager.nextTokenId();

        // Fire the batched command. Deadline = current block timestamp (the tx
        // executes now, so it can never be stale).
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // ---- (8) Verify the position really exists ----------------------
        if (positionManager.getPositionLiquidity(positionId) != liquidity) revert MintFailed();

        // ---- (9) Refund any unused token dust back to the caller --------
        // getLiquidityForAmounts rounds down, so a little of one token usually
        // remains. Return whatever this contract still holds to the LP.
        uint256 leftover0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 leftover1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        if (leftover0 > 0) IERC20(Currency.unwrap(currency0)).transfer(msg.sender, leftover0);
        if (leftover1 > 0) IERC20(Currency.unwrap(currency1)).transfer(msg.sender, leftover1);

        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, liquidity);
    }
}
