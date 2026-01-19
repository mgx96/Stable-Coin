// Layout of Contract:
// license
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Malek Sharabi
 * @notice This is the core contract of the Decentralized Stable Coin system. This contract is responsible for all the logic related to minting and redeeming DSC, as well as maintaining the collateralization ratio of the system.
 * @notice This contract should be the only one allowed to mint and burn DSC tokens.
 * @notice The DSC will be backed by WETH and WBTC in this version of the system.
 * @notice Our DSC system should always be overcollateralized. At no point should the value of all the collateral be less than the circulating supply of DSC.
 */

contract DSCEngine is ReentrancyGuard {
    //errors
    error DSCEngine__InvalidAmount();
    error DSCEngine__AssetAddressesAndPriceFeedAddressesLengthMismatch();
    error DSCEngine__AssetNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__CollateralIsBelowRequiredThreshold(uint256 healthFactor);
    error DSCEngine__HealthFactorIsOverTheRequiredThresholdForLiquidation(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__MintFailed();

    //state variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    mapping(address asset => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address asset => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscMintedAmount) private s_DSCMinted;
    address[] private s_collateralAssets;

    DecentralizedStableCoin private immutable i_dsc;

    //events
    event CollateralDeposited(address indexed user, address indexed asset, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed asset, uint256 amount
    );

    //modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__InvalidAmount();
        }
        _;
    }

    modifier isAllowedAsset(address asset) {
        if (s_priceFeeds[asset] == address(0)) {
            revert DSCEngine__AssetNotAllowed();
        }
        _;
    }

    //functions
    constructor(address[] memory assetAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (assetAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__AssetAddressesAndPriceFeedAddressesLengthMismatch();
        }
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            s_priceFeeds[assetAddresses[i]] = priceFeedAddresses[i];
            s_collateralAssets.push(assetAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //external functions
    function depositCollateralAndMintDSC(address collateralAddress, uint256 collateralAmount, uint256 dscAmountToMint)
        external
    {
        depositCollateral(collateralAddress, collateralAmount);
        mintDSC(dscAmountToMint);
    }

    function depositCollateral(address collateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedAsset(collateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralAddress, collateralAmount);
        bool success = IERC20(collateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSC(address collateralAddress, uint256 collateralAmount, uint256 dscAmountToBurn)
        external
    {
        burnDSC(dscAmountToBurn);
        redeemCollateral(collateralAddress, collateralAmount);
    }

    function redeemCollateral(address collateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(collateralAddress, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDSC(uint256 dscAmountToMint) public moreThanZero(dscAmountToMint) nonReentrant {
        s_DSCMinted[msg.sender] += dscAmountToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOverTheRequiredThresholdForLiquidation(startingUserHealthFactor);
        }
        uint256 assetAmountFromDebtCovered = getAssetAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (assetAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = assetAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //private and internal functions
    function _burnDSC(uint256 amount, address onBehalfOf, address dscFrom) internal {
        s_DSCMinted[onBehalfOf] -= amount;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    function _redeemCollateral(address collateralAddress, uint256 collateralAmount, address from, address to) private {
        s_collateralDeposited[from][collateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, collateralAddress, collateralAmount);
        bool success = IERC20(collateralAddress).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        if (s_DSCMinted[user] == 0) {
            return type(uint256).max;
        }
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__CollateralIsBelowRequiredThreshold(userHealthFactor);
        }
    }

    //public and external functions
    function getAssetAmountFromUsd(address asset, uint256 usdAmount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[asset]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmount * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUSD) {
        for (uint256 i = 0; i < s_collateralAssets.length; i++) {
            address asset = s_collateralAssets[i];
            uint256 amount = s_collateralDeposited[user][asset];
            totalCollateralValueInUSD += getUsdValue(asset, amount);
        }
        return totalCollateralValueInUSD;
    }

    function getUsdValue(address asset, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[asset]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        (totalDSCMinted, collateralValueInUSD) = _getAccountInformation(user);
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getDecimalPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralAssets() external view returns (address[] memory) {
        return s_collateralAssets;
    }

    function getCollateralBalanceOfUser(address asset, address user) external view returns (uint256) {
        return s_collateralDeposited[user][asset];
    }

    function getCollateralAssetPriceFeed(address asset) external view returns (address) {
        return s_priceFeeds[asset];
    }
}
