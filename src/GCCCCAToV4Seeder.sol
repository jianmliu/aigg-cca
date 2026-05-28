// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal Uniswap V4 surface needed by the seeder. Kept inline so we
///         don't pull in the full v4-core / v4-periphery libraries — we only
///         do two calls (`initialize` on PoolManager + a multicall on
///         PositionManager to mint a fresh full-range LP position) and never
///         settle internally.
interface IV4PoolManager {
    /// @notice PoolKey as defined by v4-core.
    /// @dev `currency0` and `currency1` MUST be sorted ascending. `hooks`
    ///      may be the zero address when no hook is wanted.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @notice Initialise a new pool. Reverts if the pool already exists.
    /// @param key Pool key (must have sorted currencies)
    /// @param sqrtPriceX96 Initial sqrt price as Q64.96
    /// @return tick The initial pool tick
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96)
        external
        returns (int24 tick);
}

/// @notice PositionManager surface used by the seeder. We rely on the
///         `multicall(bytes[])` entrypoint and pass it a hand-rolled
///         `modifyLiquidities` action call so the seeder doesn't depend on
///         the full v4-periphery `Actions` library.
interface IV4PositionManager {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

/// @notice GCCCCAToV4Seeder — the "exit" half of the CCA flow.
///
/// @dev The CCA primary auction settles GCC distribution + clearing-price
///      discovery. After it ends, this contract bootstraps the *secondary*
///      market: a Uniswap V4 USDC/GCC pool seeded with whatever USDC + GCC
///      the seeder is holding at the moment `bootstrap()` is called. Once
///      seeded, the V4 pool becomes the canonical spot-price source (read
///      by the AI.GG backend via the V4 Quoter) for everything outside the
///      primary auction.
///
///      The seeder is intentionally **operator-triggered**, not auto-triggered
///      from CCA settlement:
///        - Operator picks `sqrtPriceX96` from the observed clearing price.
///        - Operator picks tick range (full-range vs concentrated).
///        - If the CCA contract doesn't auto-forward USDC to `fundsRecipient`
///          (depends on third-party impl), operator pre-funds the seeder
///          manually before calling `bootstrap`.
///
///      The LP position NFT minted by V4 is sent to `owner()` (treasury
///      multisig). Anyone can send extra USDC/GCC to the seeder before
///      `bootstrap`, increasing the size of the seeded LP. After `bootstrap`,
///      any residual balances can be swept by the owner via `recover()`.
contract GCCCCAToV4Seeder is Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable gcc;
    IERC20 public immutable usdc;
    IV4PoolManager public immutable poolManager;
    IV4PositionManager public immutable positionManager;

    /// @notice Set once at deploy time. Fee tier of the seeded pool (e.g. 3000 = 0.3 %).
    uint24 public immutable poolFee;
    /// @notice Set once at deploy time. Tick spacing for the seeded pool. Must match
    ///         the pool fee tier convention (3000 → 60, 500 → 10, 10000 → 200).
    int24 public immutable tickSpacing;

    /// @notice True once the V4 pool has been initialised by this contract.
    ///         `bootstrap` flips it on; `addLiquidity` requires it to be on.
    ///         Tracks pool initialisation state, NOT "has the seeder been used"
    ///         — `addLiquidity` is intentionally callable any number of times
    ///         to support the unified-CCA model where every subsequent issuance
    ///         round adds more liquidity to the same V4 pool.
    bool public initialized;

