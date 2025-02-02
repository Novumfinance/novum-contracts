// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { IStrategy } from "./IStrategy.sol";
import { IEigenDelegationManager } from "./IEigenDelegationManager.sol";

interface INodeDelegator {
    // event
    event AssetDepositIntoStrategy(address indexed asset, address indexed strategy, uint256 depositAmount);
    event ETHDepositFromDepositPool(uint256 depositAmount);
    event EigenPodCreated(address indexed eigenPod, address indexed podOwner);
    event ETHStaked(bytes valPubKey, uint256 amount);
    event WithdrawalQueued(uint256 nonce, address withdrawer, bytes32 withdrawalRoot);
    event EthTransferred(address to, uint256 amount);
    event EigenLayerWithdrawalCompleted(address indexed depositor, uint256 nonce, address indexed caller);
    event ElSharesDelegated(address indexed elOperator);

    // errors
    error TokenTransferFailed();
    error StrategyIsNotSetForAsset();
    error InvalidETHSender();
    error InvalidDepositRoot(bytes32 expectedDepositRoot, bytes32 actualDepositRoot);
    error StrategyMustNotBeBeaconChain();

    // getter
    function stakedButUnverifiedNativeETH() external view returns (uint256);

    // write functions
    function depositAssetIntoStrategy(address asset) external;
    function maxApproveToEigenStrategyManager(address asset) external;
    function initiateUnstaking(IEigenDelegationManager.QueuedWithdrawalParams calldata queuedWithdrawalParam)
        external
        returns (bytes32 withdrawalRoot);

    // view functions
    function getAssetBalances() external view returns (address[] memory, uint256[] memory);

    function getAssetBalance(address asset) external view returns (uint256);

    function getETHEigenPodBalance() external view returns (uint256);

    function transferBackToLRTDepositPool(address asset, uint256 amount) external;

    function sendETHFromDepositPoolToNDC() external payable;
}
