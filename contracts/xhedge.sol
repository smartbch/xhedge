// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface PriceOracle {
	function getPrice() external returns (uint);
}

struct Vault {
	uint64 initCollateralRate;
	uint64 minCollateralRate;
	uint64 matureTime;
	uint64 lastVoteTime;
	uint validatorToVote;
	uint96 hedgeValue;
	address oracle;
	uint64 closeoutPenalty;
	uint96 amount; // at most 85 bits (21 * 1e6 * 1e18)
}

// @dev XHedge splits BCH into a pair of LeverNFT and HedgeNFT. When this pair of NFTs get burnt, the BCH
// are liquidated to the owners of them.
// The LeverNFT's owner can also vote for a validator on smartBCH.
abstract contract XHedgeBase is ERC721 {
	// This is an array of counters for calculating a new NFT's id.
	// we use 128 counters to avoid inter-dependency between the transactions calling createVault
	uint[128] internal nextSN; // we use an array of nextSN counters to avoid inter-dependency


	// The validators' accumulated votes in current epoch. When switching epoch, this variable will be
	// be cleared by the underlying golang logic in staking contract
	mapping (uint => uint) public valToVotes; 

	// The validators who have ever get voted in current epoch. When switching epoch, this variable will be
	// be cleared by the underlying golang logic in staking contract
	uint[] public validators;

	// @dev Emitted when `sn` vault has updated its supported validator to `newValidator`.
	event UpdateValidatorToVote(uint indexed sn, uint indexed newValidator);

	// @dev Emitted when `sn` vault has updated its locked BCH amount to `newAmount`.
	event UpdateAmount(uint indexed sn, uint96 newAmount);

	// @dev Emitted when `sn` vault has voted `incrVotes` to `validator`, making its accumulated votes to be `newAccumulatedVotes`.
	event Vote(uint indexed sn, uint indexed validator, uint incrVotes, uint newAccumulatedVotes);

	// To prevent dusting attack, we need to set a lower bound for how much BCH a vault locks
	uint constant GlobalMinimumAmount = 10**13; //0.00001 BCH

	// To prevent dusting attack, we need to set a lower bound for coin-days when voting for a new validator
	uint constant MinimumVotes = 500 * 10**18 * 24 * 3600; // 500 coin-days

	// @dev The address of precompile smart contract for SEP101
	address constant SEP101Contract = address(bytes20(uint160(0x2712)));

	// @dev The address of precompile smart contract for SEP206
	address constant SEP206Contract = address(bytes20(uint160(0x2711)));

	constructor() ERC721("XHedge", "XH") {}

	// virtual methods implemented by sub-contract
	function saveVault(uint sn, Vault memory vault) internal virtual;
	function loadVault(uint sn) public virtual returns (Vault memory vault);
	function deleteVault(uint sn) internal virtual;
	function safeTransfer(address receiver, uint value) internal virtual;

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
	// - The locked BCH must be no less than `GlobalMinimumAmount`, to prevent dusting attack

	function createVault(
		uint64 initCollateralRate, 
		uint64 minCollateralRate,
		uint64 closeoutPenalty, 
		uint64 matureTime,
		uint validatorToVote, 
		uint96 hedgeValue, 
		address oracle) public payable {
		Vault memory vault;
		vault.initCollateralRate = initCollateralRate;
		vault.minCollateralRate = minCollateralRate;
		vault.closeoutPenalty = closeoutPenalty;
		vault.lastVoteTime = uint64(block.timestamp);
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
			safeTransfer(msg.sender, msg.value - amount);
		}
		uint idx = uint160(msg.sender) & 127;
		uint sn = nextSN[idx];
		nextSN[idx] = sn + 1;
		sn = (sn<<8)+(idx<<1);
		_safeMint(msg.sender, (sn<<1)+1); //the LeverNFT
		_safeMint(msg.sender, sn<<1); //the HedgeNFT
		saveVault(sn, vault);
	}

	// @dev A "packed" version for createVault, to save space of calldata
	function createVaultPacked(uint initCollateralRate_minCollateralRate_closeoutPenalty_matureTime,
		uint validatorToVote, uint hedgeValue_oracle) external payable {
		uint64 initCollateralRate = uint64(initCollateralRate_minCollateralRate_closeoutPenalty_matureTime>>196);
		uint64 minCollateralRate = uint64(initCollateralRate_minCollateralRate_closeoutPenalty_matureTime>>128);
		uint64 closeoutPenalty = uint64(initCollateralRate_minCollateralRate_closeoutPenalty_matureTime>>64);
		uint64 matureTime = uint64(initCollateralRate_minCollateralRate_closeoutPenalty_matureTime);
		uint96 hedgeValue = uint96(hedgeValue_oracle>>160);
		address oracle = address(bytes20(uint160(hedgeValue_oracle)));
		return createVault(initCollateralRate, minCollateralRate, closeoutPenalty, 
			matureTime, validatorToVote, hedgeValue, oracle);
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
		Vault memory vault = loadVault(sn);
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		uint price = PriceOracle(vault.oracle).getPrice();
		if(isCloseout) {
			require(token%2==0, "NOT_HEDGE_NFT"); // a HedgeNFT
			require(block.timestamp < uint(vault.matureTime), "ALREADY_MATURE");
			uint minAmount = (10**18 + uint(vault.minCollateralRate)) * uint(vault.hedgeValue) / price;
			require(vault.amount <= minAmount, "PRICE_TOO_HIGH");
		} else {
			require(block.timestamp >= uint(vault.matureTime), "NOT_MATURE");
		}

		_vote(vault, sn); // clear the remained coin-days

		uint amountToHedgeOwner = uint(vault.hedgeValue) * 10**18 / price;
		if(isCloseout) {
			amountToHedgeOwner = amountToHedgeOwner * (10**18 + vault.closeoutPenalty) / 10**18;
		}
		if(amountToHedgeOwner > vault.amount) {
			amountToHedgeOwner = vault.amount;
		}
		uint hedgeNFT =  sn<<1;
		uint leverNFT = hedgeNFT + 1;
		address hedgeOwner = ownerOf(hedgeNFT);
		address leverOwner = ownerOf(leverNFT);
		_burn(hedgeNFT);
		_burn(leverNFT);
		deleteVault(sn);
		safeTransfer(hedgeOwner, amountToHedgeOwner);
		safeTransfer(leverOwner, vault.amount - amountToHedgeOwner);
	}

	// @dev Burn the vault's LeverNFT&HedgeNFT, delete the vault, and get back all the locked BCH
	// @param sn the serial number of the vault
	// Requirements:
	//
	// - The vault must exist (not deleted yet)
	// - The sender must own both the LeverNFT and the HedgeNFT
	function burn(uint sn) external {
		Vault memory vault = loadVault(sn);
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		uint hedgeNFT =  sn<<1;
		uint leverNFT = hedgeNFT + 1;
		require(msg.sender == ownerOf(hedgeNFT) && msg.sender == ownerOf(leverNFT), "NOT_WHOLE_OWNER");
		_vote(vault, sn); // clear the remained coin-days
		_burn(hedgeNFT);
		_burn(leverNFT);
		deleteVault(sn);
		safeTransfer(msg.sender, vault.amount);
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
	// - The locked BCH must be no less than `GlobalMinimumAmount`, to prevent dusting attack
	// - The new amount of locked BCH must meet the initial collateral rate requirement
	function changeAmount(uint sn, uint96 newAmount) external payable {
		Vault memory vault = loadVault(sn);
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		uint leverNFT = (sn<<1)+1;

		// because the amount will be changed, we vote here
		_vote(vault, sn);

		if(newAmount > vault.amount) {
			require(msg.value == newAmount - vault.amount, "BAD_MSG_VAL");
			vault.amount = newAmount;
			saveVault(sn, vault);
			emit UpdateAmount(sn, newAmount);
			return;
		}

		require(msg.sender == ownerOf(leverNFT), "NOT_OWNER");
		uint diff = vault.amount - newAmount;
		uint fee = diff * 5 / 1000; // fee as BCH
		newAmount = newAmount + uint96(fee);
		uint price = PriceOracle(vault.oracle).getPrice();
		vault.hedgeValue = vault.hedgeValue + uint96(fee*price / 10**18/*fee as USD*/);
		uint minAmount = (10**18 + uint(vault.initCollateralRate)) * uint(vault.hedgeValue) / price;
		require(newAmount > minAmount && newAmount >= GlobalMinimumAmount, "AMT_NOT_ENOUGH");
		vault.amount = newAmount;
		saveVault(sn, vault);
		safeTransfer(msg.sender, diff - fee);
		emit UpdateAmount(sn, newAmount);
	}

	// @dev Make `newValidator` the validator to whom the LeverNFT's owner would like to support
	// Requirements:
	//
	// - The vault must exist (not deleted yet)
	// - The sender must be the LeverNFT's owner
	function changeValidatorToVote(uint leverNFT, uint newValidator) external {
		require(leverNFT%2==1, "NOT_LEVER_NFT"); // must be a LeverNFT
		uint sn = leverNFT>>1;
		Vault memory vault = loadVault(sn);
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		require(msg.sender == ownerOf(leverNFT), "NOT_OWNER");
		vault.validatorToVote = newValidator;
		saveVault(sn, vault);
		emit UpdateValidatorToVote(sn, newValidator);
	}


	// @dev Vote with the accumulated coin-days in the `sn` vault and reset coin-days to zero
	// Requirements:
	//
	// - The vault must exist (not deleted yet)
	function vote(uint sn) external {
		Vault memory vault = loadVault(sn);
		require(vault.amount != 0, "VAULT_NOT_FOUND");
		_vote(vault, sn);
		saveVault(sn, vault);
	}

	function _vote(Vault memory vault, uint sn) internal {
		if(block.timestamp > vault.lastVoteTime) {
			uint incrVotes = vault.amount * (block.timestamp - vault.lastVoteTime);
			uint val = vault.validatorToVote;
			uint oldVotes = valToVotes[val];
			if(oldVotes == 0) { // find a new validator
				require(incrVotes >= MinimumVotes, "NOT_ENOUGH_VOTES_FOR_NEW_VAL");
				validators.push(val);
			}
			uint newVotes = oldVotes + incrVotes;
			emit Vote(sn, val, incrVotes, newVotes);
			valToVotes[val] = newVotes;
		}
		vault.lastVoteTime = uint32(block.timestamp);
	}
}

