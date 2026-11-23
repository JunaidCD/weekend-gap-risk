// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TestBase} from "./TestBase.sol";
import {StockTokenVault} from "../src/StockTokenVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEquityOracle} from "./mocks/MockEquityOracle.sol";

contract DecimalsAndGuardsTest is TestBase {
    uint256 internal constant MON = 1_794_236_400;

    MockUSDC internal usdc;
    MockEquityOracle internal oracle;
    StockTokenVault internal vault;
    address internal user;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockEquityOracle();
        user = makeAddr("decimalUser");
        vm.warp(MON);
        oracle.setQuote(100e18, 0.5e18, MON);
        vault = new StockTokenVault(usdc, oracle, StockTokenVault.GuardConfig({
            marketHours: true,
            staleness: true,
            confidence: true,
            pendingUpdate: true,
            maxPriceAge: 24 hours,
            maxConfidenceBps: 200,
            marketOpenUtcMinute: 14 * 60 + 30,
            marketCloseUtcMinute: 21 * 60
        }));
        usdc.mint(address(vault), 10_000e6);
        usdc.mint(user, 1_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testAssetDecimalsAreReadAndSharesStay18() public view {
        assertEq(usdc.decimals(), 6, "mock USDC has 6 decimals");
        assertEq(vault.usdcDecimals(), 6, "vault reads asset decimals");
        assertEq(vault.assetScale(), 1e6, "asset scale is 1e6");
        assertEq(vault.decimals(), 18, "shares stay 18 decimals");
    }

    /// @notice The key decimal regression: 1 share at $100 pays exactly 100 USDC.
    function testOneShareRedeemsExactly100Usdc() public {
        vm.prank(user);
        uint256 shares = vault.mint(100e6);
        assertEq(shares, 1e18, "100 USDC buys exactly 1 share at $100");

        vm.prank(user);
        uint256 paid = vault.redeem(1e18);
        assertEq(paid, 100e6, "1 share pays exactly 100e6 base units");
        assertEq(usdc.balanceOf(user), 1_000e6, "round trip is lossless");
    }

    function testPreviewMatchesActual() public {
        assertEq(vault.previewMint(100e6), 1e18);
        vm.prank(user);
        vault.mint(100e6);
        assertEq(vault.previewRedeem(1e18), 100e6);
    }

    function testZeroShareMintReverts() public {
        vm.expectRevert(StockTokenVault.ZeroShares.selector);
        vm.prank(user);
        vault.mint(0);
    }

    function testZeroShareRedeemReverts() public {
        vm.expectRevert(StockTokenVault.ZeroShares.selector);
        vm.prank(user);
        vault.redeem(0);
    }

    function testFutureLastUpdateReverts() public {
        oracle.setQuote(100e18, 0.5e18, MON + 1 hours);
        vm.expectRevert(StockTokenVault.FutureTimestamp.selector);
        vm.prank(user);
        vault.mint(100e6);
    }
}
