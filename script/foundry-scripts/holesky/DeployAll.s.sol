// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.21;

import "forge-std/Script.sol";

import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
// import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LRTConfig, LRTConstants } from "contracts/LRTConfig.sol";
import { NovETH } from "contracts/NovETH.sol";
import { LRTDepositPool } from "contracts/LRTDepositPool.sol";
import { LRTWithdrawalManager } from "contracts/LRTWithdrawalManager.sol";
import { LRTConverter } from "contracts/LRTConverter.sol";
import { LRTUnstakingVault } from "contracts/LRTUnstakingVault.sol";
import { LRTOracle } from "contracts/LRTOracle.sol";
import { ChainlinkPriceOracle } from "contracts/oracles/ChainlinkPriceOracle.sol";
// import { EthXPriceOracle } from "contracts/oracles/EthXPriceOracle.sol";
import { NodeDelegator } from "contracts/NodeDelegator.sol";
import { ConfigLib } from "../libraries/ConfigLib.sol";
import { NovETHLib } from "../libraries/NovETHLib.sol";
import { DepositPoolLib } from "../libraries/DepositPoolLib.sol";
import { WithdrawalManagerLib } from "../libraries/WithdrawalManagerLib.sol";
import { ConverterLib } from "../libraries/ConverterLib.sol";
import { UnstakingVaultLib } from "../libraries/UnstakingVaultLib.sol";
import { OraclesLib } from "../libraries/OraclesLib.sol";
import { NodeDelegatorLib } from "../libraries/NodeDelegatorLib.sol";
import { AddressesHolesky } from "../utils/Addresses.sol";

import { MockPriceAggregator } from "script/foundry-scripts/utils/MockPriceAggregator.sol";

