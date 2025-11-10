//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Vm} from "forge-std/Vm.sol";
import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {}

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcUsdPriceFeed: 0xA39434A63A52E749F02807ae27335515BA4b07F7,
            weth: 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6,
            wbtc: 0x577D296678535e4903D59A4C929B718e1D575e0A,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }
    }
}
