// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "./xhedge.sol";

contract MockOracle is PriceOracle {

	uint private price;

	constructor(uint initPrice) {
		price = initPrice;
	}

	function getPrice() external view override returns (uint) {
		return price;
	}

	function setPrice(uint _price) external {
		price = _price;
	}

}
