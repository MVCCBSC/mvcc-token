const contract = artifacts.require("MVCR");

module.exports = function(deployer, network, accounts) {

  const name = "MVCR TOKEN";
  const symbol = "MVCR";

  deployer.deploy(contract, name, symbol);
};
