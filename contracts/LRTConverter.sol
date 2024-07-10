// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { LRTConstants } from "./utils/LRTConstants.sol";

import { LRTConfigRoleChecker, ILRTConfig, IAccessControl } from "./utils/LRTConfigRoleChecker.sol";
import { UtilLib } from "./utils/UtilLib.sol";

import { ILRTDepositPool } from "./interfaces/ILRTDepositPool.sol";
import { IStrategy } from "./interfaces/IStrategy.sol";
import { ILRTOracle } from "./interfaces/ILRTOracle.sol";
import { INovETH } from "./interfaces/INovETH.sol";
import { IEigenDelegationManager } from "./interfaces/IEigenDelegationManager.sol";
import { ILRTConverter } from "./interfaces/ILRTConverter.sol";

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { UnstakeStETH } from "./unstaking-adapters/UnstakeStETH.sol";
import { UnstakeSwETH } from "./unstaking-adapters/UnstakeSwETH.sol";

/// @title LRTConverter - Converts eigenlayer deployed LSTs to novETH
/// @notice Handles eigenlayer deposited LSTs to novETH conversion
contract LRTConverter is
    ILRTConverter,
    LRTConfigRoleChecker,
    ReentrancyGuardUpgradeable,
    UnstakeSwETH,
    UnstakeStETH,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    mapping(bytes32 => bool) public processedWithdrawalRoots;
    mapping(address => bool) public convertableAssets;
    mapping(address => uint256) public conversionLimit;

    //needs to be added to total assets in protocol
    uint256 public ethValueInWithdrawal;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the contract
    /// @param lrtConfigAddr LRT config address
    function initialize(address lrtConfigAddr) external initializer {
        UtilLib.checkNonZeroAddress(lrtConfigAddr);
        __ReentrancyGuard_init();
        lrtConfig = ILRTConfig(lrtConfigAddr);
        emit UpdatedLRTConfig(lrtConfigAddr);
    }

    /// @dev Initializes the contract
    /// @param _withdrawalQueueAddress Address of withdrawal queue (stETH)
    /// @param _stETHAddress Address of stETH
    /// @param _swEXITAddress Address of swEXIT (swETH)
    /// @param _swETHAddress Address of swETH
    function initialize2(
        address _withdrawalQueueAddress,
        address _stETHAddress,
        address _swEXITAddress,
        address _swETHAddress
    )
        external
        reinitializer(2)
        onlyLRTAdmin
    {
        __ReentrancyGuard_init();
        __initializeSwETH(_swEXITAddress, _swETHAddress);
        __initializeStETH(_withdrawalQueueAddress, _stETHAddress);
    }

    modifier onlyConvertableAsset(address asset) {
        require(convertableAssets[asset], "Asset not supported");
        _;
    }

    /// @notice Add convertable asset
    /// @param asset Asset address
    function addConvertableAsset(address asset) external onlyLRTManager {
        convertableAssets[asset] = true;
    }

    /// @notice Remove convertable asset
    /// @param asset Asset address
    function removeConvertableAsset(address asset) external onlyLRTManager {
        convertableAssets[asset] = false;
    }

    /// @notice Set conversion limit for asset
    /// @param asset Asset address
    /// @param limit Conversion limit
    function setConversionLimit(address asset, uint256 limit) external onlyLRTManager {
        conversionLimit[asset] = limit;
    }

    /// @notice View amount of novETH to mint for given asset amount
    /// @param asset Asset address
    /// @param amount Asset amount
    /// @return novethAmountToMint Amount of noveth to mint
    function getNovETHAmountToMint(address asset, uint256 amount) public view returns (uint256 novethAmountToMint) {
        ILRTDepositPool lrtDepositPool = ILRTDepositPool(lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL));
        novethAmountToMint = lrtDepositPool.getNovETHAmountToMint(asset, amount);
    }

    /// @notice swap ETH for LST asset which is accepted by LRTConverter and send to LRTDepositPool
    /// @dev use LRTOracle to get price for asset. Only callable by LRT manager
    /// @param asset Asset address to swap to
    /// @param minimumExpectedReturnAmount Minimum asset amount to swap to
    function swapEthToAsset(
        address asset,
        uint256 minimumExpectedReturnAmount
    )
        external
        payable
        onlyLRTOperator
        onlyConvertableAsset(asset)
        returns (uint256 returnAmount)
    {
        ILRTDepositPool lrtDepositPool = ILRTDepositPool(lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL));
        uint256 ethAmountSent = msg.value;

        returnAmount = lrtDepositPool.getSwapETHToAssetReturnAmount(asset, ethAmountSent);

        if (returnAmount < minimumExpectedReturnAmount || IERC20(asset).balanceOf(address(this)) < returnAmount) {
            revert NotEnoughAssetToTransfer();
        }
        // account for limits and the asset value in contract
        conversionLimit[asset] += returnAmount;
        sendEthToDepositPool(ethAmountSent);

        IERC20(asset).safeTransfer(msg.sender, returnAmount);
        emit ETHSwappedForLST(ethAmountSent, asset, returnAmount);
    }

    function unstakeStEth(uint256 amountToUnstake) external onlyLRTOperator {
        _unstakeStEth(amountToUnstake);
    }

    function claimStEth(uint256 _requestId, uint256 _hint) external onlyLRTOperator {
        _claimStEth(_requestId, _hint);
        sendEthToDepositPool(address(this).balance);
    }

    function unstakeSwEth(uint256 amountToUnstake) external onlyLRTOperator {
        _unstakeSwEth(amountToUnstake);
    }

    function claimSwEth(uint256 _tokenId) external onlyLRTOperator {
        _claimSwEth(_tokenId);
        sendEthToDepositPool(address(this).balance);
    }

    /// @notice send asset from deposit pool to LRTConverter
    /// @dev Only callable by LRT manager and asset need to be approved
    /// @param _asset Asset address to send
    /// @param _amount Asset amount to send
    function transferAssetFromDepositPool(
        address _asset,
        uint256 _amount
    )
        public
        onlyConvertableAsset(_asset)
        onlyLRTManager
    {
        address lrtDepositPoolAddress = lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL);
        address lrtOracleAddress = lrtConfig.getContract(LRTConstants.LRT_ORACLE);
        ILRTOracle lrtOracle = ILRTOracle(lrtOracleAddress);

        ethValueInWithdrawal += (_amount * lrtOracle.getAssetPrice(_asset)) / 1e18;

        IERC20(_asset).safeTransferFrom(lrtDepositPoolAddress, address(this), _amount);
    }

    function sendEthToDepositPool(uint256 _amount) internal {
        address lrtDepositPoolAddress = lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL);

        if (ethValueInWithdrawal > _amount) {
            ethValueInWithdrawal -= _amount;
        } else {
            ethValueInWithdrawal = 0;
        }
        // Send eth to deposit pool
        (bool success,) = payable(lrtDepositPoolAddress).call{ value: _amount }("");
        if (!success) revert TokenTransferFailed();
        emit EthTransferred(lrtDepositPoolAddress, _amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev fallback to receive funds
    receive() external payable { }
}
