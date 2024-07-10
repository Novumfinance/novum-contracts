// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.21;

import "forge-std/Script.sol";
import { AddAssetsLib } from "../libraries/AddAssetsLib.sol";
import { WithdrawalManagerLib } from "../libraries/WithdrawalManagerLib.sol";

contract UpdateWManager is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.rememberKey(deployerPrivateKey);
        vm.startBroadcast(deployer);
        WithdrawalManagerLib.deployImpl();
        vm.stopBroadcast();
    }
}
