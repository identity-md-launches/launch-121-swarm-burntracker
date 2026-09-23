// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Swarm, SwarmLaunchToken} from "../src/Swarm.sol";
import {BurnTracker} from "../src/BurnTracker.sol";
import {SwarmTestBase} from "./Swarm.t.sol";

contract BurnTrackerTest is SwarmTestBase {
    function testConstructorBindsTokenAndStartsAtZero() public view {
        require(address(tracker.token()) == address(token), "tracker bound to wrong token");
        _eq(tracker.totalBurned(), 0, "fresh token has no burns");
        _assertInitialState();
    }

    function testProjectConstructorsPreserveLaunchSupplyAndBindTrackerToSwarm() public {
        // BOB represents the same factory caller for all three constructors.
        vm.prank(BOB);
        SwarmLaunchToken launchToken = new SwarmLaunchToken();
        _eq(launchToken.balanceOf(BOB), 1_000_000_000 ether, "factory did not receive launch supply");
        vm.prank(BOB);
        Swarm application = new Swarm();
        _eq(launchToken.totalSupply(), 1_000_000_000 ether, "Swarm constructor changed launch supply");
        _eq(launchToken.balanceOf(BOB), 1_000_000_000 ether, "Swarm constructor moved factory launch balance");
        vm.prank(BOB);
        BurnTracker applicationTracker = new BurnTracker(address(application));
        _eq(launchToken.totalSupply(), 1_000_000_000 ether, "tracker constructor changed launch supply");
        _eq(launchToken.balanceOf(BOB), 1_000_000_000 ether, "tracker constructor moved factory launch balance");
        _eq(application.balanceOf(BOB), SUPPLY, "factory did not receive Swarm supply");
        _eq(application.totalSupply(), SUPPLY, "wrong application supply");
        require(address(applicationTracker.token()) == address(application), "tracker bound to launch token");
        _eq(applicationTracker.totalBurned(), 0, "new application already reports burns");
    }

    function testLaunchTransfersAndSwarmBurnsRemainIndependent() public {
        SwarmLaunchToken launchToken = new SwarmLaunchToken();
        require(token.transfer(ALICE, 100 ether), "Swarm transfer failed");
        require(launchToken.transfer(ALICE, 100 ether), "launch transfer failed");
        require(launchToken.approve(SPENDER, 200 ether), "launch approval failed");
        vm.prank(SPENDER);
        require(launchToken.transferFrom(address(this), BOB, 200 ether), "launch delegated transfer failed");
        _eq(tracker.totalBurned(), 1 ether, "launch activity changed Swarm burns");
        _eq(token.balanceOf(ALICE), 99 ether, "Swarm must still burn one percent");
        _assertConservation();
        vm.prank(ALICE);
        require(token.transfer(ALICE, 99 ether), "Swarm self-transfer failed");
        _eq(tracker.totalBurned(), 1.99 ether, "Swarm self-transfer burn missing");
        _eq(launchToken.totalSupply(), 1_000_000_000 ether, "Swarm burns reduced launch supply");
        _eq(launchToken.balanceOf(address(this)), 1_000_000_000 ether - 300 ether, "wrong launch debit");
        _eq(launchToken.balanceOf(ALICE), 100 ether, "launch receipt incurred a burn");
        _eq(launchToken.balanceOf(BOB), 200 ether, "launch delegated receipt incurred a burn");
        _assertConservation();
    }

    function testConstructorRejectsLaunchTokenInPlaceOfSwarm() public {
        SwarmLaunchToken launchToken = new SwarmLaunchToken();
        vm.expectRevert();
        new BurnTracker(address(launchToken));
        _eq(launchToken.totalSupply(), 1_000_000_000 ether, "failed tracker constructor changed launch supply");
        _eq(
            launchToken.balanceOf(address(this)), 1_000_000_000 ether, "failed tracker constructor moved launch balance"
        );
        _assertInitialState();
    }

    function testTrackerAccumulatesDirectDelegatedAndSelfTransferBurns() public {
        require(token.transfer(ALICE, 1_000 ether), "direct transfer failed");
        _eq(tracker.totalBurned(), 10 ether, "direct burn missing");
        require(token.approve(SPENDER, 250 ether), "approval failed");
        _eq(tracker.totalBurned(), 10 ether, "approval changed burn counter");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), BOB, 250 ether), "delegated transfer failed");
        _eq(tracker.totalBurned(), 12.5 ether, "delegated burn missing");
        vm.prank(ALICE);
        require(token.transfer(ALICE, 100 ether), "self-transfer failed");
        _eq(tracker.totalBurned(), 13.5 ether, "self-transfer burn missing");
        _eq(token.totalSupply(), SUPPLY - 13.5 ether, "wrong supply after three burns");
        _assertConservation();
    }

    function testLateDeploymentIncludesEarlierBurnsAndContinuesTracking() public {
        require(token.transfer(ALICE, 1_000 ether), "first transfer failed");
        vm.prank(ALICE);
        require(token.transfer(ALICE, 100 ether), "self-transfer failed");
        vm.prank(BOB);
        BurnTracker late = new BurnTracker(address(token));
        require(address(late.token()) == address(token), "late tracker bound to wrong token");
        _eq(late.totalBurned(), 11 ether, "late tracker forgot predeployment burns");
        require(token.transfer(BOB, 200 ether), "later transfer failed");
        _eq(late.totalBurned(), 13 ether, "late tracker failed to update");
        _eq(tracker.totalBurned(), 13 ether, "early and late trackers disagree");
        _assertConservation();
    }

    function testRepeatedReadsByAnyCallerDoNotResetBurns() public {
        require(token.transfer(ALICE, 100 ether), "transfer failed");
        _eq(tracker.totalBurned(), 1 ether, "first read wrong");
        vm.prank(ALICE);
        uint256 aliceRead = tracker.totalBurned();
        vm.prank(BOB);
        uint256 bobRead = tracker.totalBurned();
        _eq(aliceRead, 1 ether, "holder cannot read burns");
        _eq(bobRead, 1 ether, "nonholder cannot read burns");
        _eq(tracker.totalBurned(), 1 ether, "reads reset burns");
        _assertConservation();
    }

    function testTrackersForDifferentTokensRemainIndependent() public {
        Swarm secondToken = new Swarm();
        BurnTracker secondTracker = new BurnTracker(address(secondToken));
        require(token.transfer(ALICE, 100 ether), "first token transfer failed");
        _eq(secondTracker.totalBurned(), 0, "first token affected second tracker");
        require(secondToken.transfer(BOB, 300 ether), "second token transfer failed");
        _eq(tracker.totalBurned(), 1 ether, "second token affected first tracker");
        _eq(secondTracker.totalBurned(), 3 ether, "second tracker counted wrong burn");
        require(address(tracker.token()) == address(token), "first binding changed");
        require(address(secondTracker.token()) == address(secondToken), "second binding wrong");
        _eq(secondToken.totalSupply(), SUPPLY - 3 ether, "second token supply wrong");
        _assertConservation();
    }

    function testZeroAndDustTransfersAndApprovalsDoNotChangeExistingBurns() public {
        require(token.transfer(ALICE, 100 ether), "initial transfer failed");
        require(token.transfer(ALICE, 0), "zero transfer failed");
        require(token.transfer(ALICE, 99), "dust transfer failed");
        vm.prank(ALICE);
        require(token.transfer(ALICE, 1), "dust self-transfer failed");
        require(token.approve(SPENDER, type(uint256).max), "approval failed");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), BOB, 0), "zero delegated transfer failed");
        _eq(tracker.totalBurned(), 1 ether, "zero-burn operations changed cumulative burns");
        _eq(token.totalSupply(), SUPPLY - 1 ether, "zero-burn operations changed supply");
        _assertConservation();
    }

    function testRoundingIsAppliedPerTransferAndTrackerSumsActualBurns() public {
        require(token.transfer(ALICE, 199), "first rounded transfer failed");
        require(token.transfer(ALICE, 199), "second rounded transfer failed");
        _eq(token.balanceOf(ALICE), 396, "wrong total rounded receipt");
        _eq(tracker.totalBurned(), 2, "tracker must sum burns, not round aggregate volume");
        _eq(token.totalSupply(), SUPPLY - 2, "wrong rounded supply");
        _assertConservation();
    }

    function testRevertedTransfersDoNotChangePreviouslyAccumulatedBurns() public {
        require(token.transfer(ALICE, 100 ether), "initial transfer failed");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, ALICE, 99 ether, 100 ether));
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 100 ether);
        _eq(tracker.totalBurned(), 1 ether, "reverts changed accumulated burns");
        _eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "reverts changed owner balance");
        _eq(token.balanceOf(ALICE), 99 ether, "reverts changed holder balance");
        _eq(token.balanceOf(BOB), 0, "reverts credited recipient");
        _assertConservation();
    }

    function testConstructorRejectsZeroAddress() public {
        vm.expectRevert();
        new BurnTracker(address(0));
        _assertInitialState();
    }

    function testConstructorRejectsAccountWithoutCode() public {
        vm.expectRevert();
        new BurnTracker(ALICE);
        _assertInitialState();
    }

    function testConstructorRejectsContractWithoutSupplyInterface() public {
        vm.expectRevert();
        new BurnTracker(address(tracker));
        _assertInitialState();
    }

    function testNeitherDeployerNorStrangerCanRebindOrResetTracker() public {
        require(token.transfer(ALICE, 100 ether), "initial transfer failed");
        Swarm secondToken = new Swarm();
        bytes[4] memory calls = [
            abi.encodeWithSignature("setToken(address)", address(secondToken)),
            abi.encodeWithSignature("initialize(address)", address(secondToken)),
            abi.encodeWithSignature("reset()"),
            abi.encodeWithSignature("recordBurn(uint256)", 100 ether)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(tracker).call(calls[i]);
            require(!deployerSucceeded, "deployer modified tracker");
            vm.prank(BOB);
            (bool strangerSucceeded,) = address(tracker).call(calls[i]);
            require(!strangerSucceeded, "stranger modified tracker");
            require(address(tracker.token()) == address(token), "tracker token binding changed");
            _eq(tracker.totalBurned(), 1 ether, "tracker cumulative burn changed");
        }
        _assertConservation();
    }

    function testFuzzTransferSequenceMaintainsCumulativeBurns(uint256[12] memory seeds) public {
        // Cycle among actual holders and self-transfers, with a tracker created
        // halfway through. Model each burn independently of the tracker reads.
        address[3] memory holders = [address(this), ALICE, BOB];
        uint256[3] memory balances = [SUPPLY, uint256(0), uint256(0)];
        uint256 burned;
        BurnTracker late;
        for (uint256 i; i < seeds.length; ++i) {
            uint256 from = i % 3;
            uint256 to = i % 4 == 3 ? from : (from + 1) % 3;
            uint256 amount = seeds[i] % (balances[from] + 1);
            uint256 burn = amount / 100;
            balances[from] -= amount;
            balances[to] += amount - burn;
            uint256 previousBurned = tracker.totalBurned();
            vm.prank(holders[from]);
            require(token.transfer(holders[to], amount), "sequence transfer failed");
            burned += burn;
            _eq(tracker.totalBurned(), burned, "sequence cumulative burn wrong");
            require(tracker.totalBurned() >= previousBurned, "cumulative burn decreased");
            _eq(token.totalSupply(), SUPPLY - burned, "sequence supply wrong");
            for (uint256 j; j < holders.length; ++j) {
                _eq(token.balanceOf(holders[j]), balances[j], "sequence holder balance wrong");
            }
            if (i == 5) late = new BurnTracker(address(token));
            if (address(late) != address(0)) _eq(late.totalBurned(), burned, "late sequence tracker wrong");
            _assertConservation();
        }
    }
}
