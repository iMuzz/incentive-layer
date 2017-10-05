var TaskGiver = artifacts.require('./TaskGiver.sol');
var Web3 = require('web3');
var web3 = new Web3(new Web3.providers.HttpProvider("http://localhost:8545"));

contract('TaskGiver', function(accounts) {
  it("should assert true", function() {
  	var taskGiver;
    return TaskGiver.deployed().then(function(instance) {
    	taskGiver = instance;
    	return taskGiver.getBalance.call(accounts[0]);
    }).then(function(balance) {
    	assert.equal(0, balance.toNumber());
    	return taskGiver.submitDeposit(accounts[0], {value: 10000});
    }).then(function(result) {
    	return taskGiver.getBalance.call(accounts[0]);
    }).then(function(balance) {
    	assert.equal(10000, balance.toNumber());
    	return taskGiver.sendTask(5000, {from: accounts[0]});
    }).then(function(tx) {
    	return taskGiver.receiveBid(0, accounts[1]);//account[1] sends bid to task0
    }).then(function(tx) {
        return taskGiver.selectSolver(0);
    }).then(function(solver) {
        return taskGiver.isSelectedSolver.call(0, accounts[1]);
    }).then(function(result) {
        assert.isTrue(result);
        return taskGiver.receiveSolutionHash(accounts[4], 0, 0x0);
    }).then(function(result) {
        return taskGiver.completeTask(0, {from: accounts[0]});
    });
  });
});
