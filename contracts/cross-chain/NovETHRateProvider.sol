// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { CrossChainRateProvider } from "./CrossChainRateProvider.sol";

import { ILRTOracle } from "../interfaces/ILRTOracle.sol";

/// @title novETH cross chain rate provider
/// @notice Provides the current exchange rate of novETH to a receiver contract on a different chain than the one this
/// contract is deployed on
contract NovETHRateProvider is CrossChainRateProvider {
    address public novETHPriceOracle;

    constructor(address _novETHPriceOracle, uint16 _dstChainId, address _layerZeroEndpoint) {
        novETHPriceOracle = _novETHPriceOracle;

        rateInfo = RateInfo({
            tokenSymbol: "novETH",
            tokenAddress: 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7, // novETH token address on ETH mainnet
            baseTokenSymbol: "ETH",
            baseTokenAddress: address(0) // Address 0 for native tokens
         });
        dstChainId = _dstChainId;
        layerZeroEndpoint = _layerZeroEndpoint;
    }

    /// @notice Returns the latest rate from the novETH contract
    function getLatestRate() public view override returns (uint256) {
        return ILRTOracle(novETHPriceOracle).novETHPrice();
    }
}
