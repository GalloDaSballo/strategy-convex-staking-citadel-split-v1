// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "deps/@openzeppelin/contracts-upgradeable/utils/EnumerableSetUpgradeable.sol";
import "interfaces/uniswap/IUniswapRouterV2.sol";
import "interfaces/badger/IBadgerGeyser.sol";

import "interfaces/uniswap/IUniswapPair.sol";

import "interfaces/badger/IController.sol";

import "interfaces/badger/ISettV4.sol";

import "interfaces/convex/IBooster.sol";
import "interfaces/convex/CrvDepositor.sol";
import "interfaces/convex/IBaseRewardsPool.sol";
import "interfaces/convex/ICvxRewardsPool.sol";

import "deps/BaseStrategySwapper.sol";

import "deps/libraries/CurveSwapper.sol";
import "deps/libraries/UniswapSwapper.sol";
import "deps/libraries/TokenSwapPathRegistry.sol";

/*
    Forked from:
    https://github.com/sajanrajdev/strategy-convex-staking-optimizer

    Citadel Version:

*/
contract StrategyConvexStakingOptimizer is
    BaseStrategy,
    CurveSwapper,
    UniswapSwapper,
    TokenSwapPathRegistry
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    // == CITADEL SETTINS ==//
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant AUTOCOMPOUND_BPS = 9_000; // 90%
    uint256 public constant EMIT_BPS = 1_000; // 10% // Sell and send to locker


    // ===== Token Registry =====
    address public constant wbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant cvx = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address public constant cvxCrv = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant threeCrv =
        0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;

    IERC20Upgradeable public constant wbtcToken =
        IERC20Upgradeable(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20Upgradeable public constant crvToken =
        IERC20Upgradeable(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20Upgradeable public constant cvxToken =
        IERC20Upgradeable(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20Upgradeable public constant cvxCrvToken =
        IERC20Upgradeable(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);
    IERC20Upgradeable public constant usdcToken =
        IERC20Upgradeable(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Upgradeable public constant threeCrvToken =
        IERC20Upgradeable(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);
    IERC20Upgradeable public constant bveCVX =
        IERC20Upgradeable(0xfd05D3C7fe2924020620A8bE4961bBaA747e6305);

    // ===== Convex Registry =====
    CrvDepositor public constant crvDepositor =
        CrvDepositor(0x8014595F2AB54cD7c604B00E9fb932176fDc86Ae); // Convert CRV -> cvxCRV
    IBooster public constant booster =
        IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IBaseRewardsPool public baseRewardsPool;
    IBaseRewardsPool public constant cvxCrvRewardsPool =
        IBaseRewardsPool(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
    ICvxRewardsPool public constant cvxRewardsPool =
        ICvxRewardsPool(0xCF50b810E57Ac33B91dCF525C6ddd9881B139332);
    address public constant threeCrvSwap =
        0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    uint256 public constant MAX_UINT_256 = uint256(-1);

    uint256 public pid;
    address public badgerTree;
    ISettV4 public cvxCrvHelperVault;

    /**
    The default conditions for a rewards token are:
    - Collect rewards token
    - Distribute 100% via Tree to users

    === Harvest Config ===
    - autoCompoundingBps: Sell this % of rewards for underlying asset.
    - autoCompoundingPerfFee: Of the auto compounded portion, take this % as a performance fee.
    - treeDistributionPerfFee: Of the remaining portion (everything not distributed or converted via another mehcanic is distributed via the tree), take this % as a performance fee.

    === Tend Config ===
    - tendConvertTo: On tend, convert some of this token into another asset. By default with value as address(0), skip this step.
    - tendConvertBps: Convert this portion of balance into another asset.
     */

    uint256 public stableSwapSlippageTolerance;
    uint256 public constant crvCvxCrvPoolIndex = 2;
    // Minimum 3Crv harvested to perform a profitable swap on it
    uint256 public minThreeCrvHarvest;

    event TreeDistribution(
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    event PerformanceFeeGovernance(
        address indexed destination,
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    event PerformanceFeeStrategist(
        address indexed destination,
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    event WithdrawState(
        uint256 toWithdraw,
        uint256 preWant,
        uint256 postWant,
        uint256 withdrawn
    );

    struct HarvestData {
        uint256 cvxCrvHarvested;
        uint256 cvxHarvested;
    }

    struct TendData {
        uint256 crvTended;
        uint256 cvxTended;
    }

    event TendState(uint256 crvTended, uint256 cvxTended);

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256 _pid,
        uint256[3] memory _feeConfig
    ) public initializer whenNotPaused {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        want = _wantConfig[0];
        badgerTree = _wantConfig[1];

        cvxCrvHelperVault = ISettV4(_wantConfig[2]);

        pid = _pid; // Core staking pool ID

        IBooster.PoolInfo memory poolInfo = booster.poolInfo(pid);
        baseRewardsPool = IBaseRewardsPool(poolInfo.crvRewards);

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        // Approvals: Staking Pools
        IERC20Upgradeable(want).approve(address(booster), MAX_UINT_256);
        cvxToken.approve(address(cvxRewardsPool), MAX_UINT_256);
        cvxCrvToken.approve(address(cvxCrvRewardsPool), MAX_UINT_256);

        // Approvals: CRV -> cvxCRV converter
        crvToken.approve(address(crvDepositor), MAX_UINT_256);

        // Set Swap Paths
        address[] memory path = new address[](3);
        path[0] = usdc;
        path[1] = weth;
        path[2] = crv;
        _setTokenSwapPath(usdc, crv, path);

        _initializeApprovals();

        // Set default values
        stableSwapSlippageTolerance = 500;
        minThreeCrvHarvest = 1000e18;
    }

    /// ===== Permissioned Functions =====
    function setPid(uint256 _pid) external {
        _onlyGovernance();
        pid = _pid; // LP token pool ID
    }

    function initializeApprovals() external {
        _onlyGovernance();
        _initializeApprovals();
    }

    function setstableSwapSlippageTolerance(uint256 _sl) external {
        _onlyGovernance();
        stableSwapSlippageTolerance = _sl;
    }

    function setMinThreeCrvHarvest(uint256 _minThreeCrvHarvest) external {
        _onlyGovernance();
        minThreeCrvHarvest = _minThreeCrvHarvest;
    }

    function _initializeApprovals() internal {
        cvxCrvToken.approve(address(cvxCrvHelperVault), MAX_UINT_256);
    }

    /// ===== View Functions =====
    function version() external pure returns (string memory) {
        return "1.3";
    }

    function getName() external pure override returns (string memory) {
        return "StrategyConvexStakingOptimizer";
    }

    function balanceOfPool() public view override returns (uint256) {
        return baseRewardsPool.balanceOf(address(this));
    }

    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](4);
        protectedTokens[0] = want;
        protectedTokens[1] = crv;
        protectedTokens[2] = cvx;
        protectedTokens[3] = cvxCrv;
        return protectedTokens;
    }

    function isTendable() public view override returns (bool) {
        return true;
    }

    /// ===== Internal Core Implementations =====
    function _onlyNotProtectedTokens(address _asset) internal override {
        require(address(want) != _asset, "want");
        require(address(crv) != _asset, "crv");
        require(address(cvx) != _asset, "cvx");
        require(address(cvxCrv) != _asset, "cvxCrv");
    }

    /// @dev Deposit Badger into the staking contract
    function _deposit(uint256 _want) internal override {
        // Deposit all want in core staking pool
        booster.deposit(pid, _want, true);
    }

    /// @dev Unroll from all strategy positions, and transfer non-core tokens to controller rewards
    function _withdrawAll() internal override {
        baseRewardsPool.withdrawAndUnwrap(balanceOfPool(), false);
        // Note: All want is automatically withdrawn outside this "inner hook" in base strategy function
    }

    /// @dev Withdraw want from staking rewards, using earnings first
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        // Get idle want in the strategy
        uint256 _preWant = IERC20Upgradeable(want).balanceOf(address(this));

        // If we lack sufficient idle want, withdraw the difference from the strategy position
        if (_preWant < _amount) {
            uint256 _toWithdraw = _amount.sub(_preWant);
            baseRewardsPool.withdrawAndUnwrap(_toWithdraw, false);
        }

        // Confirm how much want we actually end up with
        uint256 _postWant = IERC20Upgradeable(want).balanceOf(address(this));

        // Return the actual amount withdrawn if less than requested
        uint256 _withdrawn = MathUpgradeable.min(_postWant, _amount);
        emit WithdrawState(_amount, _preWant, _postWant, _withdrawn);

        return _withdrawn;
    }

    function _tendGainsFromPositions() internal {
        // Harvest CRV, CVX, cvxCRV, 3CRV, and extra rewards tokens from staking positions
        // Note: Always claim extras
        baseRewardsPool.getReward(address(this), true);

        if (cvxCrvRewardsPool.earned(address(this)) > 0) {
            cvxCrvRewardsPool.getReward(address(this), true);
        }

        if (cvxRewardsPool.earned(address(this)) > 0) {
            cvxRewardsPool.getReward(false);
        }
    }

    /// @notice The more frequent the tend, the higher returns will be
    function tend() external whenNotPaused returns (TendData memory) {
        _onlyAuthorizedActors();

        TendData memory tendData;

        // 1. Claim CVX and CRV
        _tendGainsFromPositions();

        // Track harvested coins, before conversion
        tendData.crvTended = crvToken.balanceOf(address(this));

        // Track harvested + converted coins
        tendData.cvxTended = cvxToken.balanceOf(address(this));

        emit Tend(0);
        emit TendState(
            tendData.crvTended,
            tendData.cvxTended,
        );
        return tendData;
    }

    // No-op until we optimize harvesting strategy. Auto-compouding is key.
    function harvest() external whenNotPaused returns (uint256) {
        _onlyAuthorizedActors();
        HarvestData memory harvestData;

        uint256 totalWantBefore = balanceOf();

        // Claim All rewards just like in tend
        _tendGainsFromPositions();

        // Process CRV

        // Ask Curve, Ask UniV3, 

        // Process CVX

        // Check if cvxCRV
        // If cvxCRV Proces

        // Auto-Compound

        // Emit Rest

        harvestData.crvHarvested = crvToken.balanceOf(address(this));
        harvestData.cvxCrvHarvested = cvxCrvToken.balanceOf(address(this));
        harvestData.cvxHarvested = cvxToken.balanceOf(address(this));


        uint256 totalWantAfter = balanceOf();
        require(totalWantAfter >= totalWantBefore, "want-decreased");
        // Expected to be 0 since there is no auto compounding
        uint256 wantGained = totalWantAfter - totalWantBefore;

        emit Harvest(wantGained, block.number);
        return wantGained;
    }
}
