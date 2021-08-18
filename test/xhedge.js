const XHedge = artifacts.require("XHedge");
const Oracle = artifacts.require("MockOracle");

contract("XHedge", async (accounts) => {

    const _1e18              = 10n ** 18n;
    const initOraclePrice    = 600n * _1e18;
    const initCollateralRate = _1e18 / 2n; // 0.5
    const minCollateralRate  = _1e18 / 5n; // 0.2
    const closeoutPenalty    = _1e18 / 10n;// 0.1
    const defaultMatureTime  = 30; // 30m
    const validatorToVote    = accounts[9];

    let oracle;
    let xhedge;

    before(async () => {
        oracle = await Oracle.new(initOraclePrice);
        xhedge = await XHedge.new();
    });

    it('createVault', async () => {
        const hedgeValue = 600n * _1e18;
        const amt = (_1e18 + initCollateralRate) * hedgeValue / initOraclePrice;
        const matureTime = 30; // 30m

        const result = await xhedge.createVault(
            initCollateralRate.toString(),
            minCollateralRate.toString(),
            closeoutPenalty.toString(),
            defaultMatureTime,
            validatorToVote,
            hedgeValue.toString(),
            oracle.address,
            { from: accounts[0], value: amt.toString() }
        );

        let tokenIds = getTokenIds(result);
        console.log(tokenIds);
        assert.equal(await xhedge.balanceOf(accounts[0]), 2);
    });

});


function getTokenIds(result) {
    const logs = result.logs.filter(log => log.event == 'Transfer');
    assert.lengthOf(logs, 2);
    return [
        logs[0].args.tokenId.toString(),
        logs[1].args.tokenId.toString(),
    ];
}
