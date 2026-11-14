// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title DemoMUSD — clearly-labelled demo token for MUSD Goals (testnet only)
/// @notice This is NOT MUSD. It is a throwaway ERC-20 with a public faucet
///         so judges can run the full MUSD Goals flow in one click without
///         first borrowing real testnet MUSD. The production instance of
///         MUSDGoals is wired to the official MUSD contract instead.
/// @dev Dependency-free standard ERC-20. No owner, no admin, and the only
///      mint path is the public `faucet()` below.
contract DemoMUSD {
    string public constant name = "Demo MUSD (Testnet Demo Token)";
    string public constant symbol = "dMUSD";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Mint 1,000 dMUSD to the caller.
    /// @dev Intentionally no cooldown and no cap per call — this is a demo
    ///      token for judge UX on testnet; friction here would only hurt
    ///      evaluation. It has no value and no other mint path exists.
    function faucet() external {
        uint256 amount = 1000 * 1e18;
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        emit Transfer(address(0), msg.sender, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "DemoMUSD: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "DemoMUSD: transfer to zero address");
        require(balanceOf[from] >= amount, "DemoMUSD: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
