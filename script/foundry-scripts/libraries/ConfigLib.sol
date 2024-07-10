// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.21;

import "forge-std/console.sol";

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LRTConfig } from "contracts/LRTConfig.sol";
import { Addresses, AddressesHolesky } from "../utils/Addresses.sol";
import { LRTConstants } from "contracts/utils/LRTConstants.sol";

library ConfigLib {
    function deployImpl() internal returns (address implementation) {
        // Deploy new implementation contract
        implementation = address(new LRTConfig());
        console.log("LRTConfig implementation deployed at: %s", implementation);
    }

    function initialize(LRTConfig config, address adminAddress, address novETHAddress) internal {
        // initialize new LRTConfig contract
        address stETH = block.chainid == 1 ? Addresses.STETH_TOKEN : AddressesHolesky.STETH_TOKEN;
        address ethx = block.chainid == 1 ? Addresses.ETHX_TOKEN : AddressesHolesky.ETHX_TOKEN;

        config.initialize(adminAddress, stETH, ethx, novETHAddress);
    }

    function upgrade(address proxyAddress, address newImpl) internal returns (LRTConfig) {
        address proxyAdminAddress = block.chainid == 1 ? Addresses.PROXY_ADMIN : AddressesHolesky.PROXY_ADMIN;

        ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);

        proxyAdmin.upgrade(ITransparentUpgradeableProxy(proxyAddress), newImpl);
        console.log("Upgraded LRTConfig proxy %s to new implementation %s", proxyAddress, newImpl);

        return LRTConfig(payable(proxyAddress));
    }
}
