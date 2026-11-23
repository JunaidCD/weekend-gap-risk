// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEquityOracle} from "../../src/StockTokenVault.sol";

/// @notice Controllable oracle: simulates a stale quote, wide CI and queued updates.
contract MockEquityOracle is IEquityOracle {
    uint256 private _price;
    uint256 private _confidence;
    uint256 private _lastUpdate;
    uint256 private _seq;
    bool private _pending;
    uint256 private _nextPrice;

    function price() external view returns (uint256) { return _price; }
    function confidence() external view returns (uint256) { return _confidence; }
    function lastUpdate() external view returns (uint256) { return _lastUpdate; }
    function seq() external view returns (uint256) { return _seq; }
    function pendingUpdate() external view returns (bool) { return _pending; }

    /// @notice Publishing a quote also settles any queued update, so a guarded
    ///         vault cannot be frozen forever by a stale pending flag.
    function setQuote(uint256 price_, uint256 confidence_, uint256 lastUpdate_) external {
        _price = price_;
        _confidence = confidence_;
        _lastUpdate = lastUpdate_;
        _pending = false;
        _seq += 1;
    }

    function setLastUpdate(uint256 lastUpdate_) external {
        _lastUpdate = lastUpdate_;
    }

    /// @notice A keeper has announced a new price but it is not applied yet.
    function queueUpdate(uint256 nextPrice_) external {
        _nextPrice = nextPrice_;
        _pending = true;
    }

    function applyUpdate() external {
        require(_pending, "no pending");
        _price = _nextPrice;
        _lastUpdate = block.timestamp;
        _seq += 1;
        _pending = false;
    }
}
