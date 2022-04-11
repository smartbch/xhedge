module.exports = async function(callback) {
    main()
        .then(callback)
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}

async function main() {
    const fetureHeight = 4106000;
    const currHeight = await web3.eth.getBlockNumber();
    const oldHeight = currHeight - (fetureHeight - currHeight);
    console.log('fetureHeight:', fetureHeight);
    console.log('currHeight  :', currHeight);
    console.log('oldHeight   :', oldHeight);

    const currBlock = await web3.eth.getBlock(currHeight);
    const oldBlock = await web3.eth.getBlock(oldHeight);

    const blockTime = (currBlock.timestamp - oldBlock.timestamp) / (currHeight - oldHeight);
    console.log('blockTime:', blockTime);

    const futureTime = currBlock.timestamp + blockTime * (fetureHeight - currHeight);
    console.log('futureTime:', new Date(futureTime * 1000));
}
