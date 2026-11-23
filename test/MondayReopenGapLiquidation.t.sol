// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestBase} from "./TestBase.sol";
import {StockTokenVault} from "../src/StockTokenVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";
import {MockLender} from "./mocks/MockLender.sol";

/// @dev $100 position, $2 margin, $98 debt = 50x. A 4% reopen gap wipes the margin.
///      The attack is stopped by the market-hours check, which refuses the
///      weekend/pre-open quote; the guard is opt-in in the mock lender.
contract MondayReopenGapLiquidationTest is TestBase {
    uint256 internal constant FRI = 1_793_991_600;
    uint256 internal constant SUN = 1_794_164_400;
    uint256 internal constant MON = 1_794_236_400;

    MockUSDC internal usdc;
    MockEquityOracle internal oracle;
    address internal trader;
    address internal liquidator;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockEquityOracle();
        trader = makeAddr("fiftyXTrader");
        liquidator = makeAddr("liquidator");
        vm.warp(FRI);
        oracle.setQuote(100e18, 0.5e18, FRI);
        usdc.mint(trader, 100e6);
        usdc.mint(liquidator, 100e6);
    }

    function config(bool guarded) internal pure returns (StockTokenVault.GuardConfig memory cfg) {
        cfg = StockTokenVault.GuardConfig({
            marketHours: guarded,
            staleness: guarded,
            confidence: guarded,
            pendingUpdate: guarded,
            maxPriceAge: 24 hours,
            maxConfidenceBps: 200,
            marketOpenUtcMinute: 14 * 60 + 30,
            marketCloseUtcMinute: 21 * 60
        });
    }

    function openPosition(bool guarded) internal returns (StockTokenVault vault, MockLender lender) {
        vault = new StockTokenVault(usdc, oracle, config(guarded));
        usdc.mint(address(vault), 10_000e6); // LP liquidity
        lender = new MockLender(vault, oracle, usdc, guarded);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        vault.mint(100e6); // 1 share = $100 collateral
        vm.prank(trader);
        vault.approve(address(lender), 1e18);
        usdc.mint(address(lender), 98e6); // book funds the $98 loan
        vm.prank(trader);
        lender.open(1e18, 98e6); // 50x: $2 margin controls $100 notional
        assertEq(lender.healthBps(trader), 10_204);
    }

    /// @notice FAILURE: a pre-open quote can be pushed down and the position is
    ///         liquidated before Monday's real reopen price exists.
    function testMondayReopenGapLiquidation_WithoutGuard() public {
        (, MockLender lender) = openPosition(false);

        vm.warp(SUN);
        oracle.setQuote(90e18, 0.5e18, SUN); // stale/wrong weekend quote
        vm.prank(liquidator);
        lender.liquidate(trader);

        assertEq(lender.collateralShares(trader), 0, "collateral seized before reopen");
        assertEq(lender.debt(trader), 0);
    }

    /// @notice FIX: liquidation can only use a guarded quote, so it happens at
    ///         the Monday reopen with the fresh $96 price, not on a weekend print.
    function testMondayReopenGapLiquidation_WithGuard() public {
        (, MockLender lender) = openPosition(true);

        vm.warp(SUN);
        oracle.setQuote(90e18, 0.5e18, SUN); // fresh, tight, but market is shut
        vm.expectRevert(StockTokenVault.MarketClosed.selector);
        vm.prank(liquidator);
        lender.liquidate(trader);
        assertEq(lender.collateralShares(trader), 1e18, "no weekend seizure");

        vm.warp(MON);
        oracle.setQuote(96e18, 0.5e18, MON); // -4% Friday -> Monday gap
        assertLt(lender.healthBps(trader), lender.MAINTENANCE_BPS());

        vm.prank(liquidator);
        lender.liquidate(trader);
        assertEq(lender.collateralShares(trader), 0);
        uint256 gapOnNotional = 100e6 - 96e6;
        uint256 marginLost = 98e6 - 96e6;
        assertEq(gapOnNotional, 4e6, "4% gap on $100 notional");
        assertEq(marginLost, 2e6, "entire $2 margin eliminated at 50x");
    }

    /// @notice Fuzz: at 50x, any adverse gap above 200 bps consumes the 2% margin.
    function testFiftyXMarginWipesOnReopenGap(uint256 gapBps) public pure {
        gapBps = bound(gapBps, 1, 1_000);
        uint256 notional = 100e6;
        uint256 debt = 98e6;
        uint256 reopenValue = (notional * (10_000 - gapBps)) / 10_000;
        if (gapBps > 200) {
            assertLt(reopenValue, debt, "50x margin gone");
        } else {
            assertGe(reopenValue, debt, "margin survives a smaller gap");
        }
    }
}
