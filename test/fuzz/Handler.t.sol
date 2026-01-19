//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timesMintIsCalled;
    address[] public usersWithDepositedCollateral;
    MockV3Aggregator ethUsdPriceFeed;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralAssets = engine.getCollateralAssets();
        weth = ERC20Mock(collateralAssets[0]);
        wbtc = ERC20Mock(collateralAssets[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralAssetPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(engine), collateralAmount);
        engine.depositCollateral(address(collateral), collateralAmount);
        vm.stopPrank();

        usersWithDepositedCollateral.push(msg.sender);
    }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function mintDsc(uint256 dscAmount, uint256 addressSeed) public {
        if (usersWithDepositedCollateral.length == 0) {
            return;
        }
        address sender = usersWithDepositedCollateral[addressSeed % usersWithDepositedCollateral.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd / 2)) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        dscAmount = bound(dscAmount, 0, uint256(maxDscToMint));
        if (dscAmount == 0) {
            return;
        }
        vm.startPrank(sender);
        engine.mintDSC(dscAmount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxAmountToRedeem = engine.getCollateralBalanceOfUser(address(collateral), msg.sender);

        collateralAmount = bound(collateralAmount, 0, maxAmountToRedeem);
        if (collateralAmount == 0) {
            return;
        }

        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
    }

    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }
}
