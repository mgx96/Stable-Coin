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
    error DSCEngine__CollateralIsBelowRequiredThreshold();

    //state variables
    mapping(address asset => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address asset => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscMintedAmount) private s_DSCMinted;
    DecentralizedStableCoin private immutable i_dsc;

    //events
    event CollateralDeposited(address indexed user, address indexed asset, uint256 indexed amount);

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
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }
    //external functions
    function depositCollateralAndMintDSC() external {}

    function depositCollateral(address collateralAddress, uint256 collateralAmount)
        external
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

    function redeemCollateralForDSC() external {}

    function redeemCollateral() external {}

    function mintDSC(uint256 dscAmountToMint) external moreThanZero(dscAmountToMint) nonReentrant {
        s_DSCMinted[msg.sender] += dscAmountToMint;
    }

    function burnDSC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    //private and internal functions
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
    }
    function _revertIfHealthFactorIsBroken() internal view {}
    //public and external functions
    function getAccountCollateralValue(address user) public view returns (uint256) {}
}
