// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.21;

import "forge-std/console.sol";

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LRTConfig } from "contracts/LRTConfig.sol";
import { LRTConverter } from "contracts/LRTConverter.sol";
import { Addresses, AddressesHolesky } from "../utils/Addresses.sol";
import { LRTConstants } from "contracts/utils/LRTConstants.sol";

library ConverterLib {
    function deployImpl() internal returns (address implementation) {
        // Deploy the new contract
        implementation = address(new LRTConverter());
        console.log("LRTConverter implementation deployed at: %s", implementation);
    }

    function initialize(LRTConverter converter, LRTConfig config) internal {
        converter.initialize(address(config));
    }
}
