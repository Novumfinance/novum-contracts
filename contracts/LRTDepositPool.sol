// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { UtilLib } from "./utils/UtilLib.sol";
import { LRTConstants } from "./utils/LRTConstants.sol";

import { LRTConfigRoleChecker, ILRTConfig } from "./utils/LRTConfigRoleChecker.sol";
import { INovETH } from "./interfaces/INovETH.sol";
import { ILRTOracle } from "./interfaces/ILRTOracle.sol";
import { INodeDelegator } from "./interfaces/INodeDelegator.sol";
import { ILRTDepositPool } from "./interfaces/ILRTDepositPool.sol";
import { ILRTUnstakingVault } from "./interfaces/ILRTUnstakingVault.sol";
import { ILRTWithdrawalManager } from "./interfaces/ILRTWithdrawalManager.sol";
import { ILRTConverter } from "./interfaces/ILRTConverter.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LRTDepositPool - Deposit Pool Contract for LSTs
/// @notice Handles LST asset deposits
contract LRTDepositPool is ILRTDepositPool, LRTConfigRoleChecker, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public maxNodeDelegatorLimit;
    uint256 public minAmountToDeposit;

    mapping(address => uint256) public isNodeDelegator; // 0: not a node delegator, 1: is a node delegator
    address[] public nodeDelegatorQueue;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the contract
    /// @param lrtConfigAddr LRT config address
    function initialize(address lrtConfigAddr) external initializer {
        UtilLib.checkNonZeroAddress(lrtConfigAddr);
        __Pausable_init();
        __ReentrancyGuard_init();
        maxNodeDelegatorLimit = 10;
        lrtConfig = ILRTConfig(lrtConfigAddr);
        emit UpdatedLRTConfig(lrtConfigAddr);
    }

    /*//////////////////////////////////////////////////////////////
                            view functions
    //////////////////////////////////////////////////////////////*/

    /// @notice gets the total asset present in protocol
    /// @param asset Asset address
    /// @return totalAssetDeposit total asset present in protocol
    function getTotalAssetDeposits(address asset) public view override returns (uint256 totalAssetDeposit) {
        (
            uint256 assetLyingInDepositPool,
            uint256 assetLyingInNDCs,
            uint256 assetStakedInEigenLayer,
            uint256 assetUnstakingFromEigenLayer,
            uint256 assetLyingInConverter,
            uint256 assetLyingUnstakingVault
        ) = getAssetDistributionData(asset);
        return (
            assetLyingInDepositPool + assetLyingInNDCs + assetStakedInEigenLayer + assetUnstakingFromEigenLayer
                + assetLyingInConverter + assetLyingUnstakingVault
        );
    }

    /// @notice gets the current limit of asset deposit
    /// @param asset Asset address
    /// @return currentLimit Current limit of asset deposit
    function getAssetCurrentLimit(address asset) public view override returns (uint256) {
        uint256 totalAssetDeposits = getTotalAssetDeposits(asset);
        if (totalAssetDeposits > lrtConfig.depositLimitByAsset(asset)) {
            return 0;
        }

        return lrtConfig.depositLimitByAsset(asset) - totalAssetDeposits;
    }

    /// @notice checks if deposit amount exceeds current limit
    /// @param asset Asset address
    /// @param amount Asset amount
    /// @return bool true if deposit amount exceeds current limit
    function checkIfDepositAmountExceedesCurrentLimit(address asset, uint256 amount) internal view returns (bool) {
        uint256 totalAssetDeposits = getTotalAssetDeposits(asset);
        if (asset == LRTConstants.ETH_TOKEN) {
            return (totalAssetDeposits > lrtConfig.depositLimitByAsset(asset));
        }
        return (totalAssetDeposits + amount > lrtConfig.depositLimitByAsset(asset));
    }

    /// @dev get node delegator queue
    /// @return nodeDelegatorQueue Array of node delegator contract addresses
    function getNodeDelegatorQueue() external view override returns (address[] memory) {
        return nodeDelegatorQueue;
    }

    /// @dev provides asset amount distribution data among depositPool, NDCs and eigenLayer
    /// @param asset the asset to get the total amount of
    /// @return assetLyingInDepositPool asset amount lying in this LRTDepositPool contract
    /// @return assetLyingInNDCs asset amount sum lying in all NDC contract
    /// @return assetStakedInEigenLayer asset amount deposited in eigen layer strategies through all NDCs
    /// @return assetUnstakingFromEigenLayer asset amount in delayed withdrawal from eigen layer strategies through all
    /// NDCs
    /// @return assetLyingInConverter asset value lying in converter
    /// @return assetLyingUnstakingVault asset amount lying in UnstakingVault
    function getAssetDistributionData(address asset)
        public
        view
        override
        onlySupportedAsset(asset)
        returns (
            uint256 assetLyingInDepositPool,
            uint256 assetLyingInNDCs,
            uint256 assetStakedInEigenLayer,
            uint256 assetUnstakingFromEigenLayer,
            uint256 assetLyingInConverter,
            uint256 assetLyingUnstakingVault
        )
    {
        if (asset == LRTConstants.ETH_TOKEN) {
            return getETHDistributionData();
        }
        assetLyingInDepositPool = IERC20(asset).balanceOf(address(this));

        address lrtUnstakingVault = lrtConfig.getContract(LRTConstants.LRT_UNSTAKING_VAULT);

        assetLyingUnstakingVault = IERC20(asset).balanceOf(lrtUnstakingVault);
        assetUnstakingFromEigenLayer = ILRTUnstakingVault(lrtUnstakingVault).getAssetsUnstaking(asset);

        uint256 ndcsCount = nodeDelegatorQueue.length;
        for (uint256 i; i < ndcsCount;) {
            assetLyingInNDCs += IERC20(asset).balanceOf(nodeDelegatorQueue[i]);
            assetStakedInEigenLayer += INodeDelegator(nodeDelegatorQueue[i]).getAssetBalance(asset);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev provides ETH amount distribution data among depositPool, NDCs and eigenLayer
    /// @dev rewards are not accounted here
    /// it will automatically be accounted once it is moved from feeReceiver/rewardReceiver to depositPool
    function getETHDistributionData()
        public
        view
        override
        returns (
            uint256 ethLyingInDepositPool,
            uint256 ethLyingInNDCs,
            uint256 ethStakedInEigenLayer,
            uint256 ethUnstakingFromEigenLayer,
            uint256 ethLyingInConverter,
            uint256 ethLyingInUnstakingVault
        )
    {
        ethUnstakingFromEigenLayer = 0;
        ethLyingInDepositPool = address(this).balance;

        address lrtConverter = lrtConfig.getContract(LRTConstants.LRT_CONVERTER);
        ethLyingInConverter = ILRTConverter(lrtConverter).ethValueInWithdrawal();
        ethLyingInUnstakingVault = address(lrtConfig.getContract(LRTConstants.LRT_UNSTAKING_VAULT)).balance;

        uint256 ndcsCount = nodeDelegatorQueue.length;
        for (uint256 i; i < ndcsCount;) {
            ethLyingInNDCs += nodeDelegatorQueue[i].balance;
            ethStakedInEigenLayer += INodeDelegator(nodeDelegatorQueue[i]).getETHEigenPodBalance();
            unchecked {
                ++i;
            }
        }
    }

    /// @notice View amount of novETH to mint for given asset amount
    /// @param asset Asset address
    /// @param amount Asset amount
    /// @return novethAmountToMint Amount of noveth to mint
    function getNovETHAmountToMint(
        address asset,
        uint256 amount
    )
        public
        view
        override
        returns (uint256 novethAmountToMint)
    {
        // setup oracle contract
        address lrtOracleAddress = lrtConfig.getContract(LRTConstants.LRT_ORACLE);
        ILRTOracle lrtOracle = ILRTOracle(lrtOracleAddress);

        // calculate noveth amount to mint based on asset amount and asset exchange rate
        novethAmountToMint = (amount * lrtOracle.getAssetPrice(asset)) / lrtOracle.novETHPrice();
    }

    /*//////////////////////////////////////////////////////////////
                            write functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows user to deposit ETH to the protocol
    /// @param minNovETHAmountExpected Minimum amount of noveth to receive
    /// @param referralId referral id
    function depositETH(
        uint256 minNovETHAmountExpected,
        string calldata referralId
    )
        external
        payable
        whenNotPaused
        nonReentrant
    {
        // checks
        uint256 novethAmountToMint = _beforeDeposit(LRTConstants.ETH_TOKEN, msg.value, minNovETHAmountExpected);

        // interactions
        _mintNovETH(novethAmountToMint);

        emit ETHDeposit(msg.sender, msg.value, novethAmountToMint, referralId);
    }

    /// @notice helps user stake LST to the protocol
    /// @param asset LST asset address to stake
    /// @param depositAmount LST asset amount to stake
    /// @param minNovETHAmountExpected Minimum amount of noveth to receive
    function depositAsset(
        address asset,
        uint256 depositAmount,
        uint256 minNovETHAmountExpected,
        string calldata referralId
    )
        external
        whenNotPaused
        nonReentrant
        onlySupportedAsset(asset)
    {
        // checks
        uint256 novethAmountToMint = _beforeDeposit(asset, depositAmount, minNovETHAmountExpected);

        // interactions
        IERC20(asset).safeTransferFrom(msg.sender, address(this), depositAmount);
        _mintNovETH(novethAmountToMint);

        emit AssetDeposit(msg.sender, asset, depositAmount, novethAmountToMint, referralId);
    }

    function _beforeDeposit(
        address asset,
        uint256 depositAmount,
        uint256 minNovETHAmountExpected
    )
        private
        view
        returns (uint256 novethAmountToMint)
    {
        if (depositAmount == 0 || depositAmount < minAmountToDeposit) {
            revert InvalidAmountToDeposit();
        }

        if (checkIfDepositAmountExceedesCurrentLimit(asset, depositAmount)) {
            revert MaximumDepositLimitReached();
        }
        novethAmountToMint = getNovETHAmountToMint(asset, depositAmount);

        if (novethAmountToMint < minNovETHAmountExpected) {
            revert MinimumAmountToReceiveNotMet();
        }
    }

    /// @dev private function to mint noveth
    /// @param novethAmountToMint Amount of noveth minted
    function _mintNovETH(uint256 novethAmountToMint) private {
        address novethToken = lrtConfig.novETH();
        // mint noveth for user
        INovETH(novethToken).mint(msg.sender, novethAmountToMint);
    }

    /// @notice add new node delegator contract addresses
    /// @dev only callable by LRT admin
    /// @param nodeDelegatorContracts Array of NodeDelegator contract addresses
    function addNodeDelegatorContractToQueue(address[] calldata nodeDelegatorContracts) external onlyLRTAdmin {
        uint256 length = nodeDelegatorContracts.length;
        if (nodeDelegatorQueue.length + length > maxNodeDelegatorLimit) {
            revert MaximumNodeDelegatorLimitReached();
        }

        for (uint256 i; i < length;) {
            UtilLib.checkNonZeroAddress(nodeDelegatorContracts[i]);

            // check if node delegator contract is already added and add it if not
            if (isNodeDelegator[nodeDelegatorContracts[i]] == 0) {
                nodeDelegatorQueue.push(nodeDelegatorContracts[i]);
            }

            isNodeDelegator[nodeDelegatorContracts[i]] = 1;

            unchecked {
                ++i;
            }
        }

        emit NodeDelegatorAddedinQueue(nodeDelegatorContracts);
    }

    /// @notice remove node delegator contract address from queue
    /// @dev only callable by LRT admin
    /// @param nodeDelegatorAddress NodeDelegator contract address
    function removeNodeDelegatorContractFromQueue(address nodeDelegatorAddress) public onlyLRTAdmin {
        // 1. check if node delegator contract is in queue
        uint256 length = nodeDelegatorQueue.length;
        uint256 ndcIndex;

        for (uint256 i; i < length;) {
            if (nodeDelegatorQueue[i] == nodeDelegatorAddress) {
                ndcIndex = i;
                break;
            }

            // 1.1 If node delegator contract is not found in queue, revert
            if (i == length - 1) {
                revert NodeDelegatorNotFound();
            }

            unchecked {
                ++i;
            }
        }

        // 2. revert if node delegator contract has any asset balances.

        // 2.1 check if NDC has native ETH balance in eigen layer or/and in itself.
        if (
            INodeDelegator(nodeDelegatorAddress).getETHEigenPodBalance() > 0
                || address(nodeDelegatorAddress).balance > 0
        ) {
            revert NodeDelegatorHasETH();
        }

        // 2.2  check if NDC has LST balance
        address[] memory supportedAssets = lrtConfig.getSupportedAssetList();
        uint256 supportedAssetsLength = supportedAssets.length;

        uint256 assetBalance;
        for (uint256 i; i < supportedAssetsLength; i++) {
            if (supportedAssets[i] == LRTConstants.ETH_TOKEN) {
                // ETH already checked above.
                continue;
            }

            assetBalance = IERC20(supportedAssets[i]).balanceOf(nodeDelegatorAddress)
                + INodeDelegator(nodeDelegatorAddress).getAssetBalance(supportedAssets[i]);

            if (assetBalance > 0) {
                revert NodeDelegatorHasAssetBalance(supportedAssets[i], assetBalance);
            }
        }

        // 3. remove node delegator contract from queue

        // 3.1 remove from isNodeDelegator mapping
        isNodeDelegator[nodeDelegatorAddress] = 0;
        // 3.2 remove from nodeDelegatorQueue
        nodeDelegatorQueue[ndcIndex] = nodeDelegatorQueue[length - 1];
        nodeDelegatorQueue.pop();

        emit NodeDelegatorRemovedFromQueue(nodeDelegatorAddress);
    }

    /// @notice remove many node delegator contracts from queue
    /// @dev calls internally removeNodeDelegatorContractFromQueue which is only callable by LRT admin
    /// @param nodeDelegatorContracts Array of NodeDelegator contract addresses
    function removeManyNodeDelegatorContractsFromQueue(address[] calldata nodeDelegatorContracts) external {
        uint256 length = nodeDelegatorContracts.length;

        for (uint256 i; i < length;) {
            removeNodeDelegatorContractFromQueue(nodeDelegatorContracts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice transfers asset lying in this DepositPool to node delegator contract
    /// @dev only callable by LRT manager
    /// @param ndcIndex Index of NodeDelegator contract address in nodeDelegatorQueue
    /// @param asset Asset address
    /// @param amount Asset amount to transfer
    function transferAssetToNodeDelegator(
        uint256 ndcIndex,
        address asset,
        uint256 amount
    )
        external
        nonReentrant
        onlyLRTManager
        onlySupportedAsset(asset)
    {
        address nodeDelegator = nodeDelegatorQueue[ndcIndex];
        IERC20(asset).safeTransfer(nodeDelegator, amount);
    }

    /// @notice transfers ETH lying in this DepositPool to node delegator contract
    /// @dev only callable by LRT manager
    /// @param ndcIndex Index of NodeDelegator contract address in nodeDelegatorQueue
    /// @param amount ETH amount to transfer
    function transferETHToNodeDelegator(uint256 ndcIndex, uint256 amount) external nonReentrant onlyLRTManager {
        address nodeDelegator = nodeDelegatorQueue[ndcIndex];
        INodeDelegator(nodeDelegator).sendETHFromDepositPoolToNDC{ value: amount }();
        emit EthTransferred(nodeDelegator, amount);
    }

    /// @notice swap ETH for LST asset which is accepted by LRTDepositPool
    /// @dev use LRTOracle to get price for toToken. Only callable by LRT manager
    /// @param toAsset Asset address to swap to
    /// @param minToAssetAmount Minimum asset amount to swap to
    function swapETHForAssetWithinDepositPool(
        address toAsset,
        uint256 minToAssetAmount
    )
        external
        payable
        onlyLRTManager
        onlySupportedAsset(toAsset)
    {
        // checks
        uint256 ethAmountSent = msg.value;

        uint256 returnAmount = getSwapETHToAssetReturnAmount(toAsset, ethAmountSent);

        if (returnAmount < minToAssetAmount || IERC20(toAsset).balanceOf(address(this)) < returnAmount) {
            revert NotEnoughAssetToTransfer();
        }

        // interactions
        IERC20(toAsset).transfer(msg.sender, returnAmount);

        emit ETHSwappedForLST(ethAmountSent, toAsset, returnAmount);
    }

    /// @notice get return amount for swapping ETH to asset that is accepted by LRTDepositPool
    /// @dev use LRTOracle to get price for toToken
    /// @param toAsset Asset address to swap to
    /// @param ethAmountToSend Eth amount to swap from
    /// @return returnAmount Return amount of toAsset
    function getSwapETHToAssetReturnAmount(
        address toAsset,
        uint256 ethAmountToSend
    )
        public
        view
        returns (uint256 returnAmount)
    {
        address lrtOracleAddress = lrtConfig.getContract(LRTConstants.LRT_ORACLE);
        ILRTOracle lrtOracle = ILRTOracle(lrtOracleAddress);

        uint256 ethPricePerUint = 1e18;

        return ethPricePerUint * ethAmountToSend / lrtOracle.getAssetPrice(toAsset);
    }

    /// @notice update max node delegator count
    /// @dev only callable by LRT admin
    /// @param maxNodeDelegatorLimit_ Maximum count of node delegator
    function updateMaxNodeDelegatorLimit(uint256 maxNodeDelegatorLimit_) external onlyLRTAdmin {
        if (maxNodeDelegatorLimit_ < nodeDelegatorQueue.length) {
            revert InvalidMaximumNodeDelegatorLimit();
        }

        maxNodeDelegatorLimit = maxNodeDelegatorLimit_;
        emit MaxNodeDelegatorLimitUpdated(maxNodeDelegatorLimit);
    }

    /// @notice update min amount to deposit
    /// @dev only callable by LRT admin
    /// @param minAmountToDeposit_ Minimum amount to deposit
    function setMinAmountToDeposit(uint256 minAmountToDeposit_) external onlyLRTAdmin {
        minAmountToDeposit = minAmountToDeposit_;
        emit MinAmountToDepositUpdated(minAmountToDeposit_);
    }

    /// @notice Approves the maximum amount of an asset to the LRTConverter contract
    /// @dev only supported assets can be deposited and only called by the LRT manager
    /// @param asset the asset to approve
    function maxApproveToLRTConverter(address asset) external onlySupportedAsset(asset) onlyLRTManager {
        address lrtConverterAddress = lrtConfig.getContract(LRTConstants.LRT_CONVERTER);
        IERC20(asset).approve(lrtConverterAddress, type(uint256).max);
    }

    /// @dev Triggers stopped state. Contract must not be paused.
    function pause() external onlyLRTManager {
        _pause();
    }

    /// @dev Returns to normal state. Contract must be paused
    function unpause() external onlyLRTAdmin {
        _unpause();
    }

    receive() external payable { }
}
