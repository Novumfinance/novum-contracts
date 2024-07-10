// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.21;

import "forge-std/console.sol";

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LRTConfig } from "contracts/LRTConfig.sol";
import { LRTWithdrawalManager } from "contracts/LRTWithdrawalManager.sol";
import { Addresses, AddressesHolesky } from "../utils/Addresses.sol";
import { LRTConstants } from "contracts/utils/LRTConstants.sol";

library WithdrawalManagerLib {
    function deployImpl() internal returns (address implementation) {
        // Deploy the new contract
        implementation = address(new LRTWithdrawalManager());
        console.log("LRTWithdrawalManager implementation deployed at: %s", implementation);
    }

    function initialize(LRTWithdrawalManager withdrawal_manager, LRTConfig config) internal {
        withdrawal_manager.initialize(address(config));
    }

    // function upgrade(address newImpl) internal returns (LRTDepositPool) {
    //     address proxyAdminAddress = block.chainid == 1 ? Addresses.PROXY_ADMIN : AddressesHolesky.PROXY_ADMIN;
    //     address proxyAddress = block.chainid == 1 ? Addresses.LRT_DEPOSIT_POOL : AddressesHolesky.LRT_DEPOSIT_POOL;

    //     ProxyAdmin proxyAdmin = ProxyAdmin(proxyAdminAddress);
    //     console.log("Proxy admin owner %s", proxyAdmin.owner());

    //     proxyAdmin.upgrade(ITransparentUpgradeableProxy(proxyAddress), newImpl);
    //     console.log("Upgraded LRTDepositPool proxy %s to new implementation %s", proxyAddress, newImpl);

    //     return LRTDepositPool(proxyAddress);
    // }

    // function addNodeDelegator(address nodeDelegatorProxy) internal {
    //     address depositPoolAddress = block.chainid == 1 ? Addresses.LRT_DEPOSIT_POOL :
    // AddressesHolesky.LRT_DEPOSIT_POOL;
    //     LRTDepositPool depositPool = LRTDepositPool(depositPoolAddress);

    //     address[] memory nodeDelegatorContracts = new address[](1);
    //     nodeDelegatorContracts[0] = nodeDelegatorProxy;
    //     depositPool.addNodeDelegatorContractToQueue(nodeDelegatorContracts);
    // }
}
