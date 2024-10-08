// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "./interfaces/IUSSDRebalancer.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

/**
    @dev rebalancer module for USSD ERC20 token. Performs swaps to return USSD/DAI pool balance 1-to-1
         selling USSD for buying collateral or buying and burning USSD for selling collateral
 */
contract USSDRebalancer is AccessControlUpgradeable, IUSSDRebalancer {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // main USSD/DAI pool
    IUniswapV3Pool public uniPool;

    // USSD token
    address public USSD;

    // boundary to make rebalancing
    //note @paul What is Threshold ? 
    uint256 private threshold;

    // ratios of collateralization for different collateral accumulating
    //note @paul What is flutterRatios ? 
    uint256[] public flutterRatios;
    
    // base asset for other pool leg (DAI)
    //note @paul What is baseAsset ? 
    address private baseAsset;

    // role to perform rebalancer management functions
    bytes32 public constant STABLE_CONTROL_ROLE = keccak256("STABLECONTROL");

    function initialize(address _ussd) public initializer {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

        //note @paul Does it mean that it can rebalance only 0.01 USSD at a time ? as USSD decimals is 6
        threshold = 1e4;
        USSD = _ussd;
    }

    modifier onlyControl() {
        require(hasRole(STABLE_CONTROL_ROLE, msg.sender), "control only");
        _;
    }

    function setPoolAddress(address _pool) public onlyControl {
      uniPool = IUniswapV3Pool(_pool);
    }

    function getPool() public view override returns (address) {
        return address(uniPool);
    }


    function setTreshold(uint256 _threshold) public onlyControl {
      threshold = _threshold;
    }

    function setFlutterRatios(uint256[] calldata _flutterRatios) public onlyControl {
      flutterRatios = _flutterRatios;
    }

    function setBaseAsset(address _baseAsset) public onlyControl {
      baseAsset = _baseAsset;
    }

    /// @dev get price estimation to DAI using pool address and uniswap price
    //audit-issue @correction High Chance of overflow if it enter the "else" statement as SqrtPriceX96 has 96bits for decimals and 1e18 take 60bits, 
    //note to Myself: Needs to get deeper on this issue, not fully understand it but looks interesting. A lot of duplicate so I assume it's a common issue to be aware of.
    // https://github.com/sherlock-audit/2023-05-USSD-judging/issues/79
    // Recommendation : Consider making sure the calculations are performed safely. Potentially converting the sqrtPrice to a 60x18 format and performing arithmetic operations using a library.
    function getOwnValuation() public view returns (uint256 price) {
      (uint160 sqrtPriceX96,,,,,,) =  uniPool.slot0();
      if(uniPool.token0() == USSD) {
        //note @paul need to check the uniswap logic here 
        price = uint(sqrtPriceX96)*(uint(sqrtPriceX96))/(1e6) >> (96 * 2);
      } else {
        price = uint(sqrtPriceX96)*(uint(sqrtPriceX96))*(1e18 /* 1e12 + 1e6 decimal representation */) >> (96 * 2);
        // flip the fraction
        //note @paul Hardcoded values very dangerous of use
        price = (1e24 / price) / 1e12;
      }
    }

    /// @dev return pool balances with USSD first
    //audit-issue @correction Malicious User can transfer USSD or DAI to the pool, changing the return value of "USSDRebalancer.getSupplyProportion();"
    // https://github.com/sherlock-audit/2023-05-USSD-judging/issues/405
    // Recommendation:  Don't use the balanceOf(pool) as reliable data as it can be easily manipulated by anyone -> especially using flashLoans
    function getSupplyProportion() public view returns (uint256, uint256) {
      uint256 vol1 = IERC20Upgradeable(uniPool.token0()).balanceOf(address(uniPool));
      uint256 vol2 = IERC20Upgradeable(uniPool.token1()).balanceOf(address(uniPool));
      if (uniPool.token0() == USSD) {
        return (vol1, vol2);
      }
      return (vol2, vol1);
    }

   
  //audit-issue @correction Assume DAI is 1$ wich isn't alway's the case. 
  // https://github.com/sherlock-audit/2023-05-USSD-judging/issues/714
  // Recommendation : Convert DAI to USD in "getOwnValuation" using Chanlink Oracle
    function rebalance() override public {
      uint256 ownval = getOwnValuation();
      (uint256 USSDamount, uint256 DAIamount) = getSupplyProportion();
      //audit @paul If 1e2 < ownval < 1e10, Nothing happen. Is that Logic or expected ?  
      if (ownval < 1e6 - threshold) {
        // peg-down recovery
        //note @paul What the hell is DAI doing here ? 
        BuyUSSDSellCollateral((USSDamount - DAIamount / 1e12)/2);
      } else if (ownval > 1e6 + threshold) {
        // mint and buy collateral
        // never sell too much USSD for DAI so it 'overshoots' (becomes more in quantity than DAI on the pool)
        // otherwise could be arbitraged through mint/redeem
        // the execution difference due to fee should be taken into accounting too
        // take 1% safety margin (estimated as 2 x 0.5% fee)
        IUSSD(USSD).mintRebalancer(((DAIamount / 1e12 - USSDamount)/2) * 99 / 100); // mint ourselves amount till balance recover
        SellUSSDBuyCollateral();
      }
    }


    //note @paul Those 2 function :SellUSSDBuyCollateral and BuyUSSDSellCollateral SHOULD be symetrical or almost (if including fees). 
    function BuyUSSDSellCollateral(uint256 amountToBuy) internal {
      CollateralInfo[] memory collateral = IUSSD(USSD).collateralList();
      //uint amountToBuyLeftUSD = amountToBuy * 1e12 * 1e6 / getOwnValuation();
      uint amountToBuyLeftUSD = amountToBuy * 1e12;
      uint DAItosell = 0;
      // Sell collateral in order of collateral array
      for (uint256 i = 0; i < collateral.length; i++) {
        uint256 collateralval = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * 1e18 / (10**IERC20MetadataUpgradeable(collateral[i].token).decimals()) * collateral[i].oracle.getPriceUSD() / 1e18;
        if (collateralval > amountToBuyLeftUSD) {
          // sell a portion of collateral and exit
          if (collateral[i].pathsell.length > 0) {
            uint256 amountBefore = IERC20Upgradeable(baseAsset).balanceOf(USSD);
            //audit-issue @correction  Incorrect decimals in amountToSellUnits calculation
            // https://github.com/sherlock-audit/2023-05-USSD-judging/issues/58
            //note to Myself: Get a Bit confuse by decimals -> Need to get deeper on this issue and Decimals in general. 
            //
            
            uint256 amountToSellUnits = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * ((amountToBuyLeftUSD * 1e18 / collateralval) / 1e18) / 1e18;
            IUSSD(USSD).UniV3SwapInput(collateral[i].pathsell, amountToSellUnits);
            amountToBuyLeftUSD -= (IERC20Upgradeable(baseAsset).balanceOf(USSD) - amountBefore);
            DAItosell += (IERC20Upgradeable(baseAsset).balanceOf(USSD) - amountBefore);
          } else {
            // no need to swap DAI
            DAItosell = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * amountToBuyLeftUSD / collateralval;
          }
          break;
        } else {
          // sell all or skip (if collateral is too little, 5% treshold)
          if (collateralval >= amountToBuyLeftUSD / 20) {
            uint256 amountBefore = IERC20Upgradeable(baseAsset).balanceOf(USSD);
            // sell all collateral and move to next one
            IUSSD(USSD).UniV3SwapInput(collateral[i].pathsell, IERC20Upgradeable(collateral[i].token).balanceOf(USSD));
            amountToBuyLeftUSD -= (IERC20Upgradeable(baseAsset).balanceOf(USSD) - amountBefore);
            DAItosell += (IERC20Upgradeable(baseAsset).balanceOf(USSD) - amountBefore);
          }
        }
      }

      // buy USSD (sell DAI) to burn
      // never sell too much DAI so USSD 'overshoots' (becomes less in quantity than DAI on the pool)
      // otherwise could be arbitraged through mint/redeem
      // the remainder (should be small, due to oracle twap lag) to be left as DAI collateral
      // the execution difference due to fee should be taken into accounting too
      // take 1% safety margin (estimated as 2 x 0.5% fee)
      if (DAItosell > amountToBuy * 1e12 * 99 / 100) {
        DAItosell = amountToBuy * 1e12 * 99 / 100;
      }

      if (DAItosell > 0) {
        if (uniPool.token0() == USSD) {
          //note @paul WTF is that ? 
            IUSSD(USSD).UniV3SwapInput(bytes.concat(abi.encodePacked(uniPool.token1(), hex"0001f4", uniPool.token0())), DAItosell);
        } else {
            IUSSD(USSD).UniV3SwapInput(bytes.concat(abi.encodePacked(uniPool.token0(), hex"0001f4", uniPool.token1())), DAItosell);
        }
      }

      IUSSD(USSD).burnRebalancer(IUSSD(USSD).balanceOf(USSD));
    }

    function SellUSSDBuyCollateral() internal {
      uint256 amount = IUSSD(USSD).balanceOf(USSD);
      // sell for DAI then swap by DAI routes
      uint256 daibought = 0;
      if (uniPool.token0() == USSD) {
        daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD);
        IUSSD(USSD).UniV3SwapInput(bytes.concat(abi.encodePacked(uniPool.token0(), hex"0001f4", uniPool.token1())), amount);
        daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD) - daibought; // would revert if not bought
      } else {
        daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD);
        IUSSD(USSD).UniV3SwapInput(bytes.concat(abi.encodePacked(uniPool.token1(), hex"0001f4", uniPool.token0())), amount);
        daibought = IERC20Upgradeable(baseAsset).balanceOf(USSD) - daibought; // would revert if not bought
      }

      // total collateral portions
      uint256 cf = IUSSD(USSD).collateralFactor();
      uint256 flutter = 0;
      for (flutter = 0; flutter < flutterRatios.length; flutter++) {
        if (cf < flutterRatios[flutter]) {
          break;
        }
      }

      CollateralInfo[] memory collateral = IUSSD(USSD).collateralList();
      uint portions = 0;
      uint ownval = (getOwnValuation() * 1e18 / 1e6) * IUSSD(USSD).totalSupply() / 1e6; // 1e18 total USSD value
      for (uint256 i = 0; i < collateral.length; i++) {
        uint256 collateralval = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * 1e18 / (10**IERC20MetadataUpgradeable(collateral[i].token).decimals()) * collateral[i].oracle.getPriceUSD() / 1e18;
        if (collateralval * 1e18 / ownval < collateral[i].ratios[flutter]) {
          portions++;
        }
      }

      for (uint256 i = 0; i < collateral.length; i++) {
        uint256 collateralval = IERC20Upgradeable(collateral[i].token).balanceOf(USSD) * 1e18 / (10**IERC20MetadataUpgradeable(collateral[i].token).decimals()) * collateral[i].oracle.getPriceUSD() / 1e18;
        if (collateralval * 1e18 / ownval < collateral[i].ratios[flutter]) {
          //audit-issue @correction Statement Always true. Intersersting Finding. 20 persons found it so very commong. Mandatory Need to find issue like that. 
          // https://github.com/sherlock-audit/2023-05-USSD-judging/issues/61
          // Recommendation Replace the OR "||" by AND "&&"
          if (collateral[i].token != uniPool.token0() || collateral[i].token != uniPool.token1()) {
            // don't touch DAI if it's needed to be bought (it's already bought)
            IUSSD(USSD).UniV3SwapInput(collateral[i].pathbuy, daibought/portions);
          }
        }
      }
    }
}
