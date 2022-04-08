const XHedge = artifacts.require("XHedgeForSmartBCH");
const Oracle = artifacts.require("MockOracle");

async function main() {
    const accounts = await web3.eth.getAccounts();
    const bal = await web3.eth.getBalance(accounts[0]);
    console.log('acc0:', accounts[0], 'bal:', web3.utils.fromWei(bal, 'ether'));

    // const oracle = await Oracle.new(web3.utils.toWei('400', 'ether'));
    // console.log('MockOracle deployed at:', oracle.address);

    const xh = await XHedge.new();
    console.log('XHedge deployed at:', xh.address);
}

module.exports = async function(callback) {
    main()
        .then(callback)
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}
