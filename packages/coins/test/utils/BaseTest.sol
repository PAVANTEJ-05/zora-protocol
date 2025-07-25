// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IZoraFactory} from "../../src/interfaces/IZoraFactory.sol";
import {ZoraFactoryImpl} from "../../src/ZoraFactoryImpl.sol";
import {ZoraFactory} from "../../src/proxy/ZoraFactory.sol";
import {Coin} from "../../src/Coin.sol";
import {CoinV4} from "../../src/CoinV4.sol";
import {MultiOwnable} from "../../src/utils/MultiOwnable.sol";
import {ICoin} from "../../src/interfaces/ICoin.sol";
import {IERC7572} from "../../src/interfaces/IERC7572.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IAirlock} from "../../src/interfaces/IAirlock.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "../../src/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {IProtocolRewards} from "../../src/interfaces/IProtocolRewards.sol";
import {ProtocolRewards} from "../utils/ProtocolRewards.sol";
import {MarketConstants} from "../../src/libs/MarketConstants.sol";
import {CoinConfigurationVersions} from "../../src/libs/CoinConfigurationVersions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ContentCoinHook} from "../../src/hooks/ContentCoinHook.sol";
import {HooksDeployment} from "../../src/libs/HooksDeployment.sol";
import {CoinConstants} from "../../src/libs/CoinConstants.sol";
import {ProxyShim} from "./ProxyShim.sol";
import {ICoinV4} from "../../src/interfaces/ICoinV4.sol";
import {UniV4SwapHelper} from "../../src/libs/UniV4SwapHelper.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CreatorCoin} from "../../src/CreatorCoin.sol";
import {CreatorCoinHook} from "../../src/hooks/CreatorCoinHook.sol";
import {ContractAddresses} from "./ContractAddresses.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookUpgradeGate} from "../../src/hooks/HookUpgradeGate.sol";

