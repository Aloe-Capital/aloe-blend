// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./libraries/FullMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/Silo.sol";
import "./libraries/Uniswap.sol";
import "./libraries/Volatility.sol";

import "./interfaces/IAloeBlend.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IVolatilityOracle.sol";

import "./AloeBlendERC20.sol";
import "./UniswapHelper.sol";

/*
                              #                                                                    
                             ###                                                                   
                             #####                                                                 
          #                 #######                                *###*                           
           ###             #########                         ########                              
           #####         ###########                   ###########                                 
           ########    ############               ############                                     
            ########    ###########         *##############                                        
           ###########   ########      #################                                           
           ############   ###      #################                                               
           ############       ##################                                                   
          #############    #################*         *#############*                              
         ##############    #############      #####################################                
        ###############   ####******      #######################*                                 
      ################                                                                             
    #################   *############################*                                             
      ##############    ######################################                                     
          ########    ################*                     **######*                              
              ###    ###                                                                           
*/

uint256 constant Q96 = 2**96;

contract AloeBlend is AloeBlendERC20, UniswapHelper, ReentrancyGuard, IAloeBlend {
    using SafeERC20 for IERC20;
    using Uniswap for Uniswap.Position;
    using Silo for ISilo;

    /// @inheritdoc IAloeBlendImmutables
    uint24 public constant MIN_WIDTH = 201; // 1% of inventory in primary ✅

    /// @inheritdoc IAloeBlendImmutables
    uint24 public constant MAX_WIDTH = 13864; // 50% of inventory in primary ✅

    /// @inheritdoc IAloeBlendImmutables
    uint8 public constant K = 10;

    /// @inheritdoc IAloeBlendImmutables
    uint8 public constant B = 2; // primary position should cover 95% of trading activity ✅

    /// @inheritdoc IAloeBlendImmutables
    uint8 public constant MAINTENANCE_FEE = 10; // 10 --> 1/10th of earnings from primary Uniswap position ✅

    /// @inheritdoc IAloeBlendImmutables
    IVolatilityOracle public immutable volatilityOracle;

    /// @inheritdoc IAloeBlendImmutables
    ISilo public immutable silo0;

    /// @inheritdoc IAloeBlendImmutables
    ISilo public immutable silo1;

    /// @inheritdoc IAloeBlendState
    Uniswap.Position public primary;

    // TODO
    Uniswap.Position public limit;

    uint256 public recenterTimestamp;

    /// @inheritdoc IAloeBlendState
    uint256 public maintenanceBudget0;

    /// @inheritdoc IAloeBlendState
    uint256 public maintenanceBudget1;

    /// @dev Required for some silos
    receive() external payable {}

    constructor(
        IUniswapV3Pool _uniPool,
        ISilo _silo0,
        ISilo _silo1
    )
        AloeBlendERC20(
            // ex: Aloe Blend USDC/WETH
            string(
                abi.encodePacked(
                    "Aloe Blend ",
                    IERC20Metadata(_uniPool.token0()).symbol(),
                    "/",
                    IERC20Metadata(_uniPool.token1()).symbol()
                )
            )
        )
        UniswapHelper(_uniPool)
    {
        volatilityOracle = IFactory(msg.sender).VOLATILITY_ORACLE();
        silo0 = _silo0;
        silo1 = _silo1;
        recenterTimestamp = block.timestamp;

        (uint32 oldestObservation, , , ) = volatilityOracle.cachedPoolMetadata(address(_uniPool));
        require(oldestObservation > 1 hours, "Aloe: oracle");
    }

    /// @inheritdoc IAloeBlendDerivedState
    function getInventory()
        public
        view
        returns (
            uint256 inventory0,
            uint256 inventory1,
            uint256 fluid0,
            uint256 fluid1
        )
    {
        // Everything in silos + everything in the contract, except maintenance budget
        fluid0 = silo0.balanceOf(address(this)) + _balance0();
        fluid1 = silo1.balanceOf(address(this)) + _balance1();
        // Everything in Uniswap
        (inventory0, inventory1) = primary.collectableAmountsAsOfLastPoke(UNI_POOL);
        // TODO add limit order amounts

        inventory0 += fluid0;
        inventory1 += fluid1;
    }

    function getRebalanceUrgency() public view returns (uint32 urgency) {
        urgency = uint32(FullMath.mulDiv(10_000, block.timestamp - recenterTimestamp, 24 hours));
    }

    /// @inheritdoc IAloeBlendActions
    function deposit(
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 amount0Min,
        uint256 amount1Min
    )
        public
        nonReentrant
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(amount0Max != 0 || amount1Max != 0, "Aloe: 0 deposit");

        // Poke all assets
        primary.poke(UNI_POOL);
        limit.poke(UNI_POOL);
        silo0.delegate_poke();
        silo1.delegate_poke();

        // Fetch instantaneous price from Uniswap
        (uint160 sqrtPriceX96, , , , , , ) = UNI_POOL.slot0();
        uint224 priceX96 = uint224(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96));

        (shares, amount0, amount1) = _computeLPShares(amount0Max, amount1Max, priceX96);
        require(shares != 0, "Aloe: 0 shares");
        require(amount0 >= amount0Min, "Aloe: amount0 too low");
        require(amount1 >= amount1Min, "Aloe: amount1 too low");

        // Pull in tokens from sender
        TOKEN0.safeTransferFrom(msg.sender, address(this), amount0);
        TOKEN1.safeTransferFrom(msg.sender, address(this), amount1);

        // Mint shares
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, shares, amount0, amount1);
    }

    /// @inheritdoc IAloeBlendActions
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(shares != 0, "Aloe: 0 shares");
        uint256 _totalSupply = totalSupply + 1;
        uint256 temp0;
        uint256 temp1;

        // Portion from contract
        // NOTE: Must be done FIRST to ensure we don't double count things after exiting Uniswap/silos
        amount0 = FullMath.mulDiv(_balance0(), shares, _totalSupply);
        amount1 = FullMath.mulDiv(_balance1(), shares, _totalSupply);

        // Portion from Uniswap
        (temp0, temp1) = _withdrawFractionFromUniswap(shares, _totalSupply);
        amount0 += temp0;
        amount1 += temp1;

        // Portion from silos
        temp0 = FullMath.mulDiv(silo0.balanceOf(address(this)), shares, _totalSupply);
        temp1 = FullMath.mulDiv(silo1.balanceOf(address(this)), shares, _totalSupply);
        silo0.delegate_withdraw(temp0);
        silo1.delegate_withdraw(temp1);
        amount0 += temp0;
        amount1 += temp1;

        // Check constraints
        require(amount0 >= amount0Min, "Aloe: amount0 too low");
        require(amount1 >= amount1Min, "Aloe: amount1 too low");

        // Transfer tokens
        TOKEN0.safeTransfer(msg.sender, amount0);
        TOKEN1.safeTransfer(msg.sender, amount1);

        // Burn shares
        _burn(msg.sender, shares);
        emit Withdraw(msg.sender, shares, amount0, amount1);
    }

    struct RebalanceCache {
        uint160 sqrtPriceX96;
        uint96 magic;
        int24 tick;
        uint24 w;
        uint32 urgency;
        uint224 priceX96;
    }

    /// @inheritdoc IAloeBlendActions
    function rebalance(address rewardToken) external nonReentrant {
        RebalanceCache memory cache;

        // Get current tick & price
        (cache.sqrtPriceX96, cache.tick, , , , , ) = UNI_POOL.slot0();
        cache.priceX96 = uint224(FullMath.mulDiv(cache.sqrtPriceX96, cache.sqrtPriceX96, Q96));
        // Get rebalance urgency (based on time elapsed since previous rebalance)
        cache.urgency = getRebalanceUrgency();

        // uint256 rebalanceIncentive = FullMath.mulDiv(cache.urgency, avgRebalanceCost, 10_000);
        // if (rebalanceIncentive > maintenanceBudget) rebalanceIncentive = maintenanceBudget;

        /*
        maintenanceBudget += 0.10 * earningsSinceLastRebalance
        urgency = timeSinceLastRebalance / 24 # hours
        rebalanceIncentive = min(urgency * avgRebalanceCost, maintenanceBudget)

        if maintenanceBudget > K * avgRebalanceCost:
            maintenanceBudget = K * avgRebalanceCost

        ///////

        positionWidth = 2 * B * IV * currentPrice
        if maintenanceBudget == 0:
            positionWidth = maxWidth # this part is optional, but could help de-risk

        */

        Uniswap.Position memory _limit = limit;
        _limit.withdraw(UNI_POOL, _limit.liquidity);

        (uint256 inventory0, uint256 inventory1, uint256 fluid0, uint256 fluid1) = getInventory();
        uint256 ratio = FullMath.mulDiv(
            10_000,
            inventory0,
            inventory0 + FullMath.mulDiv(inventory1, Q96, cache.priceX96)
        );

        if (ratio < 4900) {
            // Attempt to sell token1 for token0. Place a limit order below the active range
            _limit.upper = TickMath.floor(cache.tick, TICK_SPACING);
            _limit.lower = _limit.upper - TICK_SPACING;
            // Choose amount1 such that ratio will be 50/50 once the limit order is pushed through. Division by 2
            // works for small tickSpacing. Also have to constrain to fluid1 since we're not yet withdrawing from
            // primary Uniswap position.
            uint256 amount1 = (inventory1 - FullMath.mulDiv(inventory0, cache.priceX96, Q96)) >> 1;
            if (amount1 > fluid1) amount1 = fluid1;
            // Withdraw requisite amount from silo
            uint256 balance1 = _balance1();
            if (balance1 < amount1) silo1.delegate_withdraw(amount1 - balance1);
            // Deposit to new limit order and store bounds
            _limit.liquidity = _limit.liquidityForAmount1(amount1);
            _limit.deposit(UNI_POOL, _limit.liquidity);
            limit.lower = _limit.lower;
            limit.upper = _limit.upper;
            limit.liquidity = _limit.liquidity;
        } else if (ratio > 5100) {
            // Attempt to sell token0 for token1. Place a limit order above the active range
            _limit.lower = TickMath.ceil(cache.tick, TICK_SPACING);
            _limit.upper = _limit.lower + TICK_SPACING;
            // Choose amount0 such that ratio will be 50/50 once the limit order is pushed through. Division by 2
            // works for small tickSpacing. Also have to constrain to fluid0 since we're not yet withdrawing from
            // primary Uniswap position.
            uint256 amount0 = (inventory0 - FullMath.mulDiv(inventory1, Q96, cache.priceX96)) >> 1;
            if (amount0 > fluid0) amount0 = fluid0;
            // Withdraw requisite amount from silo
            uint256 balance0 = _balance0();
            if (balance0 < amount0) silo0.delegate_withdraw(amount0 - balance0);
            // Deposit to new limit order and store bounds
            _limit.liquidity = _limit.liquidityForAmount0(amount0);
            _limit.deposit(UNI_POOL, _limit.liquidity);
            limit.lower = _limit.lower;
            limit.upper = _limit.upper;
            limit.liquidity = _limit.liquidity;
        } else {
            recenter(cache);
        }
    }

    function recenter(RebalanceCache memory cache) private {
        Uniswap.Position memory _primary = primary;

        uint256 sigma = volatilityOracle.estimate24H(UNI_POOL, cache.sqrtPriceX96, cache.tick);
        cache.w = _computeNextPositionWidth(sigma);

        // Exit current Uniswap position
        {
            (uint128 liquidity, , , , ) = _primary.info(UNI_POOL);
            (, , uint256 earned0, uint256 earned1) = _primary.withdraw(UNI_POOL, liquidity);
            _earmarkSomeForMaintenance(earned0, earned1);
        }

        // Compute amounts that should be placed in new Uniswap position
        uint256 amount0;
        uint256 amount1;
        (uint256 inventory0, uint256 inventory1, , ) = getInventory();
        cache.w = cache.w >> 1;
        (amount0, amount1, cache.magic) = _computeAmountsForPrimary(inventory0, inventory1, cache.priceX96, cache.w);

        uint256 balance0 = _balance0();
        uint256 balance1 = _balance1();
        bool hasExcessToken0 = balance0 > amount0;
        bool hasExcessToken1 = balance1 > amount1;

        // Because of cToken exchangeRate rounding, we may withdraw too much
        // here. That's okay; dust will just sit in contract till next rebalance
        if (!hasExcessToken0) silo0.delegate_withdraw(amount0 - balance0);
        if (!hasExcessToken1) silo1.delegate_withdraw(amount1 - balance1);

        // Update Uniswap position's ticks
        _primary.lower = TickMath.floor(cache.tick - int24(cache.w), TICK_SPACING);
        _primary.upper = TickMath.ceil(cache.tick + int24(cache.w), TICK_SPACING);
        if (_primary.lower < TickMath.MIN_TICK) _primary.lower = TickMath.MIN_TICK;
        if (_primary.upper > TickMath.MAX_TICK) _primary.upper = TickMath.MAX_TICK;

        // Place some liquidity in Uniswap
        delete lastMintedAmount0;
        delete lastMintedAmount1;
        _primary.deposit(UNI_POOL, _primary.liquidityForAmounts(cache.sqrtPriceX96, amount0, amount1));
        primary.lower = _primary.lower;
        primary.upper = _primary.upper;

        // Place excess into silos
        if (hasExcessToken0) silo0.delegate_deposit(balance0 - lastMintedAmount0);
        if (hasExcessToken1) silo1.delegate_deposit(balance1 - lastMintedAmount1);

        recenterTimestamp = block.timestamp;
        emit Rebalance(_primary.lower, _primary.upper, cache.magic, cache.urgency, totalSupply, inventory0, inventory1);
    }

    /// @dev Calculates the largest possible `amount0` and `amount1` such that
    /// they're in the same proportion as total amounts, but not greater than
    /// `amount0Max` and `amount1Max` respectively.
    function _computeLPShares(
        uint256 amount0Max,
        uint256 amount1Max,
        uint224 priceX96
    )
        private
        view
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint256 _totalSupply = totalSupply;
        (uint256 inventory0, uint256 inventory1, , ) = getInventory();

        // If total supply > 0, pool can't be empty
        assert(_totalSupply == 0 || inventory0 != 0 || inventory1 != 0);

        if (_totalSupply == 0) {
            // For first deposit, enforce 50/50 ratio
            amount0 = FullMath.mulDiv(amount1Max, Q96, priceX96);

            if (amount0 < amount0Max) {
                amount1 = amount1Max;
                shares = amount1;
            } else {
                amount0 = amount0Max;
                amount1 = FullMath.mulDiv(amount0, priceX96, Q96);
                shares = amount0;
            }
        } else if (inventory0 == 0) {
            amount1 = amount1Max;
            shares = FullMath.mulDiv(amount1, _totalSupply, inventory1);
        } else if (inventory1 == 0) {
            amount0 = amount0Max;
            shares = FullMath.mulDiv(amount0, _totalSupply, inventory0);
        } else {
            amount0 = FullMath.mulDiv(amount1Max, inventory0, inventory1);

            if (amount0 < amount0Max) {
                amount1 = amount1Max;
                shares = FullMath.mulDiv(amount1, _totalSupply, inventory1);
            } else {
                amount0 = amount0Max;
                amount1 = FullMath.mulDiv(amount0, inventory1, inventory0);
                shares = FullMath.mulDiv(amount0, _totalSupply, inventory0);
            }
        }
    }

    /// @dev Computes amounts that should be placed in Uniswap position
    function _computeAmountsForPrimary(
        uint256 inventory0,
        uint256 inventory1,
        uint224 priceX96,
        uint24 halfWidth
    )
        internal
        pure
        returns (
            uint256 amount0,
            uint256 amount1,
            uint96 magic
        )
    {
        magic = uint96(Q96 - TickMath.getSqrtRatioAtTick(-int24(halfWidth)));
        if (FullMath.mulDiv(inventory0, priceX96, Q96) > inventory1) {
            amount1 = FullMath.mulDiv(inventory1, magic, Q96);
            amount0 = FullMath.mulDiv(amount1, Q96, priceX96);
        } else {
            amount0 = FullMath.mulDiv(inventory0, magic, Q96);
            amount1 = FullMath.mulDiv(amount0, priceX96, Q96);
        }
    }

    function _computeNextPositionWidth(uint256 sigma) internal pure returns (uint24) {
        if (sigma <= 5.024579e15) return MIN_WIDTH;
        if (sigma >= 3.000058e17) return MAX_WIDTH;
        sigma *= B; // scale by a constant factor to increase confidence

        unchecked {
            uint160 ratio = uint160((Q96 * (1e18 + sigma)) / (1e18 - sigma));
            return uint24(TickMath.getTickAtSqrtRatio(ratio)) >> 1;
        }
    }

    /// @dev Withdraws fraction of liquidity from Uniswap, but collects *all* fees from it
    function _withdrawFractionFromUniswap(uint256 numerator, uint256 denominator)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        assert(numerator < denominator);
        Uniswap.Position memory _primary = primary;

        (uint128 liquidity, , , , ) = _primary.info(UNI_POOL);
        liquidity = uint128(FullMath.mulDiv(liquidity, numerator, denominator));

        uint256 earned0;
        uint256 earned1;
        (amount0, amount1, earned0, earned1) = _primary.withdraw(UNI_POOL, liquidity);
        (earned0, earned1) = _earmarkSomeForMaintenance(earned0, earned1);
        // TODO withdraw from limit

        // Add share of earned fees
        amount0 += FullMath.mulDiv(earned0, numerator, denominator);
        amount1 += FullMath.mulDiv(earned1, numerator, denominator);
    }

    /// @dev Earmark some earned fees for maintenance, according to `maintenanceFee`. Return what's leftover
    function _earmarkSomeForMaintenance(uint256 earned0, uint256 earned1) private returns (uint256, uint256) {
        uint256 toMaintenance;

        unchecked {
            // Accrue token0
            toMaintenance = earned0 / MAINTENANCE_FEE;
            earned0 -= toMaintenance;
            maintenanceBudget0 += toMaintenance;
            // Accrue token1
            toMaintenance = earned1 / MAINTENANCE_FEE;
            earned1 -= toMaintenance;
            maintenanceBudget1 += toMaintenance;
        }

        return (earned0, earned1);
    }

    function _balance0() private view returns (uint256) {
        return TOKEN0.balanceOf(address(this)) - maintenanceBudget0;
    }

    function _balance1() private view returns (uint256) {
        return TOKEN1.balanceOf(address(this)) - maintenanceBudget1;
    }
}
