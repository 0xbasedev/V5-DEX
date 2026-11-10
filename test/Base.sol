// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// The cheatcodes these tests use. Declared here so the suite needs no test library.
interface Vm {
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function assume(bool) external pure;
    function assertEq(uint256, uint256, string calldata) external pure;
    function assertEq(address, address, string calldata) external pure;
    function assertTrue(bool, string calldata) external pure;
    function assertGe(uint256, uint256, string calldata) external pure;
    function assertLe(uint256, uint256, string calldata) external pure;
    function assertGt(uint256, uint256, string calldata) external pure;
    function assertLt(uint256, uint256, string calldata) external pure;
    function assertApproxEqAbs(uint256, uint256, uint256, string calldata) external pure;
}

abstract contract Base {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant WAD = 1e18;

    /// Move the clock forward. The time is read through the cheatcode, not
    /// from `block.timestamp`: the optimiser assumes the timestamp cannot
    /// change inside one call, which a test that warps makes untrue.
    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + x % (hi - lo + 1);
    }
}

contract Token {
    string public name;
    uint8 public decimals = 18;

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
