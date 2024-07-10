// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.21;

import "forge-std/Script.sol";
import { AddAssetsLib } from "../libraries/AddAssetsLib.sol";

contract AddAsset is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.rememberKey(deployerPrivateKey);
        vm.startBroadcast(deployer);
        AddAssetsLib.addCbETH();
        AddAssetsLib.addRETH();
        vm.stopBroadcast();
    }
}
