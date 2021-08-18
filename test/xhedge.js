const XHedge = artifacts.require("XHedge");
const Oracle = artifacts.require("MockOracle");

contract("XHedge", async (accounts) => {

    let oracle;
    let xhedge;

    before(async () => {
        oracle = await Oracle.new(600);
        xhedge = await XHedge.new();
    });

    it('createVault', async () => {
        console.log('TODO~');
    });

});
