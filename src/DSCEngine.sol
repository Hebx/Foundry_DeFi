// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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
contract DSCEngine is ReentrancyGuard {
    ///////////////
    // Errors  //
    //////////////
    error DSCEngine_MustBeMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustMatch();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor);

    /////////////////////
    // State Variables  //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% collateralization
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    /////////////////
    // Events  //
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /////////////////
    // Modifiers  //
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    /////////////////
    // Functions  //
    ////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////
    // External Function //
    //////////////////////

    /**
     * @notice Follow CEI
     * @dev deposit collateral to mint DSC
     * @param tokenCollateralAddress the address of the collateral token
     * @param amountCollateral the amount of the collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /**
     * @notice check if the collateral value > DSC value / minimum threshold
     * @notice Must revert if the Health Factor is broken
     * @param amountDscToMint the amount of DSC to mint
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) {
        s_dscMinted[msg.sender] += amountDscToMint;
    }

    function depositCollateralAndMintDsc() external {}

    function redeemCollateral() external {}

    function redeemCollateralForDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    ////////////////////////////////////
    // Private &Internal View Function //
    ///////////////////////////////////
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice returns how close to liquidation the user is
     * @notice if a user goes below 1, then they get liquidated
     * @param user the address of the user to check
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    /**
     * @notice do they have enough collateral
     * @notice set a threshold
     * @param user the address of the user to check
     */

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(userHealthFactor);
        }
    }

    ////////////////////////////////////
    // Private &Internal View Function //
    ///////////////////////////////////
    /**
     * @param user the address of the user to check
     * @notice loop through all the collateral tokens and get the amount they have deposited
     * @notice map it to the price to get the usd value
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }
    ///@dev let's say 1 ETH = 1000 USD, the returned value from chainlink will be 1000 * 1e8
    ///@dev we pretend all usd pairs have 8 decimals, we will convert it to 18 decimal for WEI

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * amount * ADDITIONAL_FEED_PRECISION) / PRECISION);
    }
}
