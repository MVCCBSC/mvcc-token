const contract = artifacts.require("MVCC");

module.exports = function(deployer, network, accounts) {

  const referralFeeReceiver = "";
  const superNodeFeeReceiver = "";

  deployer.deploy(contract, referralFeeReceiver, superNodeFeeReceiver);
};
