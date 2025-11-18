//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address btc;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, btc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    address[] public assetAddress;
    address[] public priceFeedAddress;

    function testRevertIfAssetLengthDoesNotMatchPriceFeedLength() public {
        assetAddress.push(weth);
        priceFeedAddress.push(ethUsdPriceFeed);
        priceFeedAddress.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__AssetAddressesAndPriceFeedAddressesLengthMismatch.selector);
        new DSCEngine(assetAddress, priceFeedAddress, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 52500e18; // 15 ETH * $3500(ETH/USD price)
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assert(expectedUsd == actualUsd);
    }

    function testGetAssetAmountFromUsd() public view {
        uint256 usdAmount = 52500 ether;
        uint256 expectedEth = 15 ether; // $52500 / $3500(ETH/USD price)
        uint256 actualEth = engine.getAssetAmountFromUsd(weth, usdAmount);
        assert(expectedEth == actualEth);
    }

    /*//////////////////////////////////////////////////////////////
                            COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__InvalidAmount.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock unapprovedCollateral = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AssetNotAllowed.selector);
        engine.depositCollateral(address(unapprovedCollateral), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = engine.getAssetAmountFromUsd(weth, collateralValueInUSD);
        uint256 expectedDSCMinted = 0;
        assertEq(expectedDSCMinted, totalDSCMinted);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function testDepositCollateralAndMintDSC() public {
        uint256 amountToMint = 5000e18;
        uint256 collateralToDeposit = 10 ether;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), collateralToDeposit);
        engine.depositCollateralAndMintDSC(weth, collateralToDeposit, amountToMint);
        vm.stopPrank();

        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = engine.getAssetAmountFromUsd(weth, collateralValueInUSD);
        expectedDepositedAmount = collateralToDeposit;
        uint256 expectedDSCMinted = amountToMint;
        assertEq(expectedDSCMinted, totalDSCMinted);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function testCorrectHealthFactorAfterDepositWithNoMinting() public depositCollateral {
        uint256 actualHealthFactor = engine.getHealthFactor(USER);
        assertEq(actualHealthFactor, type(uint256).max);
    }

    function testCorrectHealthFactorAfterDepositAndMinting() public depositCollateral {
        uint256 amountToMint = 5000e18;
        vm.startPrank(USER);
        engine.mintDSC(amountToMint);
        vm.stopPrank();
        uint256 actualHealthFactor = engine.getHealthFactor(USER);
        // collateral: 10 ETH * $3500 = $35000
        // minted = $5000
        // health factor = (35000 * 0.50) / 5000  = 3.5e18
        uint256 expectedHealthFactor = (35000e18 * engine.getLiquidationThreshold()) / engine.getLiquidationPrecision();
        expectedHealthFactor = (expectedHealthFactor * engine.getDecimalPrecision()) / amountToMint;
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testLiquidateFunctionWorksWhenHealthFactorIsBroken() public depositCollateral {
        uint256 amountToMint = 10000e18; // $10,000 DSC

        // 1. USER mints DSC and becomes undercollateralized (HF < 1e18)
        vm.startPrank(USER);
        engine.mintDSC(amountToMint);
        vm.stopPrank();

        // 2. Manipulate price feed to push HF below threshold
        // If ETH usd price = 3500e8 originally, cut it in half
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1500e8);

        uint256 userHFBef = engine.getHealthFactor(USER);
        uint256 one = 1e18; // 1.0 is the liquidation threshold
        assertLt(userHFBef, one); // sanity: user is liquidatable

        // 2. Setup a real liquidator
        address LIQUIDATOR = makeAddr("LIQUIDATOR");

        // USER gives DSC to LIQUIDATOR so they can repay the debt
        vm.startPrank(USER);
        dsc.transfer(LIQUIDATOR, amountToMint);
        vm.stopPrank();

        // LIQUIDATOR approves engine to pull DSC
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), amountToMint);

        // 3. Snapshot USER state before liquidation
        (uint256 dscMintedBefore, uint256 collateralBefore) = engine.getAccountInformation(USER);
        assertEq(dscMintedBefore, amountToMint); // sanity

        // 4. Perform liquidation: liquidator repays all of USER's debt
        engine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();

        // 5. Check USER state after liquidation
        (uint256 dscMintedAfter, uint256 collateralAfter) = engine.getAccountInformation(USER);

        // Debt fully cleared
        assertEq(dscMintedAfter, 0);

        // Collateral reduced, but NOT zero (because only 20k + 10% bonus worth was seized)
        assertLt(collateralAfter, collateralBefore);
        assertGt(collateralAfter, 0);
        console.log("Collateral Value Before Liquidation: ", collateralBefore);
        console.log("Collateral Value After Liquidation: ", collateralAfter);

        // Health factor must have improved (in the engine, it will be max since debt = 0)
        uint256 userHFAfter = engine.getHealthFactor(USER);
        assertGt(userHFAfter, userHFBef);
        assertEq(userHFAfter, type(uint256).max);
        console.log("User Health Factor Before Liquidation: ", userHFBef);
        console.log("User Health Factor After Liquidation: ", userHFAfter);

        uint256 liquidatorWethBalance = IERC20(weth).balanceOf(LIQUIDATOR);
        assertGt(liquidatorWethBalance, 0); // they got some collateral + bonus
    }

    function testLiquidateRevertsIfHealthFactorIsHealthy() public depositCollateral {
        uint256 amountToMint = 5000e18;
        vm.startPrank(USER);
        engine.mintDSC(amountToMint);
        vm.stopPrank();

        uint256 userHF = engine.getHealthFactor(USER);
        uint256 one = 1e18; // 1.0 is the liquidation threshold
        assertGt(userHF, one); // sanity: user is healthy

        address LIQUIDATOR = makeAddr("LIQUIDATOR");

        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__HealthFactorIsOverTheRequiredThresholdForLiquidation.selector, userHF
            )
        );
        engine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    function testRedeemCollateral() public depositCollateral {
        uint256 collateralToRedeem = 5 ether;
        vm.startPrank(USER);
        engine.redeemCollateral(weth, collateralToRedeem);
        vm.stopPrank();

        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = engine.getAssetAmountFromUsd(weth, collateralValueInUSD);
        uint256 expectedDSCMinted = 0;
        assertEq(expectedDSCMinted, totalDSCMinted);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL - collateralToRedeem);
    }

    function testRedeemCollateralForDSC() public depositCollateral {
        uint256 amountToMint = 5000e18;
        uint256 collateralToRedeem = 6 ether;
        vm.startPrank(USER);
        engine.mintDSC(amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.redeemCollateralForDSC(weth, collateralToRedeem, amountToMint);
        vm.stopPrank();

        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = engine.getAssetAmountFromUsd(weth, collateralValueInUSD);
        uint256 expectedDSCMinted = 0;
        assertEq(expectedDSCMinted, totalDSCMinted);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL - collateralToRedeem);
    }

    function testMintDSC() public depositCollateral {
        uint256 amountToMint = 5000e18;
        vm.startPrank(USER);
        engine.mintDSC(amountToMint);
        vm.stopPrank();

        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = engine.getAssetAmountFromUsd(weth, collateralValueInUSD);
        uint256 expectedDSCMinted = amountToMint;
        assertEq(expectedDSCMinted, totalDSCMinted);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function testBurnDSC() public depositCollateral {
        uint256 amountToMint = 5000e18;
        vm.startPrank(USER);
        engine.mintDSC(amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.burnDSC(amountToMint);
        vm.stopPrank();

        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = engine.getAssetAmountFromUsd(weth, collateralValueInUSD);
        uint256 expectedDSCMinted = 0;
        assertEq(expectedDSCMinted, totalDSCMinted);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public depositCollateral {
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(expectedValue, collateralValue);
    }

    //doesn't increase coverage
    function testGetAccountInformation() public depositCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(expectedCollateralValue, collateralValueInUSD);
        assertEq(0, totalDSCMinted);
    }

    function testGetHealthFactor() public depositCollateral {
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(type(uint256).max, healthFactor);
    }
}