contract XHedge is XHedgeBase {
	mapping (uint => Vault) private snToVault;

	function saveVault(uint sn, Vault memory vault) internal override {
		snToVault[sn] = vault;
	}

	function loadVault(uint sn) public override view returns (Vault memory vault) {
		vault = snToVault[sn];
	}

	function deleteVault(uint sn) internal override {
		delete snToVault[sn];
	}

	function safeTransfer(address receiver, uint value) internal override {
		receiver.call{value: value, gas: 9000}("");
	}

}

contract XHedgeForSmartBCH is XHedgeBase {
	function saveVault(uint sn, Vault memory vault) internal override {
		bytes memory snBz = abi.encode(sn);
		(uint w0, uint w2, uint w3) = (0, 0, 0);
		w0 = uint(vault.lastVoteTime);
		w0 = (w0<<64) | uint(vault.matureTime);
		w0 = (w0<<64) | uint(vault.minCollateralRate);
		w0 = (w0<<64) | uint(vault.initCollateralRate);

		w2 = uint(uint160(bytes20(vault.oracle)));
		w2 = (w2<<96) | uint(vault.hedgeValue);

		w3 = uint(vault.amount);
		w3 = (w3<<64) | uint(vault.closeoutPenalty);
		bytes memory vaultBz = abi.encode(w0, vault.validatorToVote, w2, w3);
		(bool success, bytes memory _notUsed) = SEP101Contract.delegatecall(
			abi.encodeWithSignature("set(bytes,bytes)", snBz, vaultBz));
		require(success, "SEP101_SET_FAIL");
	}

	function loadVault(uint sn) public override returns (Vault memory vault) {
		bytes memory snBz = abi.encode(sn);
		(bool success, bytes memory data) = SEP101Contract.delegatecall(
			abi.encodeWithSignature("get(bytes)", snBz));

		require(success && (data.length == 32*2 || data.length == 32*6));
		if (data.length == 32*2) {
			vault.amount = 0;
			return vault;
		}

		// bytes memory vaultBz = abi.decode(data, (bytes));
		bytes memory vaultBz;
		assembly { vaultBz := add(data, 64) }

		(uint w0, uint w1, uint w2, uint w3) = abi.decode(vaultBz, (uint, uint, uint, uint));

		vault.initCollateralRate = uint64(w0);
		vault.minCollateralRate = uint64(w0>>64);
		vault.matureTime = uint64(w0>>128);
		vault.lastVoteTime = uint64(w0>>192);

		vault.validatorToVote = w1;

		vault.hedgeValue = uint96(w2);
		vault.oracle = address(bytes20(uint160(w2>>96)));

		vault.closeoutPenalty = uint64(w3);
		vault.amount = uint96(w3>>64);
	}

	function deleteVault(uint sn) internal override {
		bytes memory snBz = abi.encode(sn);
		bytes memory vaultBz = new bytes(0); //writing 32 bytes of zero is for deletion
		(bool success, bytes memory _notUsed) = SEP101Contract.delegatecall(
			abi.encodeWithSignature("set(bytes,bytes)", snBz, vaultBz));
		require(success, "SEP101_DEL_FAIL");
	}

	function safeTransfer(address receiver, uint value) internal override {
		// IERC20(SEP206Contract).transfer(receiver, value);
		(bool success, bytes memory _notUsed) = SEP206Contract.call(
			abi.encodeWithSignature("transfer(address,uint256)", receiver, value));
		require(success, "SEP206_TRANSFER_FAIL");
	}

}
