// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Swarm (SWORM)
/// @notice An ERC-20 with 18 decimals that burns 1% of every transfer.
/// @dev README: Deploy Swarm() to mint 1,000,000 tokens to the constructor caller,
/// then deploy BurnTracker(address(swarm)) to expose cumulative burns. There are
/// no dependencies, initialization calls, owner roles, exemptions or later mints.
/// Launch layout: Swarm is a fee-on-transfer token, so it is NOT the launch token.
/// A launch token must move exactly what it is asked to move and keep a constant
/// supply, which a 1% burn cannot do. SwarmLaunchToken (below in this file) is the
/// fixed-supply launch token; Swarm and BurnTracker deploy as application contracts
/// after it, in that order, and neither constructor touches the launch token.
/// Amounts and allowances use the smallest unit (10^-18 SWORM). Each transfer
/// burns floor(amount / 100) units and credits amount - burn to the recipient.
/// Integer rounding leaves any remainder with the recipient; amounts below 100
/// units burn zero. A self-transfer still requires the full amount as a balance
/// and reduces that balance only by the burn. Zero transfers emit Transfer.
/// transferFrom spends the gross amount of allowance; uint256.max is unlimited.
/// Zero-address transfers revert. Burns reduce totalSupply and emit Transfer to
/// address(0), whose balance remains zero. No calls to recipients are made.
/// Invariant: sum of balances == totalSupply <= INITIAL_SUPPLY.
/// Build: forge build. Local verification: forge test --gas-report.
/// Gas report (Forge 1.7.1, solc 0.8.26, optimizer disabled): deployment
/// 829,094 gas / 3,655 bytes of creation code; transfer of 100 SWORM to a fresh
/// recipient 59,761 gas; initial approval of 200 SWORM 46,542 gas; transferFrom
/// of 100 SWORM against that allowance 65,957 gas. Costs depend on storage state.
/// Local tests: 34 passing cases, including four fuzz tests with 256 runs each;
/// cover rounding, zero/self transfers, events, supply conservation, allowances,
/// rollback on failure, immutable burn tracking and absence of admin entrypoints.
contract Swarm {
    string public constant name = "Swarm";
    string public constant symbol = "SWORM";
    uint8 public constant decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 10 ** 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 available = allowance[from][msg.sender];
        if (available != type(uint256).max) {
            if (available < amount) revert ERC20InsufficientAllowance(msg.sender, available, amount);
            allowance[from][msg.sender] = available - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 available = balanceOf[from];
        if (available < amount) revert ERC20InsufficientBalance(from, available, amount);

        uint256 burned = amount / 100;
        uint256 received = amount - burned;
        balanceOf[from] = available - amount;
        // Read after debiting: from and to may be the same address.
        balanceOf[to] += received;
        totalSupply -= burned;

        emit Transfer(from, to, received);
        if (burned != 0) emit Transfer(from, address(0), burned);
    }
}

/// @title Swarm Launch Token (SWLT)
/// @notice The fixed-supply ERC-20 the project launches with. It has no burn.
/// @dev README: Deploy SwarmLaunchToken() with no arguments to mint exactly
/// 1,000,000,000 tokens (10^27 minor units, 18 decimals) to the constructor
/// caller, which at launch is the factory. Supply is fixed at construction: there
/// is no mint, owner, pause, upgrade or initialization path, and no constructor
/// arguments. transfer and transferFrom move exactly the requested amount and
/// never change totalSupply. Zero-address senders, recipients and spenders revert.
/// transferFrom spends allowance unless it is uint256.max. No calls are made to
/// recipients. This contract exists only so the launch token is not the
/// deflationary Swarm; it is not a wrapper of Swarm and the two are unrelated.
/// Invariant: sum of balances == totalSupply == TOTAL_SUPPLY, always.
/// Gas report (Forge 1.8.3, solc 0.8.26, optimizer disabled): deployment
/// 765,425 gas / 3,364 bytes of creation code; transfer to a fresh recipient
/// 52,252 gas; initial approval 46,542 gas; transferFrom 58,376 gas.
contract SwarmLaunchToken {
    string public constant name = "Swarm Launch Token";
    string public constant symbol = "SWLT";
    uint8 public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 available = allowance[from][msg.sender];
        if (available != type(uint256).max) {
            if (available < amount) revert ERC20InsufficientAllowance(msg.sender, available, amount);
            allowance[from][msg.sender] = available - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 available = balanceOf[from];
        if (available < amount) revert ERC20InsufficientBalance(from, available, amount);
        balanceOf[from] = available - amount;
        // Read after debiting: from and to may be the same address.
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
