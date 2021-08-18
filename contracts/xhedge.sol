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

// @dev XHedge splits BCH into a pair of LeverNFT and HedgeNFT. When this pair of NFTs get burnt, the BCH
// are liquidated to the owners of them.
// The LeverNFT's owner can also vote for a validator on smartBCH.
contract XHedge is ERC721 {
	mapping (uint => Vault) public snToVault; //TODO: use sep101

	// This is an array of counters for calculating a new NFT's id.
	// we use 128 counters to avoid inter-dependency between the transactions calling createVault
	uint[128] internal nextSN; // we use an array of nextSN counters to avoid inter-dependency


	// The validators' accumulated votes in current epoch. When switching epoch, this variable will be
	// be cleared by the underlying golang logic in staking contract
	mapping (address => uint) public valToVotes; 

	// The validators who have ever get voted in current epoch. When switching epoch, this variable will be
	// be cleared by the underlying golang logic in staking contract
	address[] public validators;

	// To prevent dust attack, we need to set a lower bound for how much BCH a vault locks
	uint constant GlobalMinimumAmount = 10**14; //0.0001 BCH

	// @dev Emitted when `sn` vault has updated its supported validator to `newValidator`.
	event UpdateValidatorToVote(uint indexed sn, address indexed newValidator);

	// @dev Emitted when `sn` vault has updated its locked BCH amount to `newAmount`.
	event UpdateAmount(uint indexed sn, uint96 newAmount);

	// @dev Emitted when `sn` vault has voted `incrVotes` to `validator`, making its accumulated votes to be `newAccumulatedVotes`.
	event Vote(uint indexed sn, address indexed validator, uint incrVotes, uint newAccumulatedVotes);

	constructor() ERC721("XHedge", "XH") {}

	// @dev Create a vault which locks some BCH, and mint a pair of LeverNFT/HedgeNFT
	// The id of LeverNFT (HedgeNFT) is `sn*2+1` (`sn*2`), respectively, where `sn` is the serial number of the vault.
	// @param initCollateralRate the initial collateral rate
	// @param minCollateralRate the minimum collateral rate
	// @param closeoutPenalty the penalty for LeverNFT's owner at closeout, with 18 decimal digits
	// @param matureTime the time when any owner of this pair of NFTs can initiate liquidation without penalty
	// @param validatorToVote the validator that the LeverNFT's owner would like to support
	// @param hedgeValue the value (measured in USD) that the LeverNFT contains
	// @param oracle the address of a smart contract which can provide the price of BCH (measured in USD). It must support the `PriceOracle` interface
	//
	// Requirements:
	//
	// - The paid value for calling this function must be no less than the calculated amount. (If paid more, the extra coins will be returned)
	// - The locked BCH must be no less than `GlobalMinimumAmount`, to prevent dust attack

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
		vault.validatorToVote = validatorToVote;
		vault.oracle = oracle;
		uint price = PriceOracle(oracle).getPrice();
		uint amount = (10**18 + uint(initCollateralRate)) * uint(hedgeValue) / price;
		require(msg.value >= amount, "NOT_ENOUGH_PAID");
		require(amount >= GlobalMinimumAmount, "LOCKED_AMOUNT_TOO_SMALL");
		vault.amount = uint96(amount);
		if(msg.value > amount) { // return the extra coins
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

	// @dev Initiate liquidation before mature time
	// @param token the HedgeNFT whose owner wants to liquidate
	// Requirements:
	//
	// - The token must exist (not burnt yet)
	// - Current timestamp must be smaller than the mature time
	// - Current price must be low enough such that collateral rate is below the predefined minimum value
	function closeout(uint token) external {
		_liquidate(token, true);
	}

	// @dev Initiate liquidation after mature time
	// @param token the HedgeNFT or LeverNFT whose owner wants to liquidate
	// Requirements:
	//
	// - The token must exist (not burnt yet)
	// - Current timestamp must be larger than or equal to the mature time
	function liquidate(uint token) external {
		_liquidate(token, false);
	}

	// @dev Initiate liquidation before mature time (isCloseout=true) or after mature time (isCloseout=false) 
	function _liquidate(uint token, bool isCloseout) internal {
		require(ownerOf(token) == msg.sender, "NOT_OWNER");
		uint sn = token>>1;
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		uint price = PriceOracle(vault.oracle).getPrice();
		if(isCloseout) {
			require(block.timestamp < uint(vault.matureTime)*60, "ALREADY_MATURE");
			uint minAmount = (10**18 + uint(vault.minCollateralRate)) * uint(vault.hedgeValue) / price;
			require(vault.amount <= minAmount);
			require(token%2==0, "NOT_HEDGE_NFT"); // a HedgeNFT
		} else {
			require(block.timestamp >= uint(vault.matureTime)*60, "NOT_MATURE");
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

	// @dev Burn the vault's LeverNFT&HedgeNFT, delete the vault, and get back all the locked BCH
	// @param sn the serial number of the vault
	// Requirements:
	//
	// - The vault must exist (not deleted yet)
	// - The sender must own both the LeverNFT and the HedgeNFT
	function burn(uint sn) external {
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		uint hedgeNFT =  sn<<1;
		uint leverNFT = hedgeNFT + 1;
		require(msg.sender == ownerOf(hedgeNFT) && msg.sender == ownerOf(leverNFT), "NOT_OWNER");
		_burn(hedgeNFT);
		_burn(leverNFT);
		delete snToVault[sn];
		msg.sender.call{value: vault.amount}(""); //TODO: use SEP206
	}

	// @dev change the amount of BCH locked in the `sn` vault to `newAmount`
	// Vote with the accumulated coin-days in the `sn` vault and reset coin-days to zero
	//
	// @param sn the serial number of the vault
	// @param newAmount the new amount after changing
	// Requirements:
	//
	// - The vault must exist (not deleted yet)
	// - The sender must be the LeverNFT's owner, if the amount is decreased
	// - Enough BCH must be transferred when calling this function, if the amount is increased
	// - The locked BCH must be no less than `GlobalMinimumAmount`, to prevent dust attack
	// - The new amount of locked BCH must meet the initial collateral rate requirement
	function changeAmount(uint sn, uint96 newAmount) external payable {
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		uint leverNFT = (sn<<1)+1;
		if(newAmount > vault.amount) {
			require(msg.value == newAmount - vault.amount, "BAD_MSG_VAL");
			vault.amount = newAmount;
			snToVault[sn] = vault;
			emit UpdateAmount(sn, newAmount);
			return;
		}

		// because the amount will be changed, we vote here
		_vote(vault, sn);

		require(msg.sender == ownerOf(leverNFT), "NOT_OWNER");
		uint diff = vault.amount - newAmount;
		uint fee = diff * 5 / 1000; // fee as BCH
		uint price = PriceOracle(vault.oracle).getPrice();
		vault.hedgeValue = vault.hedgeValue + uint96(fee*price/*fee as USD*/);
		uint minAmount = (10**18 + uint(vault.initCollateralRate)) * uint(vault.hedgeValue) / price;
		require(newAmount > minAmount && newAmount >= GlobalMinimumAmount);
		vault.amount = newAmount;
		snToVault[sn] = vault;
		msg.sender.call{value: diff - fee}(""); //TODO: use SEP206
		emit UpdateAmount(sn, newAmount);
	}

	// @dev Make `newValidator` the validator to whom the LeverNFT's owner would like to support
	// Requirements:
	//
	// - The vault must exist (not deleted yet)
	// - The sender must be the LeverNFT's owner
	function changeValidatorToVote(uint leverNFT, address newValidator) external {
		uint sn = leverNFT>>1;
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0);
		require(msg.sender == ownerOf(leverNFT), "NOT_OWNER");
		vault.validatorToVote = newValidator;
		snToVault[sn] = vault;
		emit UpdateValidatorToVote(sn, newValidator);
	}


	// @dev Vote with the accumulated coin-days in the `sn` vault and reset coin-days to zero
	// Requirements:
	//
	// - The vault must exist (not deleted yet)
	function vote(uint sn) external {
		Vault memory vault = snToVault[sn];
		require(vault.amount != 0);
		_vote(vault, sn);
		snToVault[sn] = vault;
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
			emit Vote(sn, val, incrVotes, newVotes);
			valToVotes[val] = newVotes;
		}
		vault.lastVoteTime = uint32((block.timestamp+59)/60);
	}
}
