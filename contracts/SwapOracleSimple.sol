pragma solidity >=0.8.0;

import "./xhedge.sol";

// interface IUniswapV2Factory {
//     function pairFor(address tokenA, address tokenB) external view returns (address pair);
//     function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);
// }

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
}

library OracleLibrary {

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(address pair) internal view returns 
            (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {

        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative += uint(fraction(reserve1, reserve0)) * timeElapsed;
            // counterfactual
            price1Cumulative += uint(fraction(reserve0, reserve1)) * timeElapsed;
        }
    }

    function fraction(uint112 numerator, uint112 denominator) private pure returns (uint224) {
        require(denominator > 0, "FixedPoint: DIV_BY_ZERO");
        return uint224((uint224(numerator) << 112) / denominator);
    }

}

contract SwapOracleSimple is PriceOracle {

    address public immutable pair;
    address public constant WBCH = 0x3743eC0673453E5009310C727Ba4eaF7b3a1cc04;
    address public constant flexUSD = 0x7b2B3C5308ab5b2a1d9a94d20D35CCDf61e05b72;
    uint public constant CYCLE = 30 minutes;

    uint timestampLast;
    uint price0CumulativeLast;
    uint price1CumulativeLast;
    uint price0Average;
    uint price1Average;

    constructor(address _pair) public {
        require(IUniswapV2Pair(_pair).token0() == WBCH);
        require(IUniswapV2Pair(_pair).token1() == flexUSD);
        pair = _pair;
    }

    function update() private {
        uint timeElapsed = block.timestamp - timestampLast;
        // require(timeElapsed >= CYCLE, 'Oracle: PERIOD_NOT_ELAPSED');
        if (timeElapsed < CYCLE) {
        	return;
        }

        (uint price0Cumulative, uint price1Cumulative,) = OracleLibrary.currentCumulativePrices(pair);
        timestampLast = block.timestamp;

        price0Average = ((price0Cumulative - price0CumulativeLast) / timeElapsed) * (10**18) / (2**112);
        price1Average = ((price1Cumulative - price1CumulativeLast) / timeElapsed) * (10**18) / (2**112);

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
    }

    // price0CumulativeLast = token1/token0
    // price1CumulativeLast = token0/token1
    function getPrice() external override returns (uint) {
        update();
        return price0Average;
    }

}
