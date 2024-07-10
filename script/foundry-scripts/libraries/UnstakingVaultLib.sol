// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.21;

import "forge-std/console.sol";

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LRTConfig } from "contracts/LRTConfig.sol";
import { LRTUnstakingVault } from "contracts/LRTUnstakingVault.sol";
import { Addresses, AddressesHolesky } from "../utils/Addresses.sol";
import { LRTConstants } from "contracts/utils/LRTConstants.sol";

library UnstakingVaultLib {
    function deployImpl() internal returns (address implementation) {
        // Deploy the new contract
        implementation = address(new LRTUnstakingVault());
        console.log("LRTUnstakingVault implementation deployed at: %s", implementation);
    }

    function initialize(LRTUnstakingVault unstakingVault, LRTConfig config) internal {
        unstakingVault.initialize(address(config));
    }
}
