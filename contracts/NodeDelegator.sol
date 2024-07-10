// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { UtilLib } from "./utils/UtilLib.sol";
import { LRTConstants } from "./utils/LRTConstants.sol";
import { LRTConfigRoleChecker, ILRTConfig } from "./utils/LRTConfigRoleChecker.sol";

import { INodeDelegator } from "./interfaces/INodeDelegator.sol";
import { IStrategy } from "./interfaces/IStrategy.sol";
import { IEigenStrategyManager } from "./interfaces/IEigenStrategyManager.sol";
import { IEigenDelayedWithdrawalRouter } from "./interfaces/IEigenDelayedWithdrawalRouter.sol";

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import { IEigenPodManager } from "./interfaces/IEigenPodManager.sol";
import { IEigenPod, BeaconChainProofs, IBeaconDeposit } from "./interfaces/IEigenPod.sol";
import { ISSVNetwork, Cluster } from "./interfaces/ISSVNetwork.sol";
import { IEigenDelegationManager } from "./interfaces/IEigenDelegationManager.sol";
import { ILRTUnstakingVault } from "./interfaces/ILRTUnstakingVault.sol";

/// @title NodeDelegator Contract
/// @notice The contract that handles the depositing of assets into strategies
contract NodeDelegator is INodeDelegator, LRTConfigRoleChecker, PausableUpgradeable, ReentrancyGuardUpgradeable {
    /// @dev The EigenPod is created and owned by this contract
    IEigenPod public eigenPod;
    /// @dev Tracks the balance staked to validators and has yet to have the credentials verified with EigenLayer.
    /// call verifyWithdrawalCredentialsAndBalance in EL to verify the validator credentials on EigenLayer
    uint256 public stakedButUnverifiedNativeETH;

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

        lrtConfig = ILRTConfig(lrtConfigAddr);
        emit UpdatedLRTConfig(lrtConfigAddr);
    }

    function createEigenPod() external onlyLRTManager {
        IEigenPodManager eigenPodManager = IEigenPodManager(lrtConfig.getContract(LRTConstants.EIGEN_POD_MANAGER));
        eigenPodManager.createPod();
        eigenPod = eigenPodManager.ownerToPod(address(this));

        emit EigenPodCreated(address(eigenPod), address(this));
    }

    /// @notice Approves the maximum amount of an asset to the eigen strategy manager
    /// @dev only supported assets can be deposited and only called by the LRT manager
    /// @param asset the asset to deposit
    function maxApproveToEigenStrategyManager(address asset)
        external
        override
        onlySupportedAsset(asset)
        onlyLRTManager
    {
        address eigenlayerStrategyManagerAddress = lrtConfig.getContract(LRTConstants.EIGEN_STRATEGY_MANAGER);
        IERC20(asset).approve(eigenlayerStrategyManagerAddress, type(uint256).max);
    }

    /// @notice Deposits an asset lying in this NDC into its strategy
    /// @dev only supported assets can be deposited and only called by the LRT manager
    /// @param asset the asset to deposit
    function depositAssetIntoStrategy(address asset)
        external
        override
        whenNotPaused
        nonReentrant
        onlySupportedAsset(asset)
        onlyLRTManager
    {
        address strategy = lrtConfig.assetStrategy(asset);
        if (strategy == address(0)) {
            revert StrategyIsNotSetForAsset();
        }

        IERC20 token = IERC20(asset);
        address eigenlayerStrategyManagerAddress = lrtConfig.getContract(LRTConstants.EIGEN_STRATEGY_MANAGER);

        uint256 balance = token.balanceOf(address(this));

        IEigenStrategyManager(eigenlayerStrategyManagerAddress).depositIntoStrategy(IStrategy(strategy), token, balance);

        emit AssetDepositIntoStrategy(asset, strategy, balance);
    }

    /// @notice Transfers an asset back to the LRT deposit pool
    /// @dev only supported assets can be transferred and only called by the LRT manager
    /// @param asset the asset to transfer
    /// @param amount the amount to transfer
    function transferBackToLRTDepositPool(
        address asset,
        uint256 amount
    )
        external
        whenNotPaused
        nonReentrant
        onlySupportedAsset(asset)
        onlyLRTManager
    {
        address lrtDepositPool = lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL);

        bool success;
        if (asset == LRTConstants.ETH_TOKEN) {
            (success,) = payable(lrtDepositPool).call{ value: amount }("");
        } else {
            success = IERC20(asset).transfer(lrtDepositPool, amount);
        }

        if (!success) {
            revert TokenTransferFailed();
        }
    }

    /// @notice Fetches balance of all assets staked in eigen layer through this contract
    /// @return assets the assets that the node delegator has deposited into strategies
    /// @return assetBalances the balances of the assets that the node delegator has deposited into strategies
    function getAssetBalances()
        external
        view
        override
        returns (address[] memory assets, uint256[] memory assetBalances)
    {
        address eigenlayerStrategyManagerAddress = lrtConfig.getContract(LRTConstants.EIGEN_STRATEGY_MANAGER);

        (IStrategy[] memory strategies,) =
            IEigenStrategyManager(eigenlayerStrategyManagerAddress).getDeposits(address(this));

        uint256 strategiesLength = strategies.length;
        assets = new address[](strategiesLength);
        assetBalances = new uint256[](strategiesLength);

        for (uint256 i = 0; i < strategiesLength;) {
            assets[i] = address(IStrategy(strategies[i]).underlyingToken());
            assetBalances[i] = IStrategy(strategies[i]).userUnderlyingView(address(this));
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Returns the balance of an asset that the node delegator has deposited into the strategy
    /// @param asset the asset to get the balance of
    /// @return stakedBalance the balance of the asset
    function getAssetBalance(address asset) external view override returns (uint256) {
        address strategy = lrtConfig.assetStrategy(asset);
        if (strategy == address(0)) {
            return 0;
        }

        return IStrategy(strategy).userUnderlyingView(address(this));
    }

    /// @dev Returns the balance of an asset that the node delegator has deposited into its EigenPod strategy
    function getETHEigenPodBalance() external view override returns (uint256 ethStaked) {
        // TODO: Implement functionality to manage pending withdrawals and accommodate negative shares once withdrawal
        // feature is activated. Additionally, ensure verification of both staked but unverified and staked and verified
        // ETH native supply NDCs as provided to Eigenlayer.
        ethStaked = stakedButUnverifiedNativeETH;
    }

    /// @notice Stake ETH from NDC into EigenLayer. it calls the stake function in the EigenPodManager
    /// which in turn calls the stake function in the EigenPod
    /// @param pubkey The pubkey of the validator
    /// @param signature The signature of the validator
    /// @param depositDataRoot The deposit data root of the validator
    /// @dev Only LRT Operator should call this function
    /// @dev Exactly 32 ether is allowed, hence it is hardcoded
    /// @dev offchain checks withdraw credentials authenticity
    function stake32Eth(
        bytes calldata pubkey,
        bytes calldata signature,
        bytes32 depositDataRoot
    )
        external
        whenNotPaused
        onlyLRTOperator
    {
        IEigenPodManager eigenPodManager = IEigenPodManager(lrtConfig.getContract(LRTConstants.EIGEN_POD_MANAGER));
        eigenPodManager.stake{ value: 32 ether }(pubkey, signature, depositDataRoot);

        // tracks staked but unverified native ETH
        stakedButUnverifiedNativeETH += 32 ether;

        emit ETHStaked(pubkey, 32 ether);
    }

    /// @notice Stake ETH from NDC into EigenLayer
    /// @param pubkey The pubkey of the validator
    /// @param signature The signature of the validator
    /// @param depositDataRoot The deposit data root of the validator
    /// @param expectedDepositRoot The expected deposit data root, which is computed offchain
    /// @dev Only LRT Operator should call this function
    /// @dev Exactly 32 ether is allowed, hence it is hardcoded
    /// @dev offchain checks withdraw credentials authenticity
    /// @dev compares expected deposit root with actual deposit root
    function stake32EthValidated(
        bytes calldata pubkey,
        bytes calldata signature,
        bytes32 depositDataRoot,
        bytes32 expectedDepositRoot
    )
        external
        whenNotPaused
        onlyLRTOperator
    {
        IBeaconDeposit depositContract = eigenPod.ethPOS();
        bytes32 actualDepositRoot = depositContract.get_deposit_root();
        if (expectedDepositRoot != actualDepositRoot) {
            revert InvalidDepositRoot(expectedDepositRoot, actualDepositRoot);
        }
        IEigenPodManager eigenPodManager = IEigenPodManager(lrtConfig.getContract(LRTConstants.EIGEN_POD_MANAGER));
        eigenPodManager.stake{ value: 32 ether }(pubkey, signature, depositDataRoot);

        // tracks staked but unverified native ETH
        stakedButUnverifiedNativeETH += 32 ether;

        emit ETHStaked(pubkey, 32 ether);
    }

    /// @notice Finalizes Eigenlayer withdrawal to enable processing of queued withdrawals
    /// @param withdrawal Struct containing all data for the withdrawal
    /// @param assets Array specifying the `token` input for each strategy's 'withdraw' function.
    /// @param middlewareTimesIndex Index in the middleware times array for withdrawal eligibility check.
    function completeUnstaking(
        IEigenDelegationManager.Withdrawal calldata withdrawal,
        IERC20[] calldata assets,
        uint256 middlewareTimesIndex
    )
        external
        whenNotPaused
        nonReentrant
        onlyLRTOperator
    {
        address eigenlayerDelegationManagerAddress = lrtConfig.getContract(LRTConstants.EIGEN_DELEGATION_MANAGER);
        // Finalize withdrawal with Eigenlayer Delegation Manager
        IEigenDelegationManager(eigenlayerDelegationManagerAddress).completeQueuedWithdrawal(
            withdrawal, assets, middlewareTimesIndex, true
        );
        address withdrawer = lrtConfig.getContract(LRTConstants.LRT_UNSTAKING_VAULT);
        ILRTUnstakingVault lrtUnstakingVault = ILRTUnstakingVault(withdrawer);
        for (uint256 i = 0; i < assets.length;) {
            lrtUnstakingVault.reduceSharesUnstaking(address(assets[i]), withdrawal.shares[i]);
            assets[i].transfer(withdrawer, withdrawal.strategies[i].sharesToUnderlyingView(withdrawal.shares[i]));
            unchecked {
                i++;
            }
        }
        emit EigenLayerWithdrawalCompleted(withdrawal.staker, withdrawal.nonce, msg.sender);
    }

    /// @dev Triggers stopped state. Contract must not be paused.
    function pause() external onlyLRTManager {
        _pause();
    }

    /// @dev Returns to normal state. Contract must be paused
    function unpause() external onlyLRTAdmin {
        _unpause();
    }

    /// @notice Queues a withdrawal from the strategies
    /// @param queuedWithdrawalParam Array of queued withdrawals
    function initiateUnstaking(IEigenDelegationManager.QueuedWithdrawalParams calldata queuedWithdrawalParam)
        public
        override
        whenNotPaused
        nonReentrant
        onlyLRTOperator
        returns (bytes32 withdrawalRoot)
    {
        address beaconChainETHStrategy = lrtConfig.getContract(LRTConstants.BEACON_CHAIN_ETH_STRATEGY);

        ILRTUnstakingVault lrtUnstakingVault =
            ILRTUnstakingVault(lrtConfig.getContract(LRTConstants.LRT_UNSTAKING_VAULT));
        for (uint256 i = 0; i < queuedWithdrawalParam.strategies.length;) {
            if (address(beaconChainETHStrategy) == address(queuedWithdrawalParam.strategies[i])) {
                revert StrategyMustNotBeBeaconChain();
            }

            address token = address(queuedWithdrawalParam.strategies[i].underlyingToken());
            address strategy = lrtConfig.assetStrategy(token);

            if (strategy != address(queuedWithdrawalParam.strategies[i])) {
                revert StrategyIsNotSetForAsset();
            }
            lrtUnstakingVault.addSharesUnstaking(token, queuedWithdrawalParam.shares[i]);
            unchecked {
                ++i;
            }
        }
        address eigenlayerDelegationManagerAddress = lrtConfig.getContract(LRTConstants.EIGEN_DELEGATION_MANAGER);
        IEigenDelegationManager eigenlayerDelegationManager =
            IEigenDelegationManager(eigenlayerDelegationManagerAddress);

        IEigenDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams =
            new IEigenDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = queuedWithdrawalParam;
        uint256 nonce = eigenlayerDelegationManager.cumulativeWithdrawalsQueued(address(this));
        bytes32[] memory withdrawalRoots = eigenlayerDelegationManager.queueWithdrawals(queuedWithdrawalParams);
        withdrawalRoot = withdrawalRoots[0];

        emit WithdrawalQueued(nonce, address(this), withdrawalRoot);
    }

    /// @dev allow NodeDelegator to receive ETH
    function sendETHFromDepositPoolToNDC() external payable override {
        // only allow LRT deposit pool to send ETH to this contract
        address lrtDepositPool = lrtConfig.getContract(LRTConstants.LRT_DEPOSIT_POOL);
        if (msg.sender != lrtDepositPool) {
            revert InvalidETHSender();
        }

        emit ETHDepositFromDepositPool(msg.value);
    }

    /// @dev Approves the SSV Network contract to transfer SSV tokens for deposits
    function approveSSV() external onlyLRTManager {
        address ssvTokenAddress = lrtConfig.getContract(LRTConstants.SSV_TOKEN);
        address ssvNetworkAddress = lrtConfig.getContract(LRTConstants.SSV_NETWORK);

        IERC20(ssvTokenAddress).approve(ssvNetworkAddress, type(uint256).max);
    }

    /// @dev Deposits more SSV Tokens to the SSV Network contract which is used to pay the SSV Operators
    function depositSSV(uint64[] memory operatorIds, uint256 amount, Cluster memory cluster) external onlyLRTManager {
        address ssvNetworkAddress = lrtConfig.getContract(LRTConstants.SSV_NETWORK);

        ISSVNetwork(ssvNetworkAddress).deposit(address(this), operatorIds, amount, cluster);
    }

    function registerSsvValidator(
        bytes calldata publicKey,
        uint64[] calldata operatorIds,
        bytes calldata sharesData,
        uint256 amount,
        Cluster calldata cluster
    )
        external
        onlyLRTOperator
        whenNotPaused
    {
        address ssvNetworkAddress = lrtConfig.getContract(LRTConstants.SSV_NETWORK);

        ISSVNetwork(ssvNetworkAddress).registerValidator(publicKey, operatorIds, sharesData, amount, cluster);
    }

    /// @dev allow NodeDelegator to receive ETH
    receive() external payable { }
}