// solhint-disable-next-line max-states-count
contract DeployAll is Script {
    uint256 public constant MAX_DEPOSITS = 1000 ether;

    bool public isForked;

    address public deployerAddress;
    ProxyAdmin public proxyAdmin;

    LRTConfig public lrtConfig;
    NovETH public novETH;
    LRTDepositPool public depositPool;
    LRTOracle public lrtOracle;
    LRTWithdrawalManager public withdrawalManger;
    LRTConverter public converter;
    LRTUnstakingVault public unstakingVault;
    address public chainlinkPriceOracleAddress;
    address public ethXPriceOracleAddress;
    NodeDelegator public node1;
    NodeDelegator public node2;
    address[] public nodeDelegatorContracts;

    address public stETHPriceFeed;
    address public ethxPriceFeed;

    uint256 public minAmountToDeposit;

    function _maxApproveToEigenStrategyManager(address nodeDel) internal {
        NodeDelegator(payable(nodeDel)).maxApproveToEigenStrategyManager(AddressesHolesky.STETH_TOKEN);
        NodeDelegator(payable(nodeDel)).maxApproveToEigenStrategyManager(AddressesHolesky.ETHX_TOKEN);
    }

    function _setUpByAdmin() internal {
        // add novETH to LRT config
        lrtConfig.setNovETH(address(novETH));

        // add oracle to LRT config
        lrtConfig.setContract(LRTConstants.LRT_ORACLE, address(lrtOracle));

        // add contracts to LRT config
        lrtConfig.setContract(LRTConstants.LRT_DEPOSIT_POOL, address(depositPool));
        lrtConfig.setContract(LRTConstants.EIGEN_STRATEGY_MANAGER, AddressesHolesky.EIGEN_STRATEGY_MANAGER);
        lrtConfig.setContract(LRTConstants.EIGEN_POD_MANAGER, AddressesHolesky.EIGEN_POD_MANAGER);
        lrtConfig.setContract(LRTConstants.EIGEN_DELEGATION_MANAGER, AddressesHolesky.EIGEN_DELEGATION_MANAGER);
        lrtConfig.setContract(LRTConstants.LRT_WITHDRAW_MANAGER, address(withdrawalManger));
        lrtConfig.setContract(LRTConstants.LRT_UNSTAKING_VAULT, address(unstakingVault));
        lrtConfig.setContract(LRTConstants.LRT_CONVERTER, address(converter));

        // call updateAssetStrategy for each asset in LRTConfig
        lrtConfig.updateAssetStrategy(AddressesHolesky.STETH_TOKEN, AddressesHolesky.STETH_EIGEN_STRATEGY);
        lrtConfig.updateAssetStrategy(AddressesHolesky.ETHX_TOKEN, AddressesHolesky.ETHX_EIGEN_STRATEGY);

        // Set SSV contract addresses in LRTConfig
        lrtConfig.setContract(LRTConstants.SSV_TOKEN, AddressesHolesky.SSV_TOKEN);
        lrtConfig.setContract(LRTConstants.SSV_NETWORK, AddressesHolesky.SSV_NETWORK);

        // grant MANAGER_ROLE to deployer and Holesky Defender Relayer
        lrtConfig.grantRole(LRTConstants.MANAGER, deployerAddress);
        lrtConfig.grantRole(LRTConstants.MANAGER, AddressesHolesky.RELAYER);
        lrtConfig.grantRole(LRTConstants.DEFAULT_ADMIN_ROLE, deployerAddress);
        lrtConfig.grantRole(LRTConstants.DEFAULT_ADMIN_ROLE, AddressesHolesky.RELAYER);
        lrtConfig.grantRole(LRTConstants.OPERATOR_ROLE, deployerAddress);
        lrtConfig.grantRole(LRTConstants.OPERATOR_ROLE, AddressesHolesky.RELAYER);

        // add minter role to lrtDepositPool so it mints novETH
        lrtConfig.grantRole(LRTConstants.MINTER_ROLE, address(depositPool));

        // add burner role to lrtWithdrawalManager so it burn novETH
        lrtConfig.grantRole(LRTConstants.BURNER_ROLE, address(withdrawalManger));

        // add nodeDelegators to LRTDepositPool queue
        nodeDelegatorContracts.push(address(node1));

        depositPool.addNodeDelegatorContractToQueue(nodeDelegatorContracts);

        // add min amount to deposit in LRTDepositPool
        depositPool.setMinAmountToDeposit(minAmountToDeposit);

        // Approve 1nd NodeDelegator to transfer SSV tokens
        node1.approveSSV();
    }

    function _setUpByManager() internal {
        // Add chainlink oracles for supported assets in ChainlinkPriceOracle
        ChainlinkPriceOracle(chainlinkPriceOracleAddress).updatePriceFeedFor(
            AddressesHolesky.STETH_TOKEN, stETHPriceFeed
        );

        // call updatePriceOracleFor for each asset in LRTOracle
        lrtOracle.updatePriceOracleFor(AddressesHolesky.STETH_TOKEN, chainlinkPriceOracleAddress);
        lrtOracle.updatePriceOracleFor(AddressesHolesky.ETHX_TOKEN, ethXPriceOracleAddress);

        // _maxApproveToEigenStrategyManager in each NodeDelegator to transfer to strategy
        _maxApproveToEigenStrategyManager(address(node1));

        // Create and EigenPod for the 2nd NodeDelegator
        node1.createEigenPod();
    }

    function run() external {
        if (block.chainid != 17_000) {
            // solhint-disable gas-custom-errors
            revert("Not holesky");
        }

        isForked = vm.envOr("IS_FORK", false);
        if (isForked) {
            address mainnetProxyOwner = AddressesHolesky.PROXY_OWNER;
            console.log("Running script on Holesky fork impersonating: %s", mainnetProxyOwner);
            vm.startPrank(mainnetProxyOwner);
        } else {
            uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
            address deployer = vm.rememberKey(deployerPrivateKey);
            vm.startBroadcast(deployer);
            console.log("Deploying on Holesky with deployer: %s", deployer);
        }

        proxyAdmin = new ProxyAdmin(); // msg.sender becomes the owner of ProxyAdmin

        deployerAddress = proxyAdmin.owner();
        minAmountToDeposit = 0.0001 ether;

        console.log("ProxyAdmin deployed at: ", address(proxyAdmin));
        console.log("Tentative owner of ProxyAdmin: ", deployerAddress);

        // LRTConfig
        address lrtConfigImplementation = ConfigLib.deployImpl();
        lrtConfig =
            LRTConfig(address(new TransparentUpgradeableProxy(lrtConfigImplementation, address(proxyAdmin), "")));
        console.log("LrtConfig proxy: ", address(lrtConfig));

        // NovETH
        address novETHImplementation = NovETHLib.deployImpl();
        novETH = NovETH(address(new TransparentUpgradeableProxy(novETHImplementation, address(proxyAdmin), "")));
        console.log("NovETH proxy: ", address(novETH));

        // Initialize LRTConfig
        ConfigLib.initialize(lrtConfig, deployerAddress, address(novETH));

        // Initialize NovETH
        NovETHLib.initialize(novETH, lrtConfig);

        // LRTDepositPool
        address lrtDepositPoolImplementation = DepositPoolLib.deployImpl();
        depositPool = LRTDepositPool(
            payable(address(new TransparentUpgradeableProxy(lrtDepositPoolImplementation, address(proxyAdmin), "")))
        );
        console.log("DepositPool proxy: ", address(depositPool));
        DepositPoolLib.initialize(depositPool, lrtConfig);

        // LRTOracle
        address lrtOracleImplementation = OraclesLib.deployLRTOracleImpl();
        lrtOracle =
            LRTOracle(address(new TransparentUpgradeableProxy(lrtOracleImplementation, address(proxyAdmin), "")));
        console.log("LrtOracle proxy: ", address(lrtOracle));
        OraclesLib.initializeLRTOracle(lrtOracle, lrtConfig);

        // ChainlinkPriceOracle
        chainlinkPriceOracleAddress = OraclesLib.deployInitChainlinkOracle(proxyAdmin, lrtConfig);
        ethXPriceOracleAddress = OraclesLib.deployInitEthXPriceOracle(proxyAdmin);
        address ethOracleProxy = OraclesLib.deployInitETHOracle(proxyAdmin);

        // DelegatorNode
        address nodeImpl = NodeDelegatorLib.deployImpl();
        node1 = NodeDelegator(payable(address(new TransparentUpgradeableProxy(nodeImpl, address(proxyAdmin), ""))));
        console.log("Node1 proxy: ", address(node1));
        NodeDelegatorLib.initialize(node1, lrtConfig);

        // LRTWithdrawalManager
        address lrtWithdrawalImplementation = WithdrawalManagerLib.deployImpl();
        withdrawalManger = LRTWithdrawalManager(
            payable(address(new TransparentUpgradeableProxy(lrtWithdrawalImplementation, address(proxyAdmin), "")))
        );
        console.log("WithdrawalManger proxy: ", address(withdrawalManger));
        WithdrawalManagerLib.initialize(withdrawalManger, lrtConfig);

        // LRTConverter
        address lrtConverterImplementation = ConverterLib.deployImpl();
        converter = LRTConverter(
            payable(address(new TransparentUpgradeableProxy(lrtConverterImplementation, address(proxyAdmin), "")))
        );
        console.log("Converter proxy: ", address(converter));
        ConverterLib.initialize(converter, lrtConfig);

        // LRTUnstakingVault
        address lrtUnstakingVaultImplementation = UnstakingVaultLib.deployImpl();
        unstakingVault = LRTUnstakingVault(
            payable(address(new TransparentUpgradeableProxy(lrtUnstakingVaultImplementation, address(proxyAdmin), "")))
        );
        console.log("UnstakingVault proxy: ", address(unstakingVault));
        UnstakingVaultLib.initialize(unstakingVault, lrtConfig);

        // Transfer SSV tokens to the native staking NodeDelegator
        // SSV Faucet https://faucet.ssv.network/
        // IERC20(AddressesHolesky.SSV_TOKEN).transfer(address(node1), 30 ether);

        // Mock aggregators
        stETHPriceFeed = address(new MockPriceAggregator());

        // setup
        _setUpByAdmin();
        _setUpByManager();

        // ETH asset setup
        lrtConfig.addNewSupportedAsset(LRTConstants.ETH_TOKEN, MAX_DEPOSITS);
        lrtOracle.updatePriceOracleFor(LRTConstants.ETH_TOKEN, ethOracleProxy);

        // update prETHPrice
        lrtOracle.updateNovETHPrice();

        proxyAdmin.transferOwnership(AddressesHolesky.PROXY_OWNER);
        console.log("ProxyAdmin ownership transferred to: ", AddressesHolesky.PROXY_OWNER);

        if (isForked) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }
    }
}
