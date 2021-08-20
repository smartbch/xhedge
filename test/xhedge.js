const XHedge = artifacts.require("XHedge");
const Oracle = artifacts.require("MockOracle");

contract("XHedge", async (accounts) => {

    // accounts
    const oven  = accounts[0];
    const alice = accounts[1];
    const lula  = accounts[2];
    const hari  = accounts[3];

    const _1e18              = 10n ** 18n;
    const initOraclePrice    = 600n * _1e18;
  
    // default createVault() args
    const initCollateralRate = _1e18 / 2n; // 0.5
    const minCollateralRate  = _1e18 / 5n; // 0.2
    const closeoutPenalty    = _1e18 / 100n; // 0.01
    const matureTime         = Math.floor(Date.now() / 1000 / 60) + 30; // 30m
    const validatorToVote    = 1;
    const hedgeValue         = 600n * _1e18;
    const amt                = (_1e18 + initCollateralRate) * hedgeValue / initOraclePrice; // 1.5e18

    let gasPrice;
    let oracle;
    let xhedge;

    before(async () => {
        gasPrice = await web3.eth.getGasPrice();
    });

    beforeEach(async () => {
        oracle = await Oracle.new(initOraclePrice, { from: oven });
        xhedge = await XHedge.new({ from: oven });
        hedger = (await web3.eth.accounts.create()).address;
        speculator = (await web3.eth.accounts.create()).address;
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
        const result0 = await createVaultWithDefaultArgs();
        const tokenIds = getTokenIds(result0);
        const sn = tokenIds[0] >> 1;
        // console.log(tokenIds, sn);

        const balance0 = await web3.eth.getBalance(alice);
        const result1 = await xhedge.burn(sn, { from: alice });
        const balance1 = await web3.eth.getBalance(alice);

        const gasFee = getGasFee(result1, gasPrice);
        assert.equal(BigInt(balance1) - BigInt(balance0), amt - BigInt(gasFee));
        assert.equal(await xhedge.balanceOf(alice), 0);
    });

    it('closeout', async () => {
        const result0 = await createVaultWithDefaultArgs();
        const [leverId, hedgeId] = getTokenIds(result0);
        const sn = leverId >> 1;
        // console.log(leverId, hedgeId, sn);

        await xhedge.transferFrom(alice, lula, leverId, { from: alice });
        await oracle.setPrice(450n * _1e18, { from: oven });

        const balanceOfAlice0 = await web3.eth.getBalance(alice);
        const balanceOfLula0 = await web3.eth.getBalance(lula);
        const result = await xhedge.closeout(hedgeId, { from: alice });
        const gasFee = getGasFee(result, gasPrice);
        const balanceOfAlice1 = await web3.eth.getBalance(alice);
        const balanceOfLula1 = await web3.eth.getBalance(lula);

        // console.log(BigInt(balanceOfAlice1) - BigInt(balanceOfAlice0) + BigInt(gasFee));
        // console.log(BigInt(balanceOfLula1) - BigInt(balanceOfLula0));
        const amtToHedger = hedgeValue / 450n * (_1e18 + closeoutPenalty) / _1e18;
        assert.equal(BigInt(balanceOfAlice1) - BigInt(balanceOfAlice0) + BigInt(gasFee), amtToHedger);
        assert.equal(BigInt(balanceOfLula1) - BigInt(balanceOfLula0), amt - amtToHedger);
        assert.equal(await xhedge.balanceOf(alice), 0);
    });

    it('liquidate_priceFall_byHedgeOwner', async () => {
        const result0 = await createVaultWithDefaultArgs({matureTime: 1});
        const [leverId, hedgeId] = getTokenIds(result0);
        const sn = leverId >> 1;
        // console.log(leverId, hedgeId, sn);

        await xhedge.transferFrom(alice, lula, leverId, { from: alice });
        await oracle.setPrice(500n * _1e18, { from: oven });

        const balanceOfAlice0 = await web3.eth.getBalance(alice);
        const balanceOfLula0 = await web3.eth.getBalance(lula);
        const result = await xhedge.liquidate(hedgeId, { from: alice });
        const gasFee = getGasFee(result, gasPrice);
        const balanceOfAlice1 = await web3.eth.getBalance(alice);
        const balanceOfLula1 = await web3.eth.getBalance(lula);

        // console.log(BigInt(balanceOfAlice1) - BigInt(balanceOfAlice0) + BigInt(gasFee)); // 1.2e18
        // console.log(BigInt(balanceOfLula1) - BigInt(balanceOfLula0));                    // 0.3e18
        const amtToHedger = hedgeValue / 500n;
        assert.equal(BigInt(balanceOfAlice1) - BigInt(balanceOfAlice0) + BigInt(gasFee), amtToHedger);
        assert.equal(BigInt(balanceOfLula1) - BigInt(balanceOfLula0), amt - amtToHedger);
        assert.equal(await xhedge.balanceOf(alice), 0);
    });

    it('liquidate_priceRise_byLeverOwner', async () => {
        const result0 = await createVaultWithDefaultArgs({matureTime: 1});
        const [leverId, hedgeId] = getTokenIds(result0);
        const sn = leverId >> 1;
        // console.log(leverId, hedgeId, sn);

        await xhedge.transferFrom(alice, lula, leverId, { from: alice });
        await oracle.setPrice(800n * _1e18, { from: oven });

        const balanceOfAlice0 = await web3.eth.getBalance(alice);
        const balanceOfLula0 = await web3.eth.getBalance(lula);
        const result = await xhedge.liquidate(leverId, { from: lula });
        const gasFee = getGasFee(result, gasPrice);
        const balanceOfAlice1 = await web3.eth.getBalance(alice);
        const balanceOfLula1 = await web3.eth.getBalance(lula);

        // console.log(BigInt(balanceOfAlice1) - BigInt(balanceOfAlice0));                // 0.75e18
        // console.log(BigInt(balanceOfLula1) - BigInt(balanceOfLula0) + BigInt(gasFee)); // 0.75e18
        const amtToHedger = hedgeValue / 800n;
        assert.equal(BigInt(balanceOfAlice1) - BigInt(balanceOfAlice0), amtToHedger);
        assert.equal(BigInt(balanceOfLula1) - BigInt(balanceOfLula0) + BigInt(gasFee), amt - amtToHedger);
        assert.equal(await xhedge.balanceOf(alice), 0);
    });

    it('changeAmt_increase', async () => {
        const result0 = await createVaultWithDefaultArgs({matureTime: 1});
        const [leverId, hedgeId] = getTokenIds(result0);
        const sn = leverId >> 1;
        // console.log(leverId, hedgeId, sn);

        await xhedge.transferFrom(alice, lula, leverId, { from: alice });

        const addedAmt = _1e18 / 10n;  // 0.1e18
        const newAmt = amt + addedAmt; // 1.6e18
        const balanceOfAlice0 = await web3.eth.getBalance(alice);
        const result = await xhedge.changeAmount(sn, newAmt, { from: alice, value: addedAmt.toString() });
        const balanceOfAlice1 = await web3.eth.getBalance(alice);
        const gasFee = getGasFee(result, gasPrice);
        assert.equal(BigInt(balanceOfAlice0) - BigInt(balanceOfAlice1) - BigInt(gasFee), addedAmt);
    });

    it('changeAmt_decrease', async () => {
        const result0 = await createVaultWithDefaultArgs({matureTime: 1});
        const [leverId, hedgeId] = getTokenIds(result0);
        const sn = leverId >> 1;
        // console.log(leverId, hedgeId, sn);

        await xhedge.transferFrom(alice, lula, leverId, { from: alice });
        await oracle.setPrice(900n * _1e18, { from: oven });

        const cutAmt = _1e18 / 10n;  // 0.1e18
        const newAmt = amt - cutAmt; // 1.4e18
        const balanceOfLula0 = await web3.eth.getBalance(lula);
        const result = await xhedge.changeAmount(sn, newAmt, { from: lula });
        const balanceOfLula1 = await web3.eth.getBalance(lula);
        const gasFee = getGasFee(result, gasPrice);
        assert.equal(BigInt(balanceOfLula1) - BigInt(balanceOfLula0) + BigInt(gasFee), 
            cutAmt * 995n / 1000n);
    });

    it('changeValidatorToVote', async () => {
        // TODO
    });

    it('vote', async () => {
        // TODO
    });

    async function createVaultWithDefaultArgs(args) {
        let _matureTime = args && args.matureTime || matureTime;

        return await xhedge.createVault(
            initCollateralRate.toString(),
            minCollateralRate.toString(),
            closeoutPenalty.toString(),
            _matureTime,
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
        logs[0].args.tokenId.toString(), // LeverNFT
        logs[1].args.tokenId.toString(), // HedgeNFT
    ];
}
