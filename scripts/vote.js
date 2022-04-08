const XHedge = artifacts.require("XHedgeForSmartBCH");

const xhAddr = '0x2A859925889D09E84731887469830a6a0d1c3d96';

async function main() {
    const accounts = await web3.eth.getAccounts();
    const bal = await web3.eth.getBalance(accounts[0]);
    console.log('acc0:', accounts[0], 'bal:', web3.utils.fromWei(bal, 'ether'));

    const xh = await XHedge.at(xhAddr);
    console.log('XHedge addr:', xh.address);

    const tx = await xh.vote(sn);
}

module.exports = async function(callback) {
    main()
        .then(callback)
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}
