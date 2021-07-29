// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "./libraries/Compound.sol";
import "./libraries/FullMath.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/Math.sol";
import "./libraries/TickMath.sol";
import "./libraries/Uniswap.sol";

import "./AloeBlendERC20.sol";
import "./UniswapMinter.sol";

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
                                                                                                                        
         ___       ___       ___       ___            ___       ___       ___       ___       ___       ___       ___   
        /\  \     /\__\     /\  \     /\  \          /\  \     /\  \     /\  \     /\  \     /\  \     /\  \     /\__\  
       /::\  \   /:/  /    /::\  \   /::\  \        /::\  \   /::\  \   /::\  \   _\:\  \    \:\  \   /::\  \   /:/  /  
      /::\:\__\ /:/__/    /:/\:\__\ /::\:\__\      /:/\:\__\ /::\:\__\ /::\:\__\ /\/::\__\   /::\__\ /::\:\__\ /:/__/   
      \/\::/  / \:\  \    \:\/:/  / \:\:\/  /      \:\ \/__/ \/\::/  / \/\::/  / \::/\/__/  /:/\/__/ \/\::/  / \:\  \   
        /:/  /   \:\__\    \::/  /   \:\/  /        \:\__\     /:/  /     \/__/   \:\__\    \/__/      /:/  /   \:\__\  
        \/__/     \/__/     \/__/     \/__/          \/__/     \/__/               \/__/               \/__/     \/__/  
*/

uint256 constant TWO_96 = 2**96;
uint256 constant TWO_144 = 2**144;