    event V4PoolSeeded(
        address indexed poolManager,
        address indexed currency0,
        address indexed currency1,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 usdcAmount,
        uint256 gccAmount
    );
    event V4LiquidityAdded(
        int24 tickLower, int24 tickUpper, uint256 usdcAmount, uint256 gccAmount
    );
    event Recovered(address indexed token, address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotInitialized();
    error NoLiquidity();
    error InvalidTickRange();
    error TickNotAligned();

    constructor(
        address gcc_,
        address usdc_,
        address poolManager_,
        address positionManager_,
        uint24 poolFee_,
        int24 tickSpacing_,
        address owner_
    ) Ownable(owner_) {
        gcc = IERC20(gcc_);
        usdc = IERC20(usdc_);
        poolManager = IV4PoolManager(poolManager_);
        positionManager = IV4PositionManager(positionManager_);
        poolFee = poolFee_;
        tickSpacing = tickSpacing_;
    }

    /// @notice Initialise the V4 USDC/GCC pool and seed it with this
    ///         contract's USDC + GCC balances. Sends the resulting LP
    ///         position NFT to `owner()`.
    ///
    /// @param sqrtPriceX96 Initial sqrt price as Q64.96. The operator
    ///        computes this from the CCA clearing price.
    /// @param tickLower Lower tick of the LP position. Must be aligned to
    ///        `tickSpacing` and ≤ `tickUpper`.
    /// @param tickUpper Upper tick of the LP position. Must be aligned to
    ///        `tickSpacing` and ≥ `tickLower`.
    /// @param positionManagerActions Pre-encoded `Actions.MINT_POSITION` +
    ///        `Actions.SETTLE_PAIR` calldata. Computed off-chain by the
    ///        operator's deploy script (or a privileged frontend) using the
    ///        v4-periphery `Actions` helper. The seeder forwards it via
    ///        `PositionManager.multicall` after approving balances.
    function bootstrap(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        bytes[] calldata positionManagerActions
    ) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        _validateTicks(tickLower, tickUpper);

        (uint256 usdcBalance, uint256 gccBalance) = _checkBalances();

        // V4 sorts currencies by address; PoolKey requires currency0 < currency1.
        (address c0, address c1) = address(usdc) < address(gcc)
            ? (address(usdc), address(gcc))
            : (address(gcc), address(usdc));

        // 1. Initialise the pool. Reverts if it already exists — that's a
        //    valid retry case (operator may have pre-initialised manually
        //    before realising they should have used the seeder). In that
        //    case, redeploy a fresh seeder and call bootstrap.
        poolManager.initialize(
            IV4PoolManager.PoolKey({
                currency0: c0,
                currency1: c1,
                fee: poolFee,
                tickSpacing: tickSpacing,
                hooks: address(0)
            }),
            sqrtPriceX96
        );

        _mintLpPosition(usdcBalance, gccBalance, positionManagerActions);

        initialized = true;

        emit V4PoolSeeded(
            address(poolManager), c0, c1, sqrtPriceX96, tickLower, tickUpper, usdcBalance, gccBalance
        );
    }

    /// @notice Add more liquidity to an already-initialised V4 pool. Used by
    ///         every CCA round AFTER the first one — the unified-CCA issuance
    ///         model has the platform mint a fresh GCC tranche, auction it,
    ///         then add the proceeds as additional V4 LP via this method.
    ///
    ///         Like `bootstrap`, the operator pre-funds the seeder with the
    ///         desired USDC + GCC, picks the position range, and supplies the
    ///         pre-encoded `Actions.MINT_POSITION` + `Actions.SETTLE_PAIR`
    ///         calldata. Unlike `bootstrap`, this method does NOT call
    ///         `PoolManager.initialize` — the pool must already exist (either
    ///         seeded by this contract's earlier `bootstrap` or initialised
    ///         out-of-band by ops).
    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        bytes[] calldata positionManagerActions
    ) external onlyOwner {
        if (!initialized) revert NotInitialized();
        _validateTicks(tickLower, tickUpper);

        (uint256 usdcBalance, uint256 gccBalance) = _checkBalances();
        _mintLpPosition(usdcBalance, gccBalance, positionManagerActions);

        emit V4LiquidityAdded(tickLower, tickUpper, usdcBalance, gccBalance);
    }

    // ── internal helpers ──────────────────────────────────────────────────

    function _validateTicks(int24 tickLower, int24 tickUpper) private view {
        if (tickLower > tickUpper) revert InvalidTickRange();
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert TickNotAligned();
        }
    }

    function _checkBalances() private view returns (uint256 usdcBalance, uint256 gccBalance) {
        usdcBalance = usdc.balanceOf(address(this));
        gccBalance = gcc.balanceOf(address(this));
        if (usdcBalance == 0 || gccBalance == 0) revert NoLiquidity();
    }

    /// @dev Approve PositionManager to pull our balances, execute the
    ///      operator-supplied multicall (which under v4-periphery convention
    ///      is `MINT_POSITION` + `SETTLE_PAIR`), and clear allowances back to
    ///      zero. `forceApprove` tolerates ERC20s that require an explicit
    ///      reset to zero before approval changes (e.g. legacy USDT).
    function _mintLpPosition(
        uint256 usdcBalance,
        uint256 gccBalance,
        bytes[] calldata positionManagerActions
    ) private {
        usdc.forceApprove(address(positionManager), usdcBalance);
        gcc.forceApprove(address(positionManager), gccBalance);
        positionManager.multicall(positionManagerActions);
        usdc.forceApprove(address(positionManager), 0);
        gcc.forceApprove(address(positionManager), 0);
    }

    /// @notice Owner-only escape hatch. Sweeps any ERC20 (or ETH if `token`
    ///         is the zero address) held by the seeder to `to`. Useful for
    ///         (a) residual USDC/GCC that arrived after `bootstrap()`,
    ///         (b) tokens accidentally sent to the contract, (c) recovering
    ///         funds if `bootstrap` is permanently bricked (e.g. PoolManager
    ///         upgraded to a new address before we managed to seed).
    function recover(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            require(ok, "transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Recovered(token, to, amount);
    }

    /// @notice Allow plain ETH transfers in case anyone funds the seeder for
    ///         multicall msg.value needs. Currently the standard V4 mint
    ///         path is fully ERC20-based, so this is just a safety net.
    receive() external payable {}
}
