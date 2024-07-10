# LRT-novETH

## Setup

1. Install dependencies

```bash
npm install

forge install
```

2. copy .env.example to .env and fill in the values

```bash
cp .env.example .env
```

## Usage

This is a list of the most frequently needed commands.

### Clean

Delete the build artifacts and cache directories:

```sh
$ forge clean
```

### Compile

Compile the contracts:

```sh
$ forge build
```

### Coverage

Get a test coverage report:

```sh
$ forge coverage
```

### Deploy

# Deploy to Holesky:

```bash
source .env
forge script script/foundry-scripts/holesky/DeployAll.s.sol:DeployAll --rpc-url $HOLESKY_RPC_URL --broadcast --verify -vvvv
```
# Add assets to Holesky:
```bash
source .env
forge script script/foundry-scripts/holesky/AddAsset.s.sol:AddAsset --rpc-url $HOLESKY_RPC_URL --broadcast
```

# Deploy LRTWithDrawalManager Impl:
```bash
source .env
forge script script/foundry-scripts/holesky/UpdateWManager.s.sol:UpdateWManager --rpc-url $HOLESKY_RPC_URL --broadcast --verify -vvvv
```

### Format

Format the contracts:

```sh
$ forge fmt
```

### Gas Usage

Get a gas report:

```sh
$ forge test --gas-report
```

### Lint

Lint the contracts:

```sh
$ npm lint
```

### Test

Run the tests:

```sh
$ forge test
```

Generate test coverage and output result to the terminal:

```sh
$ npm test:coverage
```

Generate test coverage with lcov report (you'll have to open the `./coverage/index.html` file in your browser, to do so
simply copy paste the path):

```sh
$ npm test:coverage:report
```

# Deployed Contracts

## Holesky testnet

| Contract Name           | Address                                       |
|-------------------------|------------------------------------------------|
| ProxyAdmin              | 0x3341fA63353829f7B0C6dc0CFa45FcE1D50Ab786     |
| ProxyAdmin Owner        | 0x033722102c16389db325Bd7281250592C15e37dd     |

### Contract Implementations
| Contract Name           | Implementation Address                         |
|-------------------------|------------------------------------------------|
| LRTConfig               | 0xeaFd44D94817483002c2a1Bd52741232534ffca6     |
| NovETH                  | 0x5BF33ee8250c61B5cd3190056c278B12A9ebD28f     |
| LRTDepositPool          | 0x37060EB6161de9a8E7a61d8aec7A550C45845240     |
| LRTOracle               | 0x98eCF2A44591796169F3C1BA41927f242C9e49e9     |
| ChainlinkPriceOracle    | 0xaE81aBe374B219C90D1671AeAe570c488804455B     |
| EthXPriceOracle         | 0x27e2A8E3875A2483D5ab5D1B77d41599434d72b1     |
| OneETHPriceOracle       | 0x9192CF16Ab0611334e38cE7ACAc61AcA35098C6a     |
| NodeDelegator           | 0x591140555603c51c636C8E05f13f3b1f13Ee3Ba1     |

### Proxy Addresses
| Contract Name           | Proxy Address                                  |
|-------------------------|------------------------------------------------|
| LRTConfig               | 0xFB937D04dc68609e0385A7496fdEc62d5f23eC14     |
| NovETH                  | 0xc5d3754a2C4d6bEc0065B4358F30016cEe1df719     |
| LRTDepositPool          | 0xb418BDB514A7E0563469c16aAa8288C5A2bB8123     |
| LRTOracle               | 0x969f3D5e7505b38a03Dd5c68f46016601Eea935a     |
| ChainlinkPriceOracle    | 0xF5a7778dA5d0F1e65D5aE0256497a5304252eCCd     |
| EthXPriceOracle         | 0x6e07dAfc75cb74B192cD8F6FBf215BAe5DeAB389     |
| OneETHPriceOracle       | 0x0204c087b18877d298A9A2B51705dc0D2ff7C43B     |

### NodeDelegator Proxy Addresses
- NodeDelegator proxy 1: 0xafC71751B714d999b7037edc9F0012D1A741d3D6

