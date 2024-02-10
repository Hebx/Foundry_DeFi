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
    error DSCEngine__MINT_FAILED();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

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
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    /////////////////
    // Events  //
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

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
        public
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
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MINT_FAILED();
        }
    }

    /**
     *
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
     * @param amountDscToMint the amount of decentralized stable coin to mint
     * @notice deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    // in order to redeem, health factor must be above 1 after collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        // emit CollateralRedeemed(msg.sender, amountCollateral, tokenCollateralAddress);
        // bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        // if (!success) {
        //     revert DSCEngine_TransferFailed();
        // }
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        // s_dscMinted[msg.sender] -= amount;
        // bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        // if (!success) {
        //     revert DSCEngine_TransferFailed();
        // }
        // i_dsc.burn(amount);
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // [GAS AUDIT] Maybe it will never hit this line because of the burn
    }
    /**
     *
     * @param tokenCollateralAddress collateral address to redeem
     * @param amountCollateral amount of collateral to redeem
     * @param amountDscToBurn amount of DSC to burn
     * @notice redeem collateral and burn DSC in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks the health factor
    }
    /**
     * @notice if we start nearing undercollateralization, we need someonoe to liquidate the position
     * @notice 75$ wEth backing 50$ DSC --> liquidatoor pay back 50$ DSC to the protocol and get 75$ wEth so he made 25$ profit
     * @notice incentiviize liquidators to liquidate the position/ bonus for overcollateralization
     * @param collateral the erc20 address to liquidate
     * @param user the user who has broken the health factor, their health factor must be below MIN_HEALTH_FACTOR
     * @param debtToCover the amount of DSC you want to burn to improve the users health factor
     */

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their DSC "debt" and take their collateral ex: LiquidatedUser: $140 ETH, $100 DSC | Liquidator: debtToCover = $100 of DSC == ??? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // We can add features as 10% bonus for liquidators and sweep extra amount into a treasury ...
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        // We must also check the health factor of the liquidator if it got broken after the liquidation
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ////////////////////////////////////
    // Private &Internal  Function //
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

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }
    /**
     * @dev Low Level internal function , do not call unless the function calling it checks the health factor
     */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    ////////////////////////////////////
    // Public View Function //
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
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }
    ///@dev let's say 1 ETH = 1000 USD, the returned value from chainlink will be 1000 * 1e8
    ///@dev we pretend all usd pairs have 8 decimals, we will convert it to 18 decimal for WEI

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * amount * ADDITIONAL_FEED_PRECISION) / PRECISION);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }
}
