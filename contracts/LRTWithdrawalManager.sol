// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { UtilLib } from "./utils/UtilLib.sol";
import { LRTConstants } from "./utils/LRTConstants.sol";
import { DoubleEndedQueue } from "./utils/DoubleEndedQueue.sol";

import { LRTConfigRoleChecker, ILRTConfig } from "./utils/LRTConfigRoleChecker.sol";
import { INovETH } from "./interfaces/INovETH.sol";
import { ILRTOracle } from "./interfaces/ILRTOracle.sol";
import { INodeDelegator } from "./interfaces/INodeDelegator.sol";
import { ILRTWithdrawalManager, IStrategy, IERC20 } from "./interfaces/ILRTWithdrawalManager.sol";
import { ILRTDepositPool } from "./interfaces/ILRTDepositPool.sol";
import { ILRTUnstakingVault } from "./interfaces/ILRTUnstakingVault.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LRTWithdrawalManager - Withdraw Manager Contract for novETH => LSTs
/// @notice Handles LST asset withdraws
contract LRTWithdrawalManager is
    ILRTWithdrawalManager,
    LRTConfigRoleChecker,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;
    using SafeERC20 for IERC20;

    mapping(address asset => uint256) public minAmountToWithdraw;
    uint256 public withdrawalDelayBlocks;

    // Next available nonce for withdrawal requests per asset, indicating total requests made.
    mapping(address asset => uint256 nonce) public nextUnusedNonce;

    // Next nonce for which a withdrawal request remains locked.
    mapping(address asset => uint256 requestNonce) public nextLockedNonce;

    // Mapping from a unique request identifier to its corresponding withdrawal request
    mapping(bytes32 requestId => WithdrawalRequest) public withdrawalRequests;

    // Maps each asset to user addresses, pointing to an ordert list of their withdrawal request nonces.
    // Utilizes a double-ended queue for efficient management and removal of initial requests.
    mapping(address asset => mapping(address user => DoubleEndedQueue.Uint256Deque requestNonces)) public
        userAssociatedNonces;

    // Asset amount commited to be withdrawn by users.
    mapping(address asset => uint256 amount) public assetsCommitted;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract
    /// @param lrtConfigAddr LRT config address
    function initialize(address lrtConfigAddr) external initializer {
        UtilLib.checkNonZeroAddress(lrtConfigAddr);
        __Pausable_init();
        __ReentrancyGuard_init();
        withdrawalDelayBlocks = 8 days / 12 seconds;

        lrtConfig = ILRTConfig(lrtConfigAddr);
        emit UpdatedLRTConfig(lrtConfigAddr);
    }

    modifier onlySupportedStrategy(address asset) {
        if (asset != LRTConstants.ETH_TOKEN && lrtConfig.assetStrategy(asset) == address(0)) {
            revert StrategyNotSupported();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get request id
    /// @param asset Asset address
    /// @param requestIndex The requests index to generate id for
    function getRequestId(address asset, uint256 requestIndex) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(asset, requestIndex));
    }

    /// @notice Get asset amount to receive when trading in novETH
    /// @param asset Asset address of LST to receive
    /// @param amount novETH amount to convert
    /// @return underlyingToReceive Amount of underlying to receive
    function getExpectedAssetAmount(
        address asset,
        uint256 amount
    )
        public
        view
        override
        returns (uint256 underlyingToReceive)
    {
        // setup oracle contract
        ILRTOracle lrtOracle = ILRTOracle(lrtConfig.getContract(LRTConstants.LRT_ORACLE));

        // calculate underlying asset amount to receive based on novETH amount and asset exchange rate
        underlyingToReceive = amount * lrtOracle.novETHPrice() / lrtOracle.getAssetPrice(asset);
    }

    /// @notice Calculates the amount of asset available for withdrawal.
    /// @param asset The asset address.
    /// @return availableAssetAmount The asset amount avaialble for withdrawal.
    function getAvailableAssetAmount(address asset) public view override returns (uint256 availableAssetAmount) {
        ILRTDepositPool lrtDepositPool = ILRTDepositPool(lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL));
        uint256 totalAssets = lrtDepositPool.getTotalAssetDeposits(asset);
        availableAssetAmount = totalAssets > assetsCommitted[asset] ? totalAssets - assetsCommitted[asset] : 0;
    }

    /// @notice View user withdrawal request
    /// @param asset Asset address
    /// @param user User address
    /// @param userIndex Index in list of users withdrawal request
    function getUserWithdrawalRequest(
        address asset,
        address user,
        uint256 userIndex
    )
        public
        view
        override
        returns (uint256 novETHAmount, uint256 expectedAssetAmount, uint256 withdrawalStartBlock, uint256 userNonce)
    {
        userNonce = userAssociatedNonces[asset][user].at(userIndex);
        bytes32 requestId = getRequestId(asset, userNonce);
        novETHAmount = withdrawalRequests[requestId].novETHUnstaked;
        expectedAssetAmount = withdrawalRequests[requestId].expectedAssetAmount;
        withdrawalStartBlock = withdrawalRequests[requestId].withdrawalStartBlock;
    }

    /*//////////////////////////////////////////////////////////////
                        User Withdrawal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a withdrawal request for converting novETH to a specified LST.
    /// @param asset The LST address the user wants to receive.
    /// @param novETHUnstaked The amount of novETH the user wishes to unstake.
    /// @dev This function is only callable by the user and is used to initiate a withdrawal request for a specific
    /// asset. Will be finalised by calling `completeWithdrawal` after the manager unlocked the request and the delay
    /// has past. There is an edge case were the user withdraws last underlying asset and that asset gets slashed.
    function initiateWithdrawal(
        address asset,
        uint256 novETHUnstaked
    )
        external
        override
        whenNotPaused
        nonReentrant
        onlySupportedAsset(asset)
        onlySupportedStrategy(asset)
    {
        if (novETHUnstaked == 0 || novETHUnstaked < minAmountToWithdraw[asset]) revert InvalidAmountToWithdraw();

        IERC20(lrtConfig.novETH()).safeTransferFrom(msg.sender, address(this), novETHUnstaked);

        uint256 expectedAssetAmount = getExpectedAssetAmount(asset, novETHUnstaked);

        // Ensure the withdrawal does not exceed the available shares.
        if (expectedAssetAmount > getAvailableAssetAmount(asset)) revert ExceedAmountToWithdraw();

        // preventing over-withdrawal.
        assetsCommitted[asset] += expectedAssetAmount;

        _addUserWithdrawalRequest(asset, novETHUnstaked, expectedAssetAmount);

        emit AssetWithdrawalQueued(msg.sender, asset, novETHUnstaked);
    }

    /// @notice Completes a user's withdrawal process by transferring the LST amount corresponding to the novETH
    /// unstaked.
    /// @param asset The asset address the user wishes to withdraw.
    function completeWithdrawal(address asset) external payable whenNotPaused onlySupportedAsset(asset) nonReentrant {
        // Retrieve and remove the oldest withdrawal request for the user.
        uint256 usersFirstWithdrawalRequestNonce = userAssociatedNonces[asset][msg.sender].popFront();
        // Ensure the request is already unlocked.
        if (usersFirstWithdrawalRequestNonce >= nextLockedNonce[asset]) revert WithdrawalLocked();

        bytes32 requestId = getRequestId(asset, usersFirstWithdrawalRequestNonce);
        WithdrawalRequest memory request = withdrawalRequests[requestId];

        delete withdrawalRequests[requestId];

        // Check that the withdrawal delay has passed since the request's initiation.
        if (block.number < request.withdrawalStartBlock + withdrawalDelayBlocks) revert WithdrawalDelayNotPassed();

        if (asset == LRTConstants.ETH_TOKEN) {
            (bool sent,) = payable(msg.sender).call{ value: request.expectedAssetAmount }("");
            if (!sent) revert EthTransferFailed();
        } else {
            IERC20(asset).safeTransfer(msg.sender, request.expectedAssetAmount);
        }

        emit AssetWithdrawalFinalized(msg.sender, asset, request.novETHUnstaked, request.expectedAssetAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGER UNSTAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Unlocks assets in the queue up to a specified limit.
    /// @param asset The address of the asset to unlock.
    /// @param firstExcludedIndex First withdrawal requests index that will not be considered for unlocking.
    /// @param minimumAssetPrice The minimum acceptable price for the asset.
    /// @param minimumNovEthPrice The minimum acceptable price for novETH.
    function unlockQueue(
        address asset,
        uint256 firstExcludedIndex,
        uint256 minimumAssetPrice,
        uint256 minimumNovEthPrice
    )
        external
        nonReentrant
        onlySupportedAsset(asset)
        onlyLRTOperator
        returns (uint256 novETHBurned, uint256 assetAmountUnlocked)
    {
        ILRTOracle lrtOracle = ILRTOracle(lrtConfig.getContract(LRTConstants.LRT_ORACLE));
        ILRTUnstakingVault unstakingVault = ILRTUnstakingVault(lrtConfig.getContract(LRTConstants.LRT_UNSTAKING_VAULT));
        uint256 novETHPrice = lrtOracle.novETHPrice();
        uint256 assetPrice = lrtOracle.getAssetPrice(asset);

        // Ensure the current prices meet or exceed the minimum required prices.
        if (novETHPrice < minimumNovEthPrice) revert NovETHPriceMustBeGreaterMinimum(novETHPrice);
        if (assetPrice < minimumAssetPrice) revert AssetPriceMustBeGreaterMinimum(assetPrice);

        uint256 totalAvailableAssets = unstakingVault.balanceOf(asset);

        if (totalAvailableAssets == 0) revert AmountMustBeGreaterThanZero();

        // Updates and unlocks withdrawal requests up to a specified upper limit or until allocated assets are fully
        // utilized.
        (novETHBurned, assetAmountUnlocked) =
            _unlockWithdrawalRequests(asset, totalAvailableAssets, novETHPrice, assetPrice, firstExcludedIndex);

        if (novETHBurned != 0) INovETH(lrtConfig.novETH()).burnFrom(address(this), novETHBurned);
        //Take the amount to distribute from vault
        unstakingVault.redeem(asset, assetAmountUnlocked);

        emit AssetUnlocked(asset, novETHBurned, assetAmountUnlocked, novETHPrice, assetPrice);
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice update min amount to withdraw
    /// @dev only callable by LRT admin
    /// @param asset Asset address
    /// @param minAmountToWithdraw_ Minimum amount to withdraw
    function setMinAmountToWithdraw(address asset, uint256 minAmountToWithdraw_) external onlyLRTAdmin {
        minAmountToWithdraw[asset] = minAmountToWithdraw_;
        emit MinAmountToWithdrawUpdated(asset, minAmountToWithdraw_);
    }

    /// @notice update withdrawal delay
    /// @dev only callable by LRT admin
    /// @param withdrawalDelayBlocks_ The amount of blocks to wait till to complete a withdraw
    function setWithdrawalDelayBlocks(uint256 withdrawalDelayBlocks_) external onlyLRTAdmin {
        // if (7 days / 12 seconds > withdrawalDelayBlocks_) revert WithdrawalDelayTooSmall(); // for on mainnet
        if (100 > withdrawalDelayBlocks_) revert WithdrawalDelayTooSmall(); //for test
        withdrawalDelayBlocks = withdrawalDelayBlocks_;
        emit WithdrawalDelayBlocksUpdated(withdrawalDelayBlocks);
    }

    /// @dev Triggers stopped state. Contract must not be paused.
    function pause() external onlyRole(LRTConstants.PAUSER_ROLE) {
        _pause();
    }

    /// @dev Returns to normal state. Contract must be paused
    function unpause() external onlyLRTAdmin {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers a new request for withdrawing an asset in exchange for novETH.
    /// @param asset The address of the asset being withdrawn.
    /// @param novETHUnstaked The amount of novETH being exchanged.
    /// @param expectedAssetAmount The expected amount of the asset to be received upon withdrawal completion.
    function _addUserWithdrawalRequest(address asset, uint256 novETHUnstaked, uint256 expectedAssetAmount) internal {
        // Generate a unique identifier for the new withdrawal request.
        bytes32 requestId = getRequestId(asset, nextUnusedNonce[asset]);

        // Create and store the new withdrawal request.
        withdrawalRequests[requestId] = WithdrawalRequest({
            novETHUnstaked: novETHUnstaked,
            expectedAssetAmount: expectedAssetAmount,
            withdrawalStartBlock: block.number
        });

        // Map the user to the newly created request index and increment the nonce for future requests.
        userAssociatedNonces[asset][msg.sender].pushBack(nextUnusedNonce[asset]);
        nextUnusedNonce[asset]++;
    }

    /// @dev Unlocks user withdrawal requests based on current asset availability and prices.
    /// Iterates through pending requests and unlocks them until the provided asset amount is fully allocated.
    /// @param asset The asset's address for which withdrawals are being processed.
    /// @param novETHPrice Current novETH to ETH exchange rate.
    /// @param assetPrice Current asset to ETH exchange rate.
    /// @param firstExcludedIndex First withdrawal requests index that will not be considered for unlocking.
    /// @return novETHAmountToBurn The total amount of novETH unlocked for withdrawals.
    /// @return assetAmountToUnlock The total asset amount allocated to unlocked withdrawals.
    function _unlockWithdrawalRequests(
        address asset,
        uint256 availableAssetAmount,
        uint256 novETHPrice,
        uint256 assetPrice,
        uint256 firstExcludedIndex
    )
        internal
        returns (uint256 novETHAmountToBurn, uint256 assetAmountToUnlock)
    {
        // Check that upper limit is in the range of existing withdrawal requests. If it is greater set it to the first
        // nonce with no withdrawal request.
        if (firstExcludedIndex > nextUnusedNonce[asset]) {
            firstExcludedIndex = nextUnusedNonce[asset];
        }

        // Revert when trying to unlock a request that has already been unlocked
        if (nextLockedNonce[asset] >= firstExcludedIndex) revert NoPendingWithdrawals();

        while (nextLockedNonce[asset] < firstExcludedIndex) {
            bytes32 requestId = getRequestId(asset, nextLockedNonce[asset]);
            WithdrawalRequest storage request = withdrawalRequests[requestId];

            // Calculate the amount user will recieve
            uint256 payoutAmount = _calculatePayoutAmount(request, novETHPrice, assetPrice);

            if (availableAssetAmount < payoutAmount) break; // Exit if not enough assets to cover this request

            assetsCommitted[asset] -= request.expectedAssetAmount;
            // Set the amount the user will recieve
            request.expectedAssetAmount = payoutAmount;
            novETHAmountToBurn += request.novETHUnstaked;
            availableAssetAmount -= payoutAmount;
            assetAmountToUnlock += payoutAmount;
            unchecked {
                nextLockedNonce[asset]++;
            }
        }
    }

    /// @notice Determines the final amount to be disbursed to the user, based on the lesser of the initially
    /// expected asset amount and the currently calculated return.
    /// @param request The specific withdrawal request being processed.
    /// @param novETHPrice The latest exchange rate of novETH to ETH.
    /// @param assetPrice The latest exchange rate of the asset to ETH.
    /// @return The final amount the user is going to receive.
    function _calculatePayoutAmount(
        WithdrawalRequest storage request,
        uint256 novETHPrice,
        uint256 assetPrice
    )
        private
        view
        returns (uint256)
    {
        uint256 currentReturn = (request.novETHUnstaked * novETHPrice) / assetPrice;
        return (request.expectedAssetAmount < currentReturn) ? request.expectedAssetAmount : currentReturn;
    }

    receive() external payable { }
}
