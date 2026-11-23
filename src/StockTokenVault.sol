// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Mock equity oracle interface. All values use 1e18 fixed point.
interface IEquityOracle {
    function price() external view returns (uint256);
    function confidence() external view returns (uint256); // absolute half-width, 1e18 scale
    function lastUpdate() external view returns (uint256); // unix seconds
    function seq() external view returns (uint256); // monotonic update counter
    function pendingUpdate() external view returns (bool); // an update is queued but not applied
}

interface IERC20Minimal {
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title StockTokenVault
/// @notice Minimal USDC mint/redeem vault priced by an equity oracle.
/// @dev Educational PoC only. Guards can be toggled per deployment so tests can
///      show the same attack with and without each guard. Prices and shares use
///      1e18 fixed point; the underlying asset's own decimals are read at deploy
///      time. Market hours are US Eastern with the standard US DST rule, but
///      exchange holidays and early closes are NOT handled.
contract StockTokenVault {
    uint256 public constant SCALE = 1e18; // price and share fixed point

    struct GuardConfig {
        bool marketHours;
        bool staleness;
        bool confidence;
        bool pendingUpdate;
        uint256 maxPriceAge;
        uint256 maxConfidenceBps;
        uint256 marketOpenUtcMinute; // WINTER (EST, UTC-5) session open, UTC minutes
        uint256 marketCloseUtcMinute; // WINTER (EST, UTC-5) session close, UTC minutes
    }

    error MarketClosed();
    error StalePrice();
    error FutureTimestamp();
    error ConfidenceTooWide();
    error PendingOracleUpdate();
    error ZeroPrice();
    error ZeroShares();
    error TransferFailed();
    error InsufficientShares();
    error InsufficientAllowance();

    IERC20Minimal public immutable usdc;
    IEquityOracle public immutable oracle;
    uint8 public immutable usdcDecimals;
    uint256 public immutable assetScale; // 10 ** usdcDecimals

    bool public immutable guardMarketHours;
    bool public immutable guardStaleness;
    bool public immutable guardConfidence;
    bool public immutable guardPendingUpdate;
    uint256 public immutable maxPriceAge;
    uint256 public immutable maxConfidenceBps;
    uint256 public immutable marketOpenUtcMinute;
    uint256 public immutable marketCloseUtcMinute;

    string public constant name = "Weekend Gap Vault Share";
    string public constant symbol = "WGV";
    uint8 public constant decimals = 18; // share decimals, independent of USDC decimals
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Mint(address indexed user, uint256 usdcAmount, uint256 shares, uint256 price);
    event Redeem(address indexed user, uint256 shares, uint256 usdcAmount, uint256 price);

    constructor(IERC20Minimal usdc_, IEquityOracle oracle_, GuardConfig memory cfg_) {
        usdc = usdc_;
        oracle = oracle_;
        usdcDecimals = usdc_.decimals();
        assetScale = 10 ** uint256(usdcDecimals);
        guardMarketHours = cfg_.marketHours;
        guardStaleness = cfg_.staleness;
        guardConfidence = cfg_.confidence;
        guardPendingUpdate = cfg_.pendingUpdate;
        maxPriceAge = cfg_.maxPriceAge;
        maxConfidenceBps = cfg_.maxConfidenceBps;
        marketOpenUtcMinute = cfg_.marketOpenUtcMinute;
        marketCloseUtcMinute = cfg_.marketCloseUtcMinute;
    }

    // --------------------------------------------------------------------- //
    // Guards
    // --------------------------------------------------------------------- //
    /// @notice Reverts unless every enabled guard accepts the current quote.
    function guardedPrice() public view returns (uint256 price) {
        _checkMarketHours();
        uint256 lastUpdate = oracle.lastUpdate();
        if (lastUpdate > block.timestamp) revert FutureTimestamp();
        _checkFreshness(lastUpdate);
        price = oracle.price();
        if (price == 0) revert ZeroPrice();
        _checkConfidence(price);
        _checkPending();
    }

    function _checkMarketHours() internal view {
        if (guardMarketHours && !isMarketOpen(block.timestamp)) revert MarketClosed();
    }

    function _checkFreshness(uint256 lastUpdate) internal view {
        if (guardStaleness && block.timestamp > lastUpdate + maxPriceAge) revert StalePrice();
    }

    function _checkConfidence(uint256 price) internal view {
        if (guardConfidence && oracle.confidence() > (price * maxConfidenceBps) / 10_000) {
            revert ConfidenceTooWide();
        }
    }

    function _checkPending() internal view {
        if (guardPendingUpdate && oracle.pendingUpdate()) revert PendingOracleUpdate();
    }

    // --------------------------------------------------------------------- //
    // Market hours (US Eastern, DST aware)
    // --------------------------------------------------------------------- //
    /// @notice True during the Mon-Fri US cash session at `timestamp`.
    /// @dev The configured UTC minutes describe the EST (UTC-5) window. During
    ///      EDT (UTC-4) the equivalent UTC window is one hour earlier; this is
    ///      derived by shifting to Eastern local time first. Exchange holidays
    ///      and early closes are not handled.
    function isMarketOpen(uint256 timestamp) public view returns (bool) {
        uint256 offset = isUsDst(timestamp) ? 4 hours : 5 hours;
        uint256 localTs = timestamp - offset;
        uint256 localDayIndex = (localTs / 1 days + 3) % 7; // 0 = Monday ... 4 = Friday
        uint256 localMinute = (localTs % 1 days) / 60;
        uint256 openLocalMinute = marketOpenUtcMinute - 5 * 60; // 14:30 UTC -> 09:30 EST/EDT
        uint256 closeLocalMinute = marketCloseUtcMinute - 5 * 60; // 21:00 UTC -> 16:00 EST/EDT
        return localDayIndex <= 4 && localMinute >= openLocalMinute && localMinute < closeLocalMinute;
    }

    /// @notice US daylight saving: second Sunday of March to first Sunday of November.
    function isUsDst(uint256 timestamp) public pure returns (bool) {
        uint256 day = timestamp / 1 days;
        (uint256 year,,) = _civilFromDays(day);
        return day >= _nthSunday(year, 3, 2) && day < _nthSunday(year, 11, 1);
    }

    function _nthSunday(uint256 year, uint256 month, uint256 nth) internal pure returns (uint256) {
        uint256 firstOfMonth = _daysFromCivil(year, month, 1);
        uint256 dow = (firstOfMonth + 3) % 7; // 0 = Monday ... 6 = Sunday
        return firstOfMonth + ((6 - dow + 7) % 7) + (nth - 1) * 7;
    }

    // Days-from-civil / civil-from-days (Howard Hinnant's algorithms, shifted to
    // the Unix epoch). Used only to locate the two DST transition Sundays.
    function _daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        y -= (m <= 2) ? 1 : 0;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = (m > 2) ? (m - 3) : (m + 9);
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    function _civilFromDays(uint256 z_) internal pure returns (uint256 y, uint256 m, uint256 d) {
        uint256 z = z_ + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = (mp < 10) ? (mp + 3) : (mp - 9);
        y += (m <= 2) ? 1 : 0;
    }

    // --------------------------------------------------------------------- //
    // Mint / redeem
    // --------------------------------------------------------------------- //
    /// @notice Shares are 18-decimal; USDC amounts use the asset's own decimals.
    function previewMint(uint256 usdcAmount) public view returns (uint256 shares) {
        uint256 price = guardedPrice();
        shares = (usdcAmount * SCALE * SCALE) / (price * assetScale);
    }

    function previewRedeem(uint256 shares) public view returns (uint256 usdcAmount) {
        uint256 price = guardedPrice();
        usdcAmount = (shares * price * assetScale) / (SCALE * SCALE);
    }

    function mint(uint256 usdcAmount) external returns (uint256 shares) {
        uint256 price = guardedPrice();
        shares = (usdcAmount * SCALE * SCALE) / (price * assetScale);
        if (shares == 0) revert ZeroShares();
        if (!usdc.transferFrom(msg.sender, address(this), usdcAmount)) revert TransferFailed();
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
        emit Mint(msg.sender, usdcAmount, shares, price);
    }

    function redeem(uint256 shares) external returns (uint256 usdcAmount) {
        if (shares == 0) revert ZeroShares();
        uint256 price = guardedPrice();
        if (balanceOf[msg.sender] < shares) revert InsufficientShares();
        usdcAmount = (shares * price * assetScale) / (SCALE * SCALE);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        if (!usdc.transfer(msg.sender, usdcAmount)) revert TransferFailed();
        emit Redeem(msg.sender, shares, usdcAmount, price);
    }

    // Minimal share transfer support so a mock lender can hold collateral.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientShares();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) revert InsufficientShares();
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}
