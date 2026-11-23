// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestBase} from "./TestBase.sol";
import {StockTokenVault} from "../src/StockTokenVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";

/// @notice US Eastern market hours with the standard US DST rule.
/// @dev Exchange holidays and early closes (e.g. 13:00 ET) are NOT handled.
contract MarketHoursTest is TestBase {
    uint256 internal constant WINTER_1429 = 1_768_487_340; // Thu 2026-01-15 14:29 UTC
    uint256 internal constant WINTER_1430 = 1_768_487_400; // Thu 2026-01-15 14:30 UTC
    uint256 internal constant WINTER_2030 = 1_768_509_000; // Thu 2026-01-15 20:30 UTC
    uint256 internal constant WINTER_2059 = 1_768_510_740; // Thu 2026-01-15 20:59 UTC
    uint256 internal constant WINTER_2100 = 1_768_510_800; // Thu 2026-01-15 21:00 UTC
    uint256 internal constant SUMMER_1329 = 1_784_122_140; // Wed 2026-07-15 13:29 UTC
    uint256 internal constant SUMMER_1330 = 1_784_122_200; // Wed 2026-07-15 13:30 UTC
    uint256 internal constant SUMMER_1959 = 1_784_145_540; // Wed 2026-07-15 19:59 UTC
    uint256 internal constant SUMMER_2000 = 1_784_145_600; // Wed 2026-07-15 20:00 UTC
    uint256 internal constant SUMMER_2030 = 1_784_147_400; // Wed 2026-07-15 20:30 UTC
    uint256 internal constant SAT_WINTER = 1_768_662_000; // Sat 2026-01-17 15:00 UTC
    uint256 internal constant SAT_SUMMER = 1_784_386_800; // Sat 2026-07-18 15:00 UTC
    uint256 internal constant DST_MAR7 = 1_772_895_600; // Sat 2026-03-07 15:00 UTC
    uint256 internal constant DST_MAR8 = 1_772_982_000; // Sun 2026-03-08 15:00 UTC
    uint256 internal constant DST_OCT31 = 1_793_458_800; // Sat 2026-10-31 15:00 UTC
    uint256 internal constant DST_NOV1 = 1_793_545_200; // Sun 2026-11-01 15:00 UTC

    StockTokenVault internal vault;
    MockUSDC internal usdc;
    MockEquityOracle internal oracle;
    address internal user;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockEquityOracle();
        user = makeAddr("hoursUser");
        usdc.mint(user, 1_000e6);
        vault = new StockTokenVault(usdc, oracle, StockTokenVault.GuardConfig({
            marketHours: true,
            staleness: false,
            confidence: false,
            pendingUpdate: false,
            maxPriceAge: 24 hours,
            maxConfidenceBps: 200,
            marketOpenUtcMinute: 14 * 60 + 30,
            marketCloseUtcMinute: 21 * 60
        }));
        usdc.mint(address(vault), 10_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    function quoteAt(uint256 ts) internal {
        vm.warp(ts);
        oracle.setQuote(100e18, 0.5e18, ts);
    }

    function testWinterWeekdayBoundaries() public view {
        assertEq(vault.isMarketOpen(WINTER_1429) ? 1 : 0, 0, "14:29 UTC closed in EST");
        assertEq(vault.isMarketOpen(WINTER_1430) ? 1 : 0, 1, "14:30 UTC open in EST");
        assertEq(vault.isMarketOpen(WINTER_2059) ? 1 : 0, 1, "20:59 UTC open in EST");
        assertEq(vault.isMarketOpen(WINTER_2100) ? 1 : 0, 0, "21:00 UTC closed in EST");
    }

    function testSummerWeekdayBoundaries() public view {
        assertEq(vault.isMarketOpen(SUMMER_1329) ? 1 : 0, 0, "13:29 UTC closed in EDT");
        assertEq(vault.isMarketOpen(SUMMER_1330) ? 1 : 0, 1, "13:30 UTC open in EDT");
        assertEq(vault.isMarketOpen(SUMMER_1959) ? 1 : 0, 1, "19:59 UTC open in EDT");
        assertEq(vault.isMarketOpen(SUMMER_2000) ? 1 : 0, 0, "20:00 UTC closed in EDT");
    }

    /// @notice The key DST regression: the same UTC wall-clock is allowed in
    ///         winter and rejected in summer.
    function testSummer2030UtcRejectedWinter2030UtcAllowed() public {
        quoteAt(SUMMER_2030);
        vm.expectRevert(StockTokenVault.MarketClosed.selector);
        vm.prank(user);
        vault.mint(100e6);

        quoteAt(WINTER_2030);
        vm.prank(user);
        vault.mint(100e6);
        assertEq(vault.balanceOf(user), 1e18, "winter 20:30 UTC trade succeeds");
    }

    function testWinterWeekdayTradeAllowed() public {
        quoteAt(WINTER_1430);
        vm.prank(user);
        vault.mint(100e6);
        assertEq(vault.balanceOf(user), 1e18);
    }

    function testSummerWeekdayTradeAllowed() public {
        quoteAt(SUMMER_1330);
        vm.prank(user);
        vault.mint(100e6);
        assertEq(vault.balanceOf(user), 1e18);
    }

    function testWeekendsClosedInBothSeasons() public {
        assertEq(vault.isMarketOpen(SAT_WINTER) ? 1 : 0, 0);
        assertEq(vault.isMarketOpen(SAT_SUMMER) ? 1 : 0, 0);
        quoteAt(SAT_SUMMER);
        vm.expectRevert(StockTokenVault.MarketClosed.selector);
        vm.prank(user);
        vault.mint(100e6);
    }

    function testDstRuleDates() public view {
        assertEq(vault.isUsDst(DST_MAR7) ? 1 : 0, 0, "before 2nd Sunday of March");
        assertEq(vault.isUsDst(DST_MAR8) ? 1 : 0, 1, "2nd Sunday of March");
        assertEq(vault.isUsDst(DST_OCT31) ? 1 : 0, 1, "before 1st Sunday of November");
        assertEq(vault.isUsDst(DST_NOV1) ? 1 : 0, 0, "1st Sunday of November");
    }
}