contract AloeBlend is AloeBlendERC20, UniswapMinter {
    using SafeERC20 for IERC20;

    using Uniswap for Uniswap.Position;

    using Compound for Compound.Market;

    event Deposit(address indexed sender, uint256 shares, uint256 amount0, uint256 amount1);

    event Withdraw(address indexed sender, uint256 shares, uint256 amount0, uint256 amount1);

    event Snapshot(int24 tick, uint256 totalAmount0, uint256 totalAmount1, uint256 totalSupply);

    /// @dev The number of standard deviations to +/- from mean when setting position bounds
    uint8 public K = 20;

    /// @dev The minimum width (in ticks) of the Uniswap position. 1000 --> 2.5% of total inventory
    int24 public MIN_WIDTH = 1000;

    Uniswap.Position public combine;

    Compound.Market public silo0;

    Compound.Market public silo1;

    /// @dev For reentrancy check
    bool private locked;

    modifier lock() {
        require(!locked, "Aloe: Locked");
        locked = true;
        _;
        locked = false;
    }

    /// @dev Required for Compound library to work
    receive() external payable {
        require(msg.sender == address(WETH) || msg.sender == address(Compound.CETH));
    }

    constructor(
        IUniswapV3Pool uniPool,
        address cToken0,
        address cToken1
    ) AloeBlendERC20() UniswapMinter(uniPool) {
        combine.pool = uniPool;
        silo0.initialize(cToken0);
        silo1.initialize(cToken1);
    }

    /**
     * @notice Calculates the vault's total holdings of TOKEN0 and TOKEN1 - in
     * other words, how much of each token the vault would hold if it withdrew
     * all its liquidity from Uniswap and Compound.
     */
    function getInventory() public view returns (uint256 inventory0, uint256 inventory1) {
        // Everything in Uniswap
        (inventory0, inventory1) = combine.collectableAmountsAsOfLastPoke();
        // Everything in Compound
        inventory0 += silo0.getBalance();
        inventory1 += silo1.getBalance();
        // Everything in the contract
        inventory0 += TOKEN0.balanceOf(address(this));
        inventory1 += TOKEN1.balanceOf(address(this));
    }

    function getNextPositionWidth() public view returns (int24 width) {
        (uint176 mean, uint176 sigma) = fetchPriceStatistics();
        width = TickMath.getTickAtSqrtRatio(uint160(TWO_96 + FullMath.mulDiv(TWO_96, K * sigma, mean)));
        if (width < MIN_WIDTH) width = MIN_WIDTH;
    }

    /**
     * @notice Deposits tokens in proportion to the vault's current holdings.
     * @dev These tokens sit in the vault and are not used for liquidity on
     * Uniswap until the next rebalance. Also note it's not necessary to check
     * if user manipulated price to deposit cheaper, as the value of range
     * orders can only by manipulated higher.
     * @dev LOCK MODIFIER IS APPLIED IN AloeBlendCapped!!!
     * @param amount0Max Max amount of TOKEN0 to deposit
     * @param amount1Max Max amount of TOKEN1 to deposit
     * @param amount0Min Ensure `amount0` is greater than this
     * @param amount1Min Ensure `amount1` is greater than this
     * @return shares Number of shares minted
     * @return amount0 Amount of TOKEN0 deposited
     * @return amount1 Amount of TOKEN1 deposited
     */
    function deposit(
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 amount0Min,
        uint256 amount1Min
    )
        public
        virtual
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(amount0Max != 0 || amount1Max != 0, "Aloe: 0 deposit");

        combine.poke();
        silo0.poke();
        silo1.poke();

        (shares, amount0, amount1) = _computeLPShares(amount0Max, amount1Max);
        require(shares != 0, "Aloe: 0 shares");
        require(amount0 >= amount0Min, "Aloe: amount0 too low");
        require(amount1 >= amount1Min, "Aloe: amount1 too low");

        // Pull in tokens from sender
        if (amount0 != 0) TOKEN0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) TOKEN1.safeTransferFrom(msg.sender, address(this), amount1);

        // Mint shares
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, shares, amount0, amount1);
    }

    /// @dev Calculates the largest possible `amount0` and `amount1` such that
    /// they're in the same proportion as total amounts, but not greater than
    /// `amount0Max` and `amount1Max` respectively.
    function _computeLPShares(uint256 amount0Max, uint256 amount1Max)
        internal
        view
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint256 totalSupply = totalSupply();
        (uint256 inventory0, uint256 inventory1) = getInventory();

        // If total supply > 0, pool can't be empty
        assert(totalSupply == 0 || inventory0 != 0 || inventory1 != 0);

        if (totalSupply == 0) {
            // For first deposit, just use the amounts desired
            amount0 = amount0Max;
            amount1 = amount1Max;
            shares = amount0 > amount1 ? amount0 : amount1; // max
        } else if (inventory0 == 0) {
            amount1 = amount1Max;
            shares = FullMath.mulDiv(amount1, totalSupply, inventory1);
        } else if (inventory1 == 0) {
            amount0 = amount0Max;
            shares = FullMath.mulDiv(amount0, totalSupply, inventory0);
        } else {
            amount0 = FullMath.mulDiv(amount1Max, inventory0, inventory1);

            if (amount0 < amount0Max) {
                amount1 = amount1Max;
                shares = FullMath.mulDiv(amount1, totalSupply, inventory1);
            } else {
                amount0 = amount0Max;
                amount1 = FullMath.mulDiv(amount0, inventory1, inventory0);
                shares = FullMath.mulDiv(amount0, totalSupply, inventory0);
            }
        }
    }

    /**
     * @notice Withdraws tokens in proportion to the vault's holdings.
     * @param shares Shares burned by sender
     * @param amount0Min Revert if resulting `amount0` is smaller than this
     * @param amount1Min Revert if resulting `amount1` is smaller than this
     * @return amount0 Amount of TOKEN0 sent to recipient
     * @return amount1 Amount of TOKEN1 sent to recipient
     */
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min
    ) external lock returns (uint256 amount0, uint256 amount1) {
        require(shares != 0, "Aloe: 0 shares");
        uint256 totalSupply = totalSupply() + 1;
        uint256 temp0;
        uint256 temp1;

        // Portion from contract
        // NOTE: Must be done FIRST to ensure we don't double count things after exiting Uniswap/Compound
        amount0 = FullMath.mulDiv(TOKEN0.balanceOf(address(this)), shares, totalSupply);
        amount1 = FullMath.mulDiv(TOKEN1.balanceOf(address(this)), shares, totalSupply);

        // Portion from Uniswap
        (temp0, temp1) = combine.withdrawFraction(shares, totalSupply);
        amount0 += temp0;
        amount1 += temp1;

        // Portion from Compound
        temp0 = FullMath.mulDiv(silo0.getBalance(), shares, totalSupply);
        temp1 = FullMath.mulDiv(silo1.getBalance(), shares, totalSupply);
        silo0.withdraw(temp0);
        silo1.withdraw(temp1);
        amount0 += temp0;
        amount1 += temp1;

        // Check constraints
        require(amount0 >= amount0Min, "Aloe: amount0 too low");
        require(amount1 >= amount1Min, "Aloe: amount1 too low");

        // Transfer tokens
        if (amount0 != 0) TOKEN0.safeTransfer(msg.sender, amount0);
        if (amount1 != 0) TOKEN1.safeTransfer(msg.sender, amount1);

        // Burn shares
        _burn(msg.sender, shares);
        emit Withdraw(msg.sender, shares, amount0, amount1);
    }

    function rebalance() external lock {
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = UNI_POOL.slot0();
        uint224 priceX96 = uint224(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, TWO_96));
        int24 w = getNextPositionWidth() >> 1;
        uint96 magic = uint96(TWO_96 - TickMath.getSqrtRatioAtTick(-w));

        Uniswap.Position memory _combine = combine;

        // Exit current Uniswap position
        {
            (uint128 liquidity, , , , ) = _combine.info();
            _combine.withdraw(liquidity);
        }

        (uint256 inventory0, uint256 inventory1) = getInventory();
        uint256 amount0;
        uint256 amount1;
        if (FullMath.mulDiv(inventory0, priceX96, TWO_96) > inventory1) {
            amount1 = FullMath.mulDiv(inventory1, magic, TWO_96);
            amount0 = FullMath.mulDiv(amount1, TWO_96, priceX96);
        } else {
            amount0 = FullMath.mulDiv(inventory0, magic, TWO_96);
            amount1 = FullMath.mulDiv(amount0, priceX96, TWO_96);
        }

        uint256 balance0 = TOKEN0.balanceOf(address(this));
        uint256 balance1 = TOKEN1.balanceOf(address(this));
        bool hasExcessToken0 = balance0 > amount0;
        bool hasExcessToken1 = balance1 > amount1;

        if (!hasExcessToken0) silo0.withdraw(amount0 - balance0);
        if (!hasExcessToken1) silo1.withdraw(amount1 - balance1);

        // Update combine's ticks
        _combine.lower = tick - w;
        _combine.upper = tick + w;
        _combine = _coerceTicksToSpacing(_combine);
        combine.lower = _combine.lower;
        combine.upper = _combine.upper;

        // Place some liquidity in Uniswap
        delete lastMintedAmount0;
        delete lastMintedAmount1;
        _combine.deposit(_combine.liquidityForAmounts(sqrtPriceX96, amount0, amount1));

        // Place excess into Compound
        if (hasExcessToken0) silo0.deposit(inventory0 - lastMintedAmount0);
        if (hasExcessToken1) silo1.deposit(inventory1 - lastMintedAmount1);
    }

    function _coerceTicksToSpacing(Uniswap.Position memory p) private view returns (Uniswap.Position memory) {
        int24 tickSpacing = TICK_SPACING;
        p.lower = p.lower - (p.lower < 0 ? tickSpacing + (p.lower % tickSpacing) : p.lower % tickSpacing);
        p.upper = p.upper + (p.upper < 0 ? -p.upper % tickSpacing : tickSpacing - (p.upper % tickSpacing));
        return p;
    }

    function fetchPriceStatistics() public view returns (uint176 mean, uint176 sigma) {
        (int56[] memory tickCumulatives, ) = UNI_POOL.observe(selectedOracleTimetable());

        // Compute mean price over the entire 54 minute period
        mean = TickMath.getSqrtRatioAtTick(int24((tickCumulatives[9] - tickCumulatives[0]) / 3240));
        mean = uint176(FullMath.mulDiv(mean, mean, TWO_144));

        // `stat` variable will take on a few different statistical values
        // Here it's MAD (Mean Absolute Deviation), except not yet divided by number of samples
        uint184 stat;
        uint176 sample;

        for (uint8 i = 0; i < 9; i++) {
            // Compute mean price over a 6 minute period
            sample = TickMath.getSqrtRatioAtTick(int24((tickCumulatives[i + 1] - tickCumulatives[i]) / 360));
            sample = uint176(FullMath.mulDiv(sample, sample, TWO_144));

            // Accumulate
            stat += sample > mean ? sample - mean : mean - sample;
        }

        // MAD = stat / n, here n = 10
        // STDDEV = MAD * sqrt(2/pi) for a normal distribution
        sigma = uint176((uint256(stat) * 79788) / 1000000);
    }

    function selectedOracleTimetable() public pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](10);
        secondsAgos[0] = 3420;
        secondsAgos[1] = 3060;
        secondsAgos[2] = 2700;
        secondsAgos[3] = 2340;
        secondsAgos[4] = 1980;
        secondsAgos[5] = 1620;
        secondsAgos[6] = 1260;
        secondsAgos[7] = 900;
        secondsAgos[8] = 540;
        secondsAgos[9] = 180;
    }
}
