// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestBase} from "./TestBase.sol";
import {StockTokenVault} from "../src/StockTokenVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";

contract OracleFrontrunningTest is TestBase {
    uint256 internal constant MON = 1_794_236_400;

    MockUSDC internal usdc;
    MockEquityOracle internal oracle;
    address internal attacker;
    address internal keeper;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockEquityOracle();
        attacker = makeAddr("frontRunner");
        keeper = makeAddr("keeper");
        vm.warp(MON);
        oracle.setQuote(100e18, 0.5e18, MON);
        usdc.mint(attacker, 1_000e6);
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
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
    }

    function queue(uint256 nextPrice) internal {
        vm.prank(keeper);
        oracle.queueUpdate(nextPrice); // price is known to the searcher, not yet applied
    }

    /// @notice FAILURE: attacker gets ahead of the queued update and mints cheap shares.
    function testOracleUpdateFrontrunning_WithoutGuard(uint256 nextDollars) public {
        uint256 nextPrice = bound(nextDollars, 105, 180) * 1e18;
        StockTokenVault vault = deploy(false);
        queue(nextPrice);

        vm.prank(attacker);
        vault.mint(100e6);

        vm.prank(keeper);
        oracle.applyUpdate();

        vm.prank(attacker);
        vault.redeem(1e18);
        uint256 profit = usdc.balanceOf(attacker) - 1_000e6;
        uint256 expectedProfit = ((nextPrice - 100e18) * 1e6) / 1e18;
        assertEq(profit, expectedProfit, "captured the entire pending reprice");
    }

    /// @notice FIX: mint/redeem is refused while an update is queued.
    function testOracleUpdateFrontrunning_WithGuard(uint256 nextDollars) public {
        uint256 nextPrice = bound(nextDollars, 105, 180) * 1e18;
        StockTokenVault vault = deploy(true);
        queue(nextPrice);

        vm.expectRevert(StockTokenVault.PendingOracleUpdate.selector);
        vm.prank(attacker);
        vault.mint(100e6);

        vm.prank(keeper);
        oracle.applyUpdate();

        vm.prank(attacker);
        vault.mint(100e6);
        uint256 shares = vault.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(shares);
        assertApproxEqAbs(usdc.balanceOf(attacker), 1_000e6, 1_000, "no profit after the update settled");
    }

    /// @notice A queued update cannot freeze the vault forever: publishing a
    ///         quote clears the pending flag, so trading resumes.
    function testSetQuoteClearsPending() public {
        StockTokenVault vault = deploy(true);
        queue(150e18);

        vm.expectRevert(StockTokenVault.PendingOracleUpdate.selector);
        vm.prank(attacker);
        vault.mint(100e6);

        oracle.setQuote(100e18, 0.5e18, MON); // clears pending
        vm.prank(attacker);
        vault.mint(100e6);
        assertEq(vault.balanceOf(attacker), 1e18);
    }
}
