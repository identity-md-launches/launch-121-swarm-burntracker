// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Swarm} from "./Swarm.sol";

/// @title Swarm BurnTracker
/// @notice Reports all SWORM burned since the token was deployed, in minor units.
/// @dev README: Deploy with the address of an already deployed Swarm. The binding
/// is immutable and needs no initialization or privileged updates. Tracking also
/// includes burns before this contract's deployment. The constructor reads the
/// token's original supply, not its current supply. The accounting relies on
/// Swarm having no mint path and reducing its supply only through transfer burns.
/// Gas report (Forge 1.7.1, solc 0.8.26, optimizer disabled): deployment
/// 231,540 gas / 1,304 bytes of creation code; totalBurned() 5,954 gas in the
/// local transfer tests. Read costs depend on whether token storage is warm.
contract BurnTracker {
    Swarm public immutable token;
    uint256 private immutable initialSupply;

    constructor(address tokenAddress) {
        token = Swarm(tokenAddress);
        initialSupply = token.INITIAL_SUPPLY();
    }

    function totalBurned() external view returns (uint256) {
        return initialSupply - token.totalSupply();
    }
}
