// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { CrossChainRateReceiver } from "./CrossChainRateReceiver.sol";

/// @title novETH cross chain rate receiver
/// @notice Receives the novETH rate from a provider contract on a different chain than the one this contract is
/// deployed
/// on
contract NovETHRateReceiver is CrossChainRateReceiver {
    constructor(uint16 _srcChainId, address _rateProvider, address _layerZeroEndpoint) {
        rateInfo = RateInfo({ tokenSymbol: "novETH", baseTokenSymbol: "ETH" });
        srcChainId = _srcChainId;
        rateProvider = _rateProvider;
        layerZeroEndpoint = _layerZeroEndpoint;
    }
}
