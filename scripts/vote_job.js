const { CronJob } = require("cron");
const XHedge = artifacts.require("XHedgeForSmartBCH");

// TODO: read these from config file
const xhAddr = '0x943F4002b68365fCC8F62eC65c3003aEcd391c0e'; // amber testnet
const xhSNs = [ 804, 1060, 1316, 1572 ];

async function main() {
    const accounts = await web3.eth.getAccounts();
    console.log('acc0:', accounts[0]);

    const xh = await XHedge.at(xhAddr);
    // await voteVaults(xh);

    const job = new CronJob(
        // '0 */10 * * * *', // every 10 mins
        '00 00 00 * * *', // at midnight
        async () => await voteVaults(xh), 
        null, // onComplete
        true, // start?
    );

    // wait forever
    await new Promise((resolve, reject) => {});
}

async function voteVaults(xh) {
    console.log(new Date());
    for (const sn of xhSNs) {
        try {
            console.log('query vault, sn=', sn);
            const vault = await xh.loadVault.call(sn);
            console.log(vault);
            console.log('validatorToVote:', BigInt(vault.validatorToVote).toString(16));
            
            console.log('vote...');
            const tx = await xh.vote(sn);
            console.log('tx:', tx);
        } catch (err) {
            console.log('failed to vote!',err);
        }
    }
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = async function(callback) {
    main()
        .then(callback)
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}
