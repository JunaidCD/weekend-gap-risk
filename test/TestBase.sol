// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal cheatcode surface used by the PoCs. No URLs, keys or RPC config.
interface Vm {
    function warp(uint256 timestamp) external;
    function prank(address caller) external;
    function expectRevert(bytes4 errorSelector) external;
}

/// @notice Tiny local replacement for forge-std/Test: just the helpers we use.
contract TestBase {
    // Fixed Foundry cheatcode address.
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function makeAddr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }

    function bound(uint256 value, uint256 lower, uint256 upper) internal pure returns (uint256) {
        require(lower <= upper, "bad bounds");
        return lower + (value % (upper - lower + 1));
    }

    function assertEq(uint256 left, uint256 right) internal pure {
        require(left == right, "assertEq failed");
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertLt(uint256 left, uint256 right) internal pure {
        require(left < right, "assertLt failed");
    }

    function assertLt(uint256 left, uint256 right, string memory message) internal pure {
        require(left < right, message);
    }

    function assertGe(uint256 left, uint256 right) internal pure {
        require(left >= right, "assertGe failed");
    }

    function assertGe(uint256 left, uint256 right, string memory message) internal pure {
        require(left >= right, message);
    }

    function assertApproxEqAbs(uint256 left, uint256 right, uint256 delta, string memory message) internal pure {
        uint256 diff = left > right ? left - right : right - left;
        require(diff <= delta, message);
    }
}
