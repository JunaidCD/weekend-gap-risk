// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StockTokenVault} from "../../src/StockTokenVault.sol";
import {IEquityOracle} from "../../src/StockTokenVault.sol";
import {IERC20Minimal} from "../../src/StockTokenVault.sol";

/// @notice Demo 50x book: vault shares are collateral, USDC is debt.
contract MockLender {
    uint256 public constant MAINTENANCE_BPS = 10_150; // 101.5% collateral / debt

    StockTokenVault public immutable vault;
    IEquityOracle public immutable oracle;
    IERC20Minimal public immutable usdc;
    bool public immutable useGuardedPrice;

    mapping(address => uint256) public collateralShares;
    mapping(address => uint256) public debt;

    event Opened(address indexed user, uint256 shares, uint256 borrowed);
    event Liquidated(address indexed user, address indexed liquidator, uint256 shares, uint256 price);

    constructor(StockTokenVault vault_, IEquityOracle oracle_, IERC20Minimal usdc_, bool useGuardedPrice_) {
        vault = vault_;
        oracle = oracle_;
        usdc = usdc_;
        useGuardedPrice = useGuardedPrice_;
    }

    function open(uint256 shares, uint256 borrowAmount) external {
        require(vault.transferFrom(msg.sender, address(this), shares), "transfer");
        collateralShares[msg.sender] += shares;
        debt[msg.sender] += borrowAmount;
        require(usdc.transfer(msg.sender, borrowAmount), "borrow");
        emit Opened(msg.sender, shares, borrowAmount);
    }

    function healthBps(address user) public view returns (uint256) {
        if (debt[user] == 0) return type(uint256).max;
        // previewRedeem values collateral in the asset's own base units and uses
        // the guarded quote when this lender opts in.
        uint256 collateralValue = useGuardedPrice
            ? vault.previewRedeem(collateralShares[user])
            : (collateralShares[user] * oracle.price() * vault.assetScale()) / (vault.SCALE() * vault.SCALE());
        return (collateralValue * 10_000) / debt[user];
    }

    function liquidate(address user) external {
        uint256 price = useGuardedPrice ? vault.guardedPrice() : oracle.price();
        if (debt[user] == 0 || collateralShares[user] == 0) revert("nothing to liquidate");
        if (healthBps(user) >= MAINTENANCE_BPS) revert("healthy");

        uint256 seized = collateralShares[user];
        collateralShares[user] = 0;
        debt[user] = 0;
        require(vault.transfer(msg.sender, seized), "seize");
        emit Liquidated(user, msg.sender, seized, price);
    }
}
