// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestBase} from "./TestBase.sol";
import {StockTokenVault} from "../src/StockTokenVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";

contract GuardHaltsRedemptionTest is TestBase {
    uint256 internal constant FRI = 1_793_991_600;
    uint256 internal constant SAT = 1_794_078_000;
    uint256 internal constant MON = 1_794_236_400;

    // Friday 2026-01-09 12:00 UTC + N hours, N = 0..167. Each character is the
    // independently computed (Python zoneinfo) expected US Eastern market state:
    // 1 = open 09:30-16:00 Mon-Fri, 0 = closed. This is NOT the contract formula.
    uint256 internal constant WINTER_BASE = 1_767_960_000;
    string internal constant WINTER_EXPECTED =
        "00011111100000000000000000000000000000000000000000000000"
        "00000000000000000001111110000000000000000001111110000000"
        "00000000000111111000000000000000000111111000000000000000";

    MockUSDC internal usdc;
    MockEquityOracle internal oracle;
    address internal user;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockEquityOracle();
        user = makeAddr("holder");
        vm.warp(FRI);
        oracle.setQuote(100e18, 0.5e18, FRI);
        usdc.mint(user, 1_000e6);
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

    function deploy(bool guarded) internal returns (StockTokenVault vault) {
        vault = new StockTokenVault(usdc, oracle, config(guarded));
        usdc.mint(address(vault), 10_000e6); // LP liquidity for redemptions
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @notice UNSAFE: on Saturday a holder exits at Friday's frozen $100 mark
    ///         even though the true price is already $80. LPs eat the $20 gap.
    function testGuardHaltsRedemption_WithoutGuard() public {
        StockTokenVault vault = deploy(false);
        vm.prank(user);
        vault.mint(100e6); // 1 share

        vm.warp(SAT);
        oracle.setQuote(100e18, 0.5e18, SAT); // fresh label, stale economics
        vm.prank(user);
        uint256 paid = vault.redeem(1e18); // succeeds while the cash market is shut

        assertEq(paid, 100e6, "exit at the stale Friday price");
        assertEq(usdc.balanceOf(user), 1_000e6, "holder escaped the $20 loss");
        assertEq(vault.balanceOf(user), 0);
    }

    /// @notice FIX: the market-hours guard halts the weekend exit and the same
    ///         holder redeems at the real Monday price instead.
    function testGuardHaltsRedemption_WithGuard() public {
        StockTokenVault vault = deploy(true);
        vm.prank(user);
        vault.mint(100e6);

        vm.warp(SAT);
        oracle.setQuote(100e18, 0.5e18, SAT);
        vm.expectRevert(StockTokenVault.MarketClosed.selector);
        vm.prank(user);
        vault.redeem(1e18);
        assertEq(vault.balanceOf(user), 1e18, "shares remain until reopen");

        vm.warp(MON);
        oracle.setQuote(80e18, 0.5e18, MON); // Monday reality
        vm.prank(user);
        uint256 paid = vault.redeem(1e18);
        assertEq(paid, 80e6, "exit at the real Monday price");
        assertEq(usdc.balanceOf(user), 980e6, "holder bears the $20 gap");
        assertEq(vault.balanceOf(user), 0);
    }

    /// @notice Non-tautological fuzz: compare the contract schedule against a
    ///         hard-coded expected table generated from Python's IANA tzdata,
    ///         and assert the guard's redeem behaviour matches that table.
    function testMarketHoursRedemptionFuzz(uint256 hourOffset) public {
        hourOffset = bound(hourOffset, 0, 167);
        uint256 ts = WINTER_BASE + hourOffset * 1 hours;
        bool expectedOpen = bytes(WINTER_EXPECTED)[hourOffset] == '1';

        StockTokenVault probe = new StockTokenVault(usdc, oracle, config(true));
        assertEq(probe.isMarketOpen(ts) ? 1 : 0, expectedOpen ? 1 : 0, "schedule mismatch");

        StockTokenVault vault = deploy(true);
        vm.prank(user);
        vault.mint(100e6); // opened during Friday market hours

        vm.warp(ts);
        oracle.setQuote(100e18, 0.5e18, ts); // always fresh and tight

        if (!expectedOpen) {
            vm.expectRevert(StockTokenVault.MarketClosed.selector);
        }
        vm.prank(user);
        vault.redeem(1e18);
        assertEq(vault.balanceOf(user), expectedOpen ? 0 : 1e18, "redemption followed the schedule");
    }
}
