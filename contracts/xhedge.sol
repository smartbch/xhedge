// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface PriceOracle {
	function getPrice() external returns (uint);
}

struct Vault {
	uint64 initCollateralRate;
	uint64 minCollateralRate;
	uint64 closeoutPenalty;
	uint32 matureTime; // in minutes
	uint32 lastVoteTime; // in minutes

	address validatorToVote;
	uint96  hedgeValue;

	address oracle;
	uint96  amount; // at most 85 bits (21 * 1e6 * 1e18)
}

contract XHedge is ERC721 {
	mapping (uint => Vault) internal snToVault; //TODO: use sep101
	mapping (address => uint) public valToVotes; 
	address[] public validators;
	uint[128] internal nextSN;
	uint constant GlobalMinimumAmount = 10**15; //0.001 BCH

	event UpdateValidatorToVote(uint indexed sn, address validatorToVote);
	event UpdateAmount(uint indexed sn, uint96 newAmount);
	event Vote(address indexed validator, uint indexed sn, uint incrVotes, uint newAccumulatedVotes);

	constructor() ERC721("XHedge", "XH") {
	}

	function createVault(
		uint64 initCollateralRate, 
		uint64 minCollateralRate,
		uint64 closeoutPenalty, 
		uint32 matureTime,
		address validatorToVote, 
		uint96 hedgeValue, 
		address oracle) external payable {
		Vault memory vault;
		vault.initCollateralRate = initCollateralRate;
		vault.minCollateralRate = minCollateralRate;
		vault.closeoutPenalty = closeoutPenalty;
		vault.lastVoteTime = uint32((block.timestamp+59)/60);
		vault.hedgeValue = hedgeValue;
		vault.matureTime = matureTime;
		//TODO: make sure validatorToVote is already registered as a validator
		vault.validatorToVote = validatorToVote;
		vault.oracle = oracle;
		uint price = PriceOracle(oracle).getPrice();
		uint amount = (10**18 + uint(initCollateralRate)) * uint(hedgeValue) / price;
		require(amount != 0);
		require(msg.value >= amount);
		require(amount >= GlobalMinimumAmount);
		vault.amount = uint96(amount);
		if(msg.value > amount) {
			msg.sender.call{value: msg.value - amount}(""); //TODO: use SEP206
		}
		uint idx = uint160(msg.sender) & 127;
		uint sn = nextSN[idx];
		nextSN[idx] = sn + 1;
		sn = (sn<<8)+(idx<<1);
		_safeMint(msg.sender, (sn<<1)+1); //the LeverNFT
		_safeMint(msg.sender, sn<<1); //the HedgeNFT
		snToVault[sn] = vault;
	}

	function liquidate(uint token) external {
		_liquidate(token, false);
	}

	function closeout(uint token) external {
		_liquidate(token, true);
	}

	function _liquidate(uint token, bool isCloseout) internal {
		require(ownerOf(token) == msg.sender);
		uint sn = token>>1;
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0);
		uint price = PriceOracle(vault.oracle).getPrice();
		if(isCloseout) {
			require(block.timestamp < uint(vault.matureTime)*60);
			uint minAmount = (10**18 + uint(vault.minCollateralRate)) * uint(vault.hedgeValue) / price;
			require(vault.amount <= minAmount);
			require(token%2==0); // a HedgeNFT
		} else {
			require(block.timestamp >= uint(vault.matureTime)*60);
		}
		uint hedgeAmount = uint(vault.hedgeValue) * price;
		if(isCloseout) {
			hedgeAmount = hedgeAmount * (10**18 + vault.closeoutPenalty) / 10**18;
		}
		if(hedgeAmount > vault.amount) {
			hedgeAmount = vault.amount;
		}
		uint hedgeNFT =  sn<<1;
		uint leverNFT = hedgeNFT + 1;
		_burn(hedgeNFT);
		_burn(leverNFT);
		delete snToVault[sn];
		ownerOf(hedgeNFT).call{value: hedgeAmount}(""); //TODO: use SEP206
		ownerOf(leverNFT).call{value: vault.amount - hedgeAmount}(""); //TODO: use SEP206
	}

	function burn(uint sn) external {
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0);
		uint hedgeNFT =  sn<<1;
		uint leverNFT = hedgeNFT + 1;
		require(msg.sender == ownerOf(hedgeNFT) && msg.sender == ownerOf(leverNFT));
		delete snToVault[sn];
		msg.sender.call{value: vault.amount}(""); //TODO: use SEP206
	}

	function changeAmount(uint sn, uint96 amount) external payable {
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0);
		uint leverNFT = (sn<<1)+1;
		require(msg.sender == ownerOf(leverNFT));
		if(amount > vault.amount) {
			require(msg.value == amount - vault.amount);
			vault.amount = amount;
			snToVault[sn] = vault;
			emit UpdateAmount(sn, amount);
			return;
		}

		// because the amount will be changed, we vote here
		_vote(vault, sn);

		uint diff = vault.amount - amount;
		uint fee = diff * 5 / 1000; // fee as BCH
		uint price = PriceOracle(vault.oracle).getPrice();
		vault.hedgeValue = vault.hedgeValue + uint96(fee*price/*fee as USD*/);
		uint minAmount = (10**18 + uint(vault.minCollateralRate)) * uint(vault.hedgeValue) / price;
		require(amount > minAmount && amount >= GlobalMinimumAmount);
		vault.amount = amount;
		snToVault[sn] = vault;
		msg.sender.call{value: diff - fee}(""); //TODO: use SEP206
		emit UpdateAmount(sn, amount);
	}

	function changeValidatorToVote(uint sn, address validatorToVote) external {
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0);
		uint leverNFT = (sn<<1)+1;
		require(msg.sender == ownerOf(leverNFT));
		//TODO: make sure validatorToVote is already registered as a validator
		vault.validatorToVote = validatorToVote;
		snToVault[sn] = vault;
		emit UpdateValidatorToVote(sn, validatorToVote);
	}

	function _vote(Vault memory vault, uint sn) internal {
		if(block.timestamp > 60*vault.lastVoteTime) {
			uint incrVotes = vault.amount * (block.timestamp - 60*vault.lastVoteTime);
			address val = vault.validatorToVote;
			uint oldVotes = valToVotes[val];
			if(oldVotes == 0) { // find a new validator
				validators.push(val);
			}
			uint newVotes = oldVotes + incrVotes;
			emit Vote(val, sn, incrVotes, newVotes);
			valToVotes[val] = newVotes;
		}
		vault.lastVoteTime = uint32((block.timestamp+59)/60);
	}

	function vote(uint sn) external {
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0);
		_vote(vault, sn);
		snToVault[sn] = vault;
	}
}
