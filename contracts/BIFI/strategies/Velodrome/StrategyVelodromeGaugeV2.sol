// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin-4/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/common/ISolidlyRouter.sol";
import "../../interfaces/common/ISolidlyPair.sol";
import "../../interfaces/common/IVelodromeGauge.sol";
import "../../interfaces/common/IERC20Extended.sol";
import "../../interfaces/beefy/IBeefySwapper.sol";
import "../Common/StratFeeManagerInitializable.sol";

contract StrategyVelodromeGaugeV2 is StratFeeManagerInitializable {
    using SafeERC20 for IERC20;

    // Tokens used
    address public native;
    address public output;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public gauge;
    address public factory;
    address public beefySwapper;

    bool public stable;
    bool public harvestOnDeposit;
    uint256 public lastHarvest;

    ISolidlyRouter.Route[] public outputToNativeRoute;
    ISolidlyRouter.Route[] public outputToLp0Route;
    ISolidlyRouter.Route[] public outputToLp1Route;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event ChargedFees(uint256 callFees, uint256 beefyFees, uint256 strategistFees);
    event SetBeefySwapper(address newSwapper);

    function initialize(
        address _want,
        address _gauge,
        address _beefySwapper,
        CommonAddresses calldata _commonAddresses,
        ISolidlyRouter.Route[] calldata _outputToNativeRoute,
        ISolidlyRouter.Route[] calldata _outputToLp0Route,
        ISolidlyRouter.Route[] calldata _outputToLp1Route
    ) external initializer  {
        __StratFeeManager_init(_commonAddresses);
        want = _want;
        gauge = _gauge;
        beefySwapper = _beefySwapper;

        factory = ISolidlyRouter(unirouter).defaultFactory();
        stable = ISolidlyPair(want).stable();

        for (uint i; i < _outputToNativeRoute.length; ++i) {
            outputToNativeRoute.push(_outputToNativeRoute[i]);
        }

        for (uint i; i < _outputToLp0Route.length; ++i) {
            outputToLp0Route.push(_outputToLp0Route[i]);
        }

        for (uint i; i < _outputToLp1Route.length; ++i) {
            outputToLp1Route.push(_outputToLp1Route[i]);
        }

        output = outputToNativeRoute[0].from;
        native = outputToNativeRoute[outputToNativeRoute.length -1].to;
        lpToken0 = ISolidlyPair(want).token0();
        lpToken1 = ISolidlyPair(want).token1();

        _giveAllowances();

    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IVelodromeGauge(gauge).deposit(wantBal, address(this));
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IVelodromeGauge(gauge).withdraw(_amount - wantBal);
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal * withdrawalFee / WITHDRAWAL_MAX;
            wantBal = wantBal - withdrawalFeeAmount;
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external virtual override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        IVelodromeGauge(gauge).getReward(address(this));
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            chargeFees(callFeeRecipient);
            addLiquidity();
            uint256 wantHarvested = balanceOfWant();
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 toNative = IERC20(output).balanceOf(address(this)) * fees.total / DIVISOR;
        (address router,,,,) = IBeefySwapper(beefySwapper).swapInfo(output, native);
        if (router != address(0)) {
            IBeefySwapper(beefySwapper).swap(output, native, toNative);
        } else {
            ISolidlyRouter(unirouter).swapExactTokensForTokens(toNative, 0, outputToNativeRoute, address(this), block.timestamp);
        }

        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        uint256 callFeeAmount = nativeBal * fees.call / DIVISOR;
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 beefyFeeAmount = nativeBal * fees.beefy / DIVISOR;
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFeeAmount = nativeBal * fees.strategist / DIVISOR;
        IERC20(native).safeTransfer(strategist, strategistFeeAmount);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFeeAmount);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        uint256 lp0Amt = outputBal / 2;
        uint256 lp1Amt = outputBal - lp0Amt;

        if (stable) {
            uint256 lp0Decimals = 10**IERC20Extended(lpToken0).decimals();
            uint256 lp1Decimals = 10**IERC20Extended(lpToken1).decimals();
            uint256 out0 = lpToken0 != output ? ISolidlyRouter(unirouter).getAmountsOut(lp0Amt, outputToLp0Route)[outputToLp0Route.length] * 1e18 / lp0Decimals : lp0Amt;
            uint256 out1 = lpToken1 != output ? ISolidlyRouter(unirouter).getAmountsOut(lp1Amt, outputToLp1Route)[outputToLp1Route.length] * 1e18 / lp1Decimals  : lp1Amt;
            (uint256 amountA, uint256 amountB,) = ISolidlyRouter(unirouter).quoteAddLiquidity(lpToken0, lpToken1, stable, factory, out0, out1);
            amountA = amountA * 1e18 / lp0Decimals;
            amountB = amountB * 1e18 / lp1Decimals;
            uint256 ratio = out0 * 1e18 / out1 * amountB / amountA;
            lp0Amt = outputBal * 1e18 / (ratio + 1e18);
            lp1Amt = outputBal - lp0Amt;
        }

        if (lpToken0 != output) {
            (address router,,,,) = IBeefySwapper(beefySwapper).swapInfo(output, lpToken0);
            if (router != address(0)) {
                IBeefySwapper(beefySwapper).swap(output, lpToken0, lp0Amt);
            } else {
                ISolidlyRouter(unirouter).swapExactTokensForTokens(lp0Amt, 0, outputToLp0Route, address(this), block.timestamp);
            }
        }

        if (lpToken1 != output) {
            (address router,,,,) = IBeefySwapper(beefySwapper).swapInfo(output, lpToken1);
            if (router != address(0)) {
                IBeefySwapper(beefySwapper).swap(output, lpToken1, lp1Amt);
            } else {
                ISolidlyRouter(unirouter).swapExactTokensForTokens(lp1Amt, 0, outputToLp1Route, address(this), block.timestamp);
            }
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        ISolidlyRouter(unirouter).addLiquidity(lpToken0, lpToken1, stable, lp0Bal, lp1Bal, 1, 1, address(this), block.timestamp);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant() + balanceOfPool();
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        return IVelodromeGauge(gauge).balanceOf(address(this));
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        return IVelodromeGauge(gauge).earned(address(this));
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            nativeOut = ISolidlyRouter(unirouter).getAmountsOut(outputBal, outputToNativeRoute)[outputToNativeRoute.length];
        }

        return nativeOut * fees.total / DIVISOR * fees.call / DIVISOR;
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IVelodromeGauge(gauge).withdraw(balanceOfPool());

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IVelodromeGauge(gauge).withdraw(balanceOfPool());
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(gauge, type(uint).max);
        IERC20(output).safeApprove(unirouter, type(uint).max);
        IERC20(output).safeApprove(beefySwapper, type(uint).max);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, type(uint).max);

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, type(uint).max);
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(gauge, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(output).safeApprove(beefySwapper, 0);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function _solidlyToRoute(ISolidlyRouter.Route[] memory _route) internal pure returns (address[] memory) {
        address[] memory route = new address[](_route.length + 1);
        route[0] = _route[0].from;
        for (uint i; i < _route.length; ++i) {
            route[i + 1] = _route[i].to;
        }
        return route;
    }

    function outputToNative() external view returns (address[] memory) {
        ISolidlyRouter.Route[] memory _route = outputToNativeRoute;
        return _solidlyToRoute(_route);
    }

    function outputToLp0() external view returns (address[] memory) {
        ISolidlyRouter.Route[] memory _route = outputToLp0Route;
        return _solidlyToRoute(_route);
    }

    function outputToLp1() external view returns (address[] memory) {
        ISolidlyRouter.Route[] memory _route = outputToLp1Route;
        return _solidlyToRoute(_route);
    }

    function setBeefySwapper(address _beefySwapper) external onlyManager {
        IERC20(output).safeApprove(beefySwapper, 0);
        beefySwapper = _beefySwapper;
        if (!paused()) IERC20(output).safeApprove(beefySwapper, type(uint).max);
        emit SetBeefySwapper(_beefySwapper);
    }
}