contract BaseTest is Test, ContractAddresses {
    using stdStorage for StdStorage;

    int24 internal constant USDC_TICK_LOWER = 57200;

    struct Users {
        address factoryOwner;
        address feeRecipient;
        address creator;
        address platformReferrer;
        address buyer;
        address seller;
        address coinRecipient;
        address tradeReferrer;
    }

    uint256 internal forkId;
    IERC20Metadata internal zoraToken;
    IERC20Metadata internal usdc;
    IWETH internal weth;

    ProtocolRewards internal protocolRewards;
    IUniswapV3Factory internal v3Factory;
    INonfungiblePositionManager internal nonfungiblePositionManager;
    IPermit2 internal permit2;
    IUniversalRouter internal router;
    IPoolManager internal poolManager;
    IV4Quoter internal quoter;
    CoinV4 internal coinV4;

    ISwapRouter internal swapRouter;
    IAirlock internal airlock;
    Users internal users;

    Coin internal coinV3Impl;
    CoinV4 internal coinV4Impl;
    CreatorCoin internal creatorCoinImpl;
    ZoraFactoryImpl internal factoryImpl;
    IZoraFactory internal factory;
    ContentCoinHook internal contentCoinHook;
    CreatorCoinHook internal creatorCoinHook;
    HookUpgradeGate internal hookUpgradeGate;
    Coin internal coin;

    IUniswapV3Pool internal pool;
    int24 internal constant DEFAULT_DISCOVERY_TICK_LOWER = CoinConstants.DEFAULT_DISCOVERY_TICK_LOWER;
    int24 internal constant DEFAULT_DISCOVERY_TICK_UPPER = CoinConstants.DEFAULT_DISCOVERY_TICK_UPPER;
    uint16 internal constant DEFAULT_NUM_DISCOVERY_POSITIONS = CoinConstants.DEFAULT_NUM_DISCOVERY_POSITIONS;
    uint256 internal constant DEFAULT_DISCOVERY_SUPPLY_SHARE = CoinConstants.DEFAULT_DISCOVERY_SUPPLY_SHARE;

    function _deployCoin() internal {
        bytes memory poolConfig_ = _generatePoolConfig(
            CoinConfigurationVersions.DOPPLER_UNI_V3_POOL_VERSION,
            address(weth),
            DEFAULT_DISCOVERY_TICK_LOWER,
            DEFAULT_DISCOVERY_TICK_UPPER,
            DEFAULT_NUM_DISCOVERY_POSITIONS,
            DEFAULT_DISCOVERY_SUPPLY_SHARE
        );
        vm.prank(users.creator);
        (address coinAddress, ) = factory.deploy(
            users.creator,
            _getDefaultOwners(),
            "https://test.com",
            "Testcoin",
            "TEST",
            poolConfig_,
            users.platformReferrer,
            0
        );

        coin = Coin(payable(coinAddress));
        pool = IUniswapV3Pool(coin.poolAddress());

        vm.label(address(coin), "COIN");
        vm.label(address(pool), "POOL");
    }

    function _defaultPoolConfig(address currency) internal pure returns (bytes memory) {
        return CoinConfigurationVersions.defaultDopplerMultiCurveUniV4(currency);
    }

    function _deployV4Coin(address currency) internal returns (ICoinV4) {
        bytes32 salt = keccak256(abi.encode(bytes("randomSalt")));
        return _deployV4Coin(currency, address(0), salt);
    }

    string constant DEFAULT_NAME = "Testcoin";
    string constant DEFAULT_SYMBOL = "TEST";

    function _deployV4Coin(address currency, address createReferral, bytes32 salt) internal returns (ICoinV4) {
        address[] memory owners = new address[](1);
        owners[0] = users.creator;

        bytes memory poolConfig = _defaultPoolConfig(currency);

        vm.prank(users.creator);
        (address coinAddress, ) = factory.deploy(
            users.creator,
            owners,
            "https://test.com",
            DEFAULT_NAME,
            DEFAULT_SYMBOL,
            poolConfig,
            createReferral,
            address(0),
            bytes(""),
            salt
        );

        coinV4 = CoinV4(payable(coinAddress));
        return coinV4;
    }

    function _deployCoinUSDCPair() internal {
        bytes memory poolConfig_ = _generatePoolConfig(
            CoinConfigurationVersions.DOPPLER_UNI_V3_POOL_VERSION,
            USDC_ADDRESS,
            DEFAULT_DISCOVERY_TICK_LOWER,
            DEFAULT_DISCOVERY_TICK_UPPER,
            DEFAULT_NUM_DISCOVERY_POSITIONS,
            DEFAULT_DISCOVERY_SUPPLY_SHARE
        );
        vm.prank(users.creator);
        (address coinAddress, ) = factory.deploy(
            users.creator,
            _getDefaultOwners(),
            "https://test.com",
            "Testcoin",
            "TEST",
            poolConfig_,
            users.platformReferrer,
            0
        );

        coin = Coin(payable(coinAddress));
        pool = IUniswapV3Pool(coin.poolAddress());

        vm.label(address(coin), "COIN");
        vm.label(address(pool), "POOL");
    }

    function _swapSomeCurrencyForCoin(ICoinV4 _coin, address currency, uint128 amountIn, address trader) internal {
        _swapSomeCurrencyForCoin(_coin.getPoolKey(), _coin, currency, amountIn, trader);
    }

    function _swapSomeCurrencyForCoin(PoolKey memory poolKey, ICoinV4 _coin, address currency, uint128 amountIn, address trader) internal {
        uint128 minAmountOut = uint128(0);

        (bytes memory commands, bytes[] memory inputs) = UniV4SwapHelper.buildExactInputSingleSwapCommand(
            currency,
            amountIn,
            address(_coin),
            minAmountOut,
            poolKey,
            bytes("")
        );

        vm.startPrank(trader);
        UniV4SwapHelper.approveTokenWithPermit2(permit2, address(router), currency, amountIn, uint48(block.timestamp + 1 days));

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);

        vm.stopPrank();
    }

    function _swapSomeCoinForCurrency(ICoinV4 _coin, address currency, uint128 amountIn, address trader) internal {
        uint128 minAmountOut = uint128(0);

        (bytes memory commands, bytes[] memory inputs) = UniV4SwapHelper.buildExactInputSingleSwapCommand(
            address(_coin),
            amountIn,
            currency,
            minAmountOut,
            _coin.getPoolKey(),
            bytes("")
        );

        vm.startPrank(trader);
        UniV4SwapHelper.approveTokenWithPermit2(permit2, address(router), address(_coin), amountIn, uint48(block.timestamp + 1 days));

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);

        vm.stopPrank();
    }

    function _deployFeeEstimatorHook(uint256 initialSupplyForPositions, address hooks) internal {
        deployCodeTo("FeeEstimatorHook.sol", abi.encode(V4_POOL_MANAGER, address(factory), hookUpgradeGate, initialSupplyForPositions), hooks);
    }

    function getSalts(address[] memory trustedMessageSenders) public returns (bytes32 contentCoinSalt, bytes32 creatorCoinSalt) {
        address deployer = address(this);

        (, contentCoinSalt) = HooksDeployment.mineForContentCoinSalt(
            deployer,
            V4_POOL_MANAGER,
            address(factory),
            trustedMessageSenders,
            address(hookUpgradeGate)
        );

        (, creatorCoinSalt) = HooksDeployment.mineForCreatorCoinSalt(
            deployer,
            V4_POOL_MANAGER,
            address(factory),
            trustedMessageSenders,
            address(hookUpgradeGate)
        );
    }

    function _deployHooks() internal {
        address[] memory trustedMessageSenders = new address[](2);
        trustedMessageSenders[0] = UNIVERSAL_ROUTER;
        trustedMessageSenders[1] = V4_POSITION_MANAGER;

        (bytes32 contentCoinSalt, bytes32 creatorCoinSalt) = getSalts(trustedMessageSenders);

        contentCoinHook = ContentCoinHook(
            address(
                HooksDeployment.deployHookWithSalt(
                    HooksDeployment.contentCoinCreationCode(V4_POOL_MANAGER, address(factory), trustedMessageSenders, address(hookUpgradeGate)),
                    contentCoinSalt
                )
            )
        );
        creatorCoinHook = CreatorCoinHook(
            address(
                HooksDeployment.deployHookWithSalt(
                    HooksDeployment.creatorCoinHookCreationCode(V4_POOL_MANAGER, address(factory), trustedMessageSenders, address(hookUpgradeGate)),
                    creatorCoinSalt
                )
            )
        );
    }

    function setUp() public virtual {
        setUpWithBlockNumber(28415528);
    }

    function setUpWithBlockNumber(uint256 forkBlockNumber) public {
        forkId = vm.createSelectFork("base", forkBlockNumber);

        weth = IWETH(WETH_ADDRESS);
        usdc = IERC20Metadata(USDC_ADDRESS);
        zoraToken = IERC20Metadata(ZORA_TOKEN_ADDRESS);
        v3Factory = IUniswapV3Factory(V3_FACTORY);
        nonfungiblePositionManager = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER);
        swapRouter = ISwapRouter(SWAP_ROUTER);
        airlock = IAirlock(DOPPLER_AIRLOCK);
        protocolRewards = new ProtocolRewards();
        permit2 = IPermit2(V4_PERMIT2);
        router = IUniversalRouter(UNIVERSAL_ROUTER);
        poolManager = IPoolManager(V4_POOL_MANAGER);
        quoter = IV4Quoter(V4_QUOTER);
        users = Users({
            factoryOwner: makeAddr("factoryOwner"),
            feeRecipient: makeAddr("feeRecipient"),
            creator: makeAddr("creator"),
            platformReferrer: makeAddr("platformReferrer"),
            buyer: makeAddr("buyer"),
            seller: makeAddr("seller"),
            coinRecipient: makeAddr("coinRecipient"),
            tradeReferrer: makeAddr("tradeReferrer")
        });

        ProxyShim mockUpgradeableImpl = new ProxyShim();
        factory = IZoraFactory(address(new ZoraFactory(address(mockUpgradeableImpl))));
        coinV3Impl = new Coin(users.feeRecipient, address(protocolRewards), WETH_ADDRESS, V3_FACTORY, SWAP_ROUTER, DOPPLER_AIRLOCK);

        hookUpgradeGate = new HookUpgradeGate(users.factoryOwner);

        _deployHooks();

        coinV4Impl = new CoinV4(users.feeRecipient, address(protocolRewards), IPoolManager(V4_POOL_MANAGER), DOPPLER_AIRLOCK);

        creatorCoinImpl = new CreatorCoin(users.feeRecipient, address(protocolRewards), IPoolManager(V4_POOL_MANAGER), DOPPLER_AIRLOCK);

        factoryImpl = new ZoraFactoryImpl(
            address(coinV3Impl),
            address(coinV4Impl),
            address(creatorCoinImpl),
            address(contentCoinHook),
            address(creatorCoinHook)
        );
        UUPSUpgradeable(address(factory)).upgradeToAndCall(address(factoryImpl), "");
        factory = IZoraFactory(address(factory));

        ZoraFactoryImpl(address(factory)).initialize(users.factoryOwner);

        vm.label(address(factory), "ZORA_FACTORY");
        vm.label(address(protocolRewards), "PROTOCOL_REWARDS");
        vm.label(address(nonfungiblePositionManager), "NONFUNGIBLE_POSITION_MANAGER");
        vm.label(address(v3Factory), "V3_FACTORY");
        vm.label(address(swapRouter), "SWAP_ROUTER");
        vm.label(address(weth), "WETH");
        vm.label(address(usdc), "USDC");
        vm.label(address(airlock), "AIRLOCK");
        vm.label(address(zoraToken), "$ZORA");
        vm.label(address(V4_POOL_MANAGER), "V4_POOL_MANAGER");
        vm.label(address(V4_POSITION_MANAGER), "V4_POSITION_MANAGER");
        vm.label(address(V4_QUOTER), "V4_QUOTER");
        vm.label(address(V4_PERMIT2), "V4_PERMIT2");
        vm.label(address(UNIVERSAL_ROUTER), "UNIVERSAL_ROUTER");
        vm.label(address(creatorCoinHook), "CREATOR_COIN_HOOK");
    }

    struct TradeRewards {
        uint256 creator;
        uint256 platformReferrer;
        uint256 tradeReferrer;
        uint256 protocol;
    }

    struct MarketRewards {
        uint256 creator;
        uint256 platformReferrer;
        uint256 doppler;
        uint256 protocol;
    }

    function _calculateTradeRewards(uint256 ethAmount) internal pure returns (TradeRewards memory) {
        return
            TradeRewards({
                creator: (ethAmount * 5000) / 10_000,
                platformReferrer: (ethAmount * 1500) / 10_000,
                tradeReferrer: (ethAmount * 1500) / 10_000,
                protocol: (ethAmount * 2000) / 10_000
            });
    }

    function _calculateExpectedFee(uint256 ethAmount) internal pure returns (uint256) {
        uint256 feeBps = 100; // 1%
        return (ethAmount * feeBps) / 10_000;
    }

    function _calculateMarketRewards(uint256 ethAmount) internal pure returns (MarketRewards memory) {
        uint256 creator = (ethAmount * 5000) / 10_000;
        uint256 platformReferrer = (ethAmount * 2500) / 10_000;
        uint256 doppler = (ethAmount * 500) / 10_000;
        uint256 protocol = ethAmount - creator - platformReferrer - doppler;

        return MarketRewards({creator: creator, platformReferrer: platformReferrer, doppler: doppler, protocol: protocol});
    }

    function dealUSDC(address to, uint256 numUSDC) internal returns (uint256) {
        uint256 amount = numUSDC * 1e6;
        deal(address(usdc), to, amount);
        return amount;
    }

    function _getDefaultOwners() internal view returns (address[] memory owners) {
        owners = new address[](1);
        owners[0] = users.creator;
    }

    function dopplerFeeRecipient() internal view returns (address) {
        return airlock.owner();
    }

    function _generatePoolConfig(address currency_) internal pure returns (bytes memory) {
        return
            _generatePoolConfig(
                CoinConfigurationVersions.DOPPLER_UNI_V3_POOL_VERSION,
                currency_,
                DEFAULT_DISCOVERY_TICK_LOWER,
                DEFAULT_DISCOVERY_TICK_UPPER,
                DEFAULT_NUM_DISCOVERY_POSITIONS,
                DEFAULT_DISCOVERY_SUPPLY_SHARE
            );
    }

    function _generatePoolConfig(
        uint8 version_,
        address currency_,
        int24 tickLower_,
        int24 tickUpper_,
        uint16 numDiscoveryPositions_,
        uint256 maxDiscoverySupplyShare_
    ) internal pure returns (bytes memory) {
        return abi.encode(version_, currency_, tickLower_, tickUpper_, numDiscoveryPositions_, maxDiscoverySupplyShare_);
    }
}
