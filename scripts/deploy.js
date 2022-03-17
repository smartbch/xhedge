const XHedge = artifacts.require("XHedgeForSmartBCH");

async function main() {
    const accounts = await web3.eth.getAccounts();
    console.log('acc0:', accounts[0]);

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
