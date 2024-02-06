// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

/**
 * @title DSCEngine
 * @author Hebx
 * @dev The system engine for the Decentralized Stable Coin and have to maintain a 1token = 1$ peg
 * Exogenous Collateral + Dollar Pegged + Algorithmic Minting & stablecoin
 * This is similar to DAI if DAI had no governance and only backed by WETH & WBTC
 * @notice this contract is the core of DSC System, It handles all the logic of minting and redeeming DSC, as well as depositiing & withdrawing collateral
 * @notice This contract is similar based on the MakerDAO DSS (DAI) system
 * @notice our DSC system must always be overcollateralized
 * at no point should the value of all the collateral be less than the dollar pegged value of all the DSC
 * @dev set a Threshold for liquidation to avoid the system from being undercollateralized
 * @dev if someone pays back the minted DSC of a liquidated, they get the locked collateral for a discount
 */

contract DSCEngine {
    ///////////////
    // Errors  //
    //////////////
    error DSCEngine_MustBeMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustMatch();

    /////////////////////
    // State Variables  //
    /////////////////////

    mapping(address token => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private i_dsc;

    /////////////////
    // Modifiers  //
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_MustBeMoreThanZero();
        }
        _;
    }

    // modifier isAllowedToken(address token) {

    // }

    /////////////////
    // Functions  //
    ////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
    }

    ///////////////////////
    // External Function //
    //////////////////////

    /**
     * @dev deposit collateral to mint DSC
     * @param tokenCollateralAddress the address of the collateral token
     * @param amountCollateral the amount of the collateral to deposit
     */

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) external moreThanZero(amountCollateral) {}

    function depositCollateralAndMintDsc() external {}

    function redeemCollateral() external {}

    function redeemCollateralForDsc() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
