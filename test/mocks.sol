// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

/// @dev The subset of forge's cheatcodes these tests use. Declared here rather than pulled in
/// from forge-std so the suite has no dependency beyond what package.json already installs.
interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function etch(address, bytes calldata) external;
    function expectRevert(bytes calldata) external;
}

/// @dev Minimal ERC20 with a known storage layout, so it can be vm.etch'ed onto the hard-coded
/// BSC mainnet addresses the contracts read in their constructors. Only the parts the payment
/// paths touch are real; the rest is stubbed.
contract MockERC20 {
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    uint8 public constant decimals = 18;
    function mint(address to, uint amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        uint a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        if (a != type(uint).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function totalSupply() external pure returns (uint) { return 0; }
    function transfer(address, uint) external pure returns (bool) { return true; }
}

/// @dev Just enough of a PancakeV3 pool for resolveCoaiIsToken0 and a flat TWAP.
contract MockPool {
    address public token0;
    address public token1;
    function setTokens(address a, address b) external { token0 = a; token1 = b; }
    /// tick 0 across the whole window => sqrtPriceX96 = 2^96 => 1 COAI = 1 quote token.
    function observe(uint32[] calldata secondsAgos) external pure returns (int56[] memory, uint160[] memory) {
        return (new int56[](secondsAgos.length), new uint160[](secondsAgos.length));
    }
}
