// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestBase} from "./TestBase.sol";
import {StockTokenVault} from "../src/StockTokenVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";

/// @dev Real dates behind these epochs: Fri 2026-11-06 19:00 UTC (cash close),
///      Sat 2026-11-07 19:00 UTC, Mon 2026-11-09 15:00 UTC (10:00 EST).
contract StaleFridayCloseTest is TestBase {
    uint256 internal constant FRI = 1_793_991_600;
    uint256 internal constant SAT = 1_794_078_000;
    uint256 internal constant MON = 1_794_236_400;
    uint256 internal constant MAX_AGE = 24 hours;

    MockUSDC internal usdc;
    MockEquityOracle internal oracle;
    address internal trader;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockEquityOracle();
        trader = makeAddr("weekendTrader");
        vm.warp(FRI);
        oracle.setQuote(100e18, 0.5e18, FRI); // $100, 0.5% CI, fresh at Friday close
        usdc.mint(trader, 1_000e6);
    }

    function config(bool guarded) internal pure returns (StockTokenVault.GuardConfig memory cfg) {
        cfg = StockTokenVault.GuardConfig({
            marketHours: guarded,
            staleness: guarded,
            confidence: guarded,
            pendingUpdate: guarded,
            maxPriceAge: MAX_AGE,
            maxConfidenceBps: 200, // 2%
            marketOpenUtcMinute: 14 * 60 + 30,
            marketCloseUtcMinute: 21 * 60
        });
    }

    function deploy(bool guarded) internal returns (StockTokenVault vault) {
        vault = new StockTokenVault(usdc, oracle, config(guarded));
        usdc.mint(address(vault), 10_000e6); // LP liquidity for redemptions
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @notice FAILURE: quote frozen at Friday's close, news breaks Saturday,
    ///         attacker mints at the stale $100 and redeems Monday at $130.
    ///         Stopped in practice by the market-hours guard (see _WithGuard).
    function testStaleFridayCloseArbitrage_WithoutGuard() public {
        StockTokenVault vault = deploy(false);

        vm.warp(SAT);
        vm.prank(trader);
        vault.mint(100e6);
        assertEq(vault.balanceOf(trader), 1e18);

        vm.warp(MON);
        oracle.setQuote(130e18, 0.5e18, MON);
        vm.prank(trader);
        vault.redeem(1e18);

        assertEq(usdc.balanceOf(trader), 1_030e6);
        assertEq(usdc.balanceOf(trader) - 1_000e6, 30e6, "stale-quote profit");
    }

    /// @notice FIX: the weekend mint is blocked by the market-hours check;
    ///         only a genuine Friday entry survives.
    function testStaleFridayCloseArbitrage_WithGuard() public {
        StockTokenVault vault = deploy(true);

        vm.prank(trader);
        vault.mint(100e6); // allowed: Friday, market open, fresh quote

        vm.warp(SAT);
        vm.expectRevert(StockTokenVault.MarketClosed.selector);
        vm.prank(trader);
        vault.mint(100e6);

        vm.warp(MON);
        oracle.setQuote(130e18, 0.5e18, MON);
        vm.prank(trader);
        vault.redeem(1e18);

        assertEq(usdc.balanceOf(trader), 1_030e6);
        assertEq(vault.balanceOf(trader), 0);
    }

    /// @notice Fuzz: even during market hours, a quote older than maxPriceAge is unusable.
    ///         This is the separate staleness-guard test (not the market-hours one).
    function testStalePriceGuardFuzz(uint256 ageSeconds) public {
        ageSeconds = bound(ageSeconds, MAX_AGE + 1, 200 hours);
        vm.warp(MON);
        oracle.setQuote(100e18, 0.5e18, MON - ageSeconds);
        StockTokenVault vault = deploy(true);

        vm.expectRevert(StockTokenVault.StalePrice.selector);
        vm.prank(trader);
        vault.mint(100e6);
    }
}
