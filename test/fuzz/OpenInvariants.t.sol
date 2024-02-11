// // Invariants aka properties
// // 1. the total supply of DSC should be less than the toal value of collateral
// // 2. Getter view functions should never reverts or modifies state

// // SPDX-LICENSE-Identifier: MIT

// pragma solidity ^0.8.18;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDsc} from "../../script/DeployDsc.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDsc deployer;
//     DSCEngine engine;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDsc();
//         (dsc, engine, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(engine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt (dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));
//         uint256 wEthValue = engine.getUsdValue(weth, totalWethDeposited);
//         uint256 wBtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);
//         console.log("wEthValue: ", wEthValue);
//         console.log("wBtcValue: ", wBtcValue);
//         console.log("totalSupply: ", totalSupply);
//         assert(wEthValue + wBtcValue >= totalSupply);
//     }
// }
