// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestBase} from "./TestBase.sol";
import {StockTokenVault} from "../src/StockTokenVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";

contract WideConfidenceIntervalTest is TestBase {
    uint256 internal constant MON = 1_794_236_400;
    uint256 internal constant PRICE = 100e18;
    uint256 internal constant ASSET_SCALE = 1e6;
    uint256 internal constant PRICE_SCALE = 1e18;

    MockUSDC internal usdc;
    MockEquityOracle internal oracle;
    address internal trader;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockEquityOracle();
        trader = makeAddr("ciTrader");
        vm.warp(MON);
        oracle.setQuote(PRICE, 0.5e18, MON);
        usdc.mint(trader, 1_000e6);
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
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @notice FAILURE: a wide confidence band makes the midpoint a bad price.
    ///         Attacker buys at the midpoint, the quote resolves to the high end.
    function testWideConfidenceIntervalAbuse_WithoutGuard(uint256 confidencePct) public {
        confidencePct = bound(confidencePct, 3, 40);
        oracle.setQuote(PRICE, (PRICE * confidencePct) / 100, MON);
        StockTokenVault vault = deploy(false);

        vm.prank(trader);
        vault.mint(100e6);

        uint256 resolvedPrice = PRICE + (PRICE * confidencePct) / 100;
        oracle.setQuote(resolvedPrice, 0.5e18, MON);
        vm.prank(trader);
        vault.redeem(1e18);

        uint256 profit = usdc.balanceOf(trader) - 1_000e6;
        uint256 expectedProfit = (PRICE * confidencePct * ASSET_SCALE) / (100 * PRICE_SCALE);
        assertEq(profit, expectedProfit, "profit equals CI half-width in USDC");
    }

    /// @notice FIX: any CI above 2% is rejected, so the midpoint cannot be abused.
    function testWideConfidenceIntervalAbuse_WithGuard(uint256 confidencePct) public {
        confidencePct = bound(confidencePct, 3, 40);
        oracle.setQuote(PRICE, (PRICE * confidencePct) / 100, MON);
        StockTokenVault vault = deploy(true);

        vm.expectRevert(StockTokenVault.ConfidenceTooWide.selector);
        vm.prank(trader);
        vault.mint(100e6);

        // Boundary: exactly 2% is accepted when everything else is healthy.
        oracle.setQuote(PRICE, (PRICE * 2) / 100, MON);
        vm.prank(trader);
        vault.mint(100e6);
        assertEq(vault.balanceOf(trader), 1e18);
    }
}
