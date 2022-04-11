module.exports = async function(callback) {
    main()
        .then(callback)
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}

async function main() {
    const futureHeight = 4106000;
    const currHeight = await web3.eth.getBlockNumber();
    const oldHeight = currHeight - (futureHeight - currHeight);
    console.log('futureHeight:', futureHeight);
    console.log('currHeight  :', currHeight);
    console.log('oldHeight   :', oldHeight);

    const currBlock = await web3.eth.getBlock(currHeight);
    const oldBlock = await web3.eth.getBlock(oldHeight);

    const avgBlockTime = (currBlock.timestamp - oldBlock.timestamp) / (currHeight - oldHeight);
    console.log('avgBlockTime:', avgBlockTime);

    const futureTime = currBlock.timestamp + avgBlockTime * (futureHeight - currHeight);
    console.log('futureTime:', new Date(futureTime * 1000));
}
