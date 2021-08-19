const XHedge = artifacts.require("XHedge");
const Oracle = artifacts.require("MockOracle");

contract("XHedge", async (accounts) => {

    const alice = accounts[0];
    const bob   = accounts[1];

    const _1e18              = 10n ** 18n;
    const initOraclePrice    = 600n * _1e18;
  
    // default createVault() args
    const initCollateralRate = _1e18 / 2n; // 0.5
    const minCollateralRate  = _1e18 / 5n; // 0.2
    const closeoutPenalty    = _1e18 / 10n;// 0.1
    const matureTime         = 30; // 30m
    const validatorToVote    = accounts[9];
    const hedgeValue         = 600n * _1e18;
    const amt                = (_1e18 + initCollateralRate) * hedgeValue / initOraclePrice;

    let gasPrice;
    let oracle;
    let xhedge;

    before(async () => {
        gasPrice = await web3.eth.getGasPrice();
    });

    beforeEach(async () => {
        oracle = await Oracle.new(initOraclePrice, { from: bob });
        xhedge = await XHedge.new({ from: bob });
    });

    it('createVault', async () => {
        const balance0 = await web3.eth.getBalance(alice);
        const result = await createVaultWithDefaultArgs();
        const balance1 = await web3.eth.getBalance(alice);

        const gasFee = getGasFee(result, gasPrice);
        assert.equal(BigInt(balance0) - BigInt(balance1), BigInt(gasFee) + amt);

        assert.equal(await xhedge.balanceOf(alice), 2);
        const tokenIds = getTokenIds(result);
        //console.log(tokenIds);
        assert.equal(await xhedge.ownerOf(tokenIds[0]), alice);
        assert.equal(await xhedge.ownerOf(tokenIds[1]), alice);
    });

    it('burn', async () => {
        const result1 = await createVaultWithDefaultArgs();
        const tokenIds = getTokenIds(result1);
        const sn = tokenIds[0] >> 1;
        console.log(tokenIds, sn);

        const balance0 = await web3.eth.getBalance(alice);
        const result2 = await xhedge.burn(sn, { from: alice });
        const balance1 = await web3.eth.getBalance(alice);

        const gasFee = getGasFee(result2, gasPrice);
        assert.equal(BigInt(balance1) - BigInt(balance0), amt - BigInt(gasFee));
        assert.equal(await xhedge.balanceOf(alice), 0);
    });

    it('closeout', async () => {
        // TODO
    });

    it('liquidate', async () => {
        // TODO
    });

    async function createVaultWithDefaultArgs() {
        return await xhedge.createVault(
            initCollateralRate.toString(),
            minCollateralRate.toString(),
            closeoutPenalty.toString(),
            matureTime,
            validatorToVote,
            hedgeValue.toString(),
            oracle.address,
            { from: alice, value: amt.toString() }
        );
    }

});

function getGasFee(result, gasPrice) {
    return result.receipt.gasUsed * gasPrice;
}

function getTokenIds(result) {
    const logs = result.logs.filter(log => log.event == 'Transfer');
    assert.lengthOf(logs, 2);
    return [
        logs[0].args.tokenId.toString(),
        logs[1].args.tokenId.toString(),
    ];
}
