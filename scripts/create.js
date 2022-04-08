const XHedge = artifacts.require("XHedgeForSmartBCH");

const xhAddr = '0x2A859925889D09E84731887469830a6a0d1c3d96';
const oracle = '0x93107C1E1aC0D212c56Dbc4Ae3A33c07F5D2fC7F';
const validatorToVote = '0x8df07574b4d9b436650ccb091181297ca66fe2625f984321681ff8ef9ae650ac';

async function main() {
    const accounts = await web3.eth.getAccounts();
    const bal = await web3.eth.getBalance(accounts[0]);
    console.log('acc0:', accounts[0], 'bal:', web3.utils.fromWei(bal, 'ether'));

    const xh = await XHedge.at(xhAddr);
    console.log('XHedge addr:', xh.address);

    const _1e18              = 10n ** 18n;
    const initOraclePrice    = 400n * _1e18;
    const initCollateralRatio= _1e18 / 2n; // 0.5
    const minCollateralRatio = _1e18 / 5n; // 0.2
    const closeoutPenalty    = _1e18 / 100n; // 0.01
    const matureTime         = Math.floor(Date.now() / 1000) + 30 * 60; // 30m
    const hedgeValue         = 100n * 10n ** 18n; // 100
    const amt                = (_1e18 + initCollateralRatio) * hedgeValue / initOraclePrice; // 0.375
    // console.log(web3.utils.fromWei(amt.toString(), 'ether'));

    const tx = await xh.createVault(
        initCollateralRatio.toString(),
        minCollateralRatio.toString(),
        closeoutPenalty.toString(),
        matureTime,
        validatorToVote,
        hedgeValue.toString(),
        oracle,
        {value: amt.toString()}
    );
    console.log(tx);
    console.log(getTokenIds(tx));
}

function getTokenIds(result) {
    const logs = result.logs.filter(log => log.event == 'Transfer');
    // assert.lengthOf(logs, 2);
    return [
        logs[0].args.tokenId.toString(), // LeverNFT
        logs[1].args.tokenId.toString(), // HedgeNFT
        logs[0].args.tokenId >> 1,       // sn
    ];
}

module.exports = async function(callback) {
    main()
        .then(callback)
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}
