// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Swarm} from "../src/Swarm.sol";
import {BurnTracker} from "../src/BurnTracker.sol";

// Only the Foundry cheatcodes used here are declared, so the suite needs no library.
interface SwarmVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function expectRevert() external;
    function expectRevert(bytes calldata reason) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @dev README (kept here because the assignment permits only these test files):
/// Deploy Swarm() to mint 1,000,000 SWORM to its caller, then deploy
/// BurnTracker(address(swarm)). Neither needs initialization or has an owner role.
/// All amounts and allowances are minor units (18 decimals). A transfer burns
/// floor(amount / 100), delivers the remainder and spends the gross allowance.
/// Self-transfers still need the gross balance and lose only the burned amount.
/// The tracker includes burns before its deployment; reads need no updates.
///
/// Run `forge build`, `forge test`, and `forge test --gas-report`. No dependencies
/// or configuration changes are needed. The suite has 51 tests, including five
/// fuzz tests (256 runs each by default), exact events, rounding boundaries,
/// allowance isolation, revert rollback, invalid tracker inputs and late binding.
/// Calls after expectRevert intentionally do not inspect a returned bool.
/// No test imports the removable protected harness. Its full-receipt, fixed-supply
/// launch requirement conflicts with Swarm's required burn; .imd-findings.json
/// records the concrete incompatibility. Passing these tests does not resolve it.
///
/// Gas report: Forge 1.7.1, solc 0.8.30, optimizer disabled. Reproduce the focused
/// sample with `forge test --gas-report --match-test
/// 'testTransfer(BurnsExactly|FromSpendsGross)'` (one shell command).
/// Swarm deployment: 829,094 gas, 3,655 creation bytes.
/// Transfer 100 SWORM to fresh ALICE: 59,759 gas.
/// Approve SPENDER for 200 SWORM from zero allowance: 46,540 gas.
/// TransferFrom 100 SWORM against that finite allowance: 65,954 gas.
/// BurnTracker deployment: 231,540 gas, 1,304 creation bytes.
/// BurnTracker.totalBurned(): 5,954 gas. Gas varies with state and calldata;
/// the full report also includes zero transfers, reverts and fuzzed inputs.
abstract contract SwarmTestBase {
    SwarmVm internal constant vm = SwarmVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant SUPPLY = 1_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);

    Swarm internal token;
    BurnTracker internal tracker;

    function setUp() public virtual {
        token = new Swarm();
        tracker = new BurnTracker(address(token));
    }

    function _eq(uint256 actual, uint256 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function _assertConservation() internal view {
        _eq(
            token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(SPENDER),
            token.totalSupply(),
            "balances must sum to supply"
        );
        _eq(token.totalSupply() + tracker.totalBurned(), SUPPLY, "supply plus burns must equal initial supply");
        _eq(token.balanceOf(address(0)), 0, "burns must not become a zero-address balance");
    }

    function _assertInitialState() internal view {
        _eq(token.balanceOf(address(this)), SUPPLY, "deployer balance changed");
        _eq(token.balanceOf(ALICE), 0, "Alice balance changed");
        _eq(token.balanceOf(BOB), 0, "Bob balance changed");
        _eq(token.balanceOf(SPENDER), 0, "spender balance changed");
        _eq(token.totalSupply(), SUPPLY, "supply changed");
        _eq(tracker.totalBurned(), 0, "burn counter changed");
        _assertConservation();
    }

    function _assertTransferLog(SwarmVm.Log memory entry, address emitter, address from, address to, uint256 amount)
        internal
        pure
    {
        require(entry.emitter == emitter, "wrong Transfer emitter");
        _eq(entry.topics.length, 3, "wrong Transfer topic count");
        require(entry.topics[0] == keccak256("Transfer(address,address,uint256)"), "wrong event signature");
        require(entry.topics[1] == bytes32(uint256(uint160(from))), "wrong Transfer sender");
        require(entry.topics[2] == bytes32(uint256(uint160(to))), "wrong Transfer recipient");
        _eq(abi.decode(entry.data, (uint256)), amount, "wrong Transfer amount");
    }
}

contract SwarmTest is SwarmTestBase {
    function testConstructorMetadataAndSupply() public view {
        require(keccak256(bytes(token.name())) == keccak256("Swarm"), "wrong name");
        require(keccak256(bytes(token.symbol())) == keccak256("SWORM"), "wrong symbol");
        _eq(token.decimals(), 18, "wrong decimals");
        _eq(token.INITIAL_SUPPLY(), SUPPLY, "wrong initial supply");
        _eq(token.allowance(address(this), SPENDER), 0, "initial allowance must be zero");
        _assertInitialState();
    }

    function testConstructorMintsOnlyToItsCallerAndEmitsMint() public {
        vm.recordLogs();
        vm.prank(ALICE);
        Swarm other = new Swarm();
        _eq(other.totalSupply(), SUPPLY, "wrong constructor supply");
        _eq(other.balanceOf(ALICE), SUPPLY, "constructor caller did not receive supply");
        _eq(other.balanceOf(address(this)), 0, "test contract received someone else's mint");
        _eq(other.balanceOf(address(0)), 0, "mint credited zero address");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "constructor must emit one mint");
        _assertTransferLog(entries[0], address(other), address(0), ALICE, SUPPLY);
    }

    function testTransferBurnsExactlyOnePercentAndEmitsNetAndBurn() public {
        vm.recordLogs();
        require(token.transfer(ALICE, 100 ether), "transfer returned false");
        _eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "sender must spend gross amount");
        _eq(token.balanceOf(ALICE), 99 ether, "recipient must receive 99 percent");
        _eq(token.totalSupply(), SUPPLY - 1 ether, "one token must be removed from supply");
        _eq(tracker.totalBurned(), 1 ether, "one token must be tracked");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 2, "expected delivery and burn events");
        _assertTransferLog(entries[0], address(token), address(this), ALICE, 99 ether);
        _assertTransferLog(entries[1], address(token), address(this), address(0), 1 ether);
        _assertConservation();
    }

    function testTransferEntireSupply() public {
        require(token.transfer(ALICE, SUPPLY), "transfer returned false");
        _eq(token.balanceOf(address(this)), 0, "sender must be empty");
        _eq(token.balanceOf(ALICE), 990_000 ether, "wrong full-supply receipt");
        _eq(token.totalSupply(), 990_000 ether, "wrong full-supply burn");
        _eq(tracker.totalBurned(), 10_000 ether, "wrong tracked full-supply burn");
        _assertConservation();
    }

    function testBurnRoundingAtMinorUnitBoundaries() public {
        uint256[9] memory amounts = [uint256(1), 99, 100, 101, 199, 200, 999, 10_001, 1 ether + 99];
        uint256[9] memory burns = [uint256(0), 0, 1, 1, 1, 2, 9, 100, 0.01 ether];
        uint256 gross;
        uint256 burned;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 previousSupply = token.totalSupply();
            require(token.transfer(ALICE, amounts[i]), "boundary transfer returned false");
            gross += amounts[i];
            burned += burns[i];
            _eq(previousSupply - token.totalSupply(), burns[i], "wrong per-transfer rounding");
            _eq(token.balanceOf(address(this)), SUPPLY - gross, "wrong cumulative debit");
            _eq(token.balanceOf(ALICE), gross - burned, "rounding remainder must reach recipient");
            _eq(tracker.totalBurned(), burned, "wrong cumulative rounded burn");
            _assertConservation();
        }
    }

    function testDustTransferEmitsDeliveryWithoutBurnEvent() public {
        vm.recordLogs();
        require(token.transfer(ALICE, 99), "dust transfer returned false");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "zero burn must not emit a burn event");
        _assertTransferLog(entries[0], address(token), address(this), ALICE, 99);
        _eq(token.totalSupply(), SUPPLY, "dust must not round burn up");
        _eq(token.balanceOf(ALICE), 99, "dust was lost");
        _assertConservation();
    }

    function testConsecutiveTransfersChargeEveryHolderIncludingDeployer() public {
        require(token.transfer(ALICE, 1_000 ether), "first transfer failed");
        vm.prank(ALICE);
        require(token.transfer(BOB, 400 ether), "second transfer failed");
        vm.prank(BOB);
        require(token.transfer(address(this), 200 ether), "third transfer failed");
        _eq(token.balanceOf(address(this)), SUPPLY - 802 ether, "wrong deployer balance after return transfer");
        _eq(token.balanceOf(ALICE), 590 ether, "wrong Alice balance");
        _eq(token.balanceOf(BOB), 196 ether, "wrong Bob balance");
        _eq(token.totalSupply(), SUPPLY - 16 ether, "all three burns must reduce supply");
        _eq(tracker.totalBurned(), 16 ether, "tracker must accumulate all three burns");
        _assertConservation();
    }

    function testZeroTransferFromFundedAccountEmitsTransferAndPreservesState() public {
        vm.recordLogs();
        require(token.transfer(ALICE, 0), "zero transfer returned false");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "zero transfer must emit one event");
        _assertTransferLog(entries[0], address(token), address(this), ALICE, 0);
        _assertInitialState();
    }

    function testZeroTransferFromUnfundedAccount() public {
        vm.recordLogs();
        vm.prank(ALICE);
        require(token.transfer(BOB, 0), "empty account cannot send zero");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "zero transfer must emit one event");
        _assertTransferLog(entries[0], address(token), ALICE, BOB, 0);
        _assertInitialState();
    }

    function testZeroSelfTransfer() public {
        require(token.transfer(address(this), 0), "funded zero self-transfer failed");
        vm.prank(ALICE);
        require(token.transfer(ALICE, 0), "unfunded zero self-transfer failed");
        _assertInitialState();
    }

    function testSelfTransferDebitsOnlyBurnAndEmitsBothEvents() public {
        vm.recordLogs();
        require(token.transfer(address(this), 100 ether), "self-transfer returned false");
        _eq(token.balanceOf(address(this)), SUPPLY - 1 ether, "self-transfer must lose only burn");
        _eq(token.totalSupply(), SUPPLY - 1 ether, "self-transfer must burn");
        _eq(tracker.totalBurned(), 1 ether, "self-transfer burn missing");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 2, "self-transfer must emit delivery and burn");
        _assertTransferLog(entries[0], address(token), address(this), address(this), 99 ether);
        _assertTransferLog(entries[1], address(token), address(this), address(0), 1 ether);
        _assertConservation();
    }

    function testSelfTransferEntireBalance() public {
        require(token.transfer(address(this), SUPPLY), "full-balance self-transfer failed");
        _eq(token.balanceOf(address(this)), 990_000 ether, "wrong self-transfer balance");
        _eq(token.totalSupply(), 990_000 ether, "wrong self-transfer supply");
        _assertConservation();
    }

    function testApproveEmitsEventAndReplacementAndRevocationDoNotBurn() public {
        vm.recordLogs();
        require(token.approve(SPENDER, 200 ether), "approve returned false");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "approval must emit exactly one event");
        require(entries[0].emitter == address(token), "wrong Approval emitter");
        _eq(entries[0].topics.length, 3, "wrong Approval topic count");
        require(entries[0].topics[0] == keccak256("Approval(address,address,uint256)"), "missing Approval event");
        require(entries[0].topics[1] == bytes32(uint256(uint160(address(this)))), "wrong Approval owner");
        require(entries[0].topics[2] == bytes32(uint256(uint160(SPENDER))), "wrong Approval spender");
        _eq(abi.decode(entries[0].data, (uint256)), 200 ether, "wrong Approval amount");
        _eq(token.allowance(address(this), SPENDER), 200 ether, "allowance not stored");
        require(token.approve(SPENDER, 50 ether), "replacement failed");
        _eq(token.allowance(address(this), SPENDER), 50 ether, "replacement must not add to allowance");
        require(token.approve(SPENDER, 0), "revocation failed");
        _eq(token.allowance(address(this), SPENDER), 0, "allowance not revoked");
        _assertInitialState();
    }

    function testTransferFromSpendsGrossAllowanceAndEmitsNetAndBurn() public {
        require(token.approve(SPENDER, 200 ether), "approval failed");
        vm.recordLogs();
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 100 ether), "transferFrom returned false");
        _eq(token.allowance(address(this), SPENDER), 100 ether, "allowance must decrease by gross amount");
        _eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "wrong owner debit");
        _eq(token.balanceOf(ALICE), 99 ether, "wrong delegated receipt");
        _eq(token.balanceOf(SPENDER), 0, "spender took tokens");
        _eq(token.totalSupply(), SUPPLY - 1 ether, "delegated burn missing");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 2, "expected delegated delivery and burn");
        _assertTransferLog(entries[0], address(token), address(this), ALICE, 99 ether);
        _assertTransferLog(entries[1], address(token), address(this), address(0), 1 ether);
        _assertConservation();
    }

    function testExactAllowanceCannotBeReused() public {
        require(token.approve(SPENDER, 100 ether), "approval failed");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 100 ether), "first delegated transfer failed");
        _eq(token.allowance(address(this), SPENDER), 0, "exact allowance not consumed");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        _eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "failed repeat changed owner balance");
        _eq(token.balanceOf(ALICE), 99 ether, "failed repeat changed recipient balance");
        _eq(tracker.totalBurned(), 1 ether, "failed repeat burned tokens");
        _assertConservation();
    }

    function testUnlimitedAllowanceSurvivesRepeatedSpending() public {
        require(token.approve(SPENDER, type(uint256).max), "approval failed");
        for (uint256 i; i < 2; ++i) {
            vm.prank(SPENDER);
            require(token.transferFrom(address(this), ALICE, 100 ether), "unlimited transfer failed");
            _eq(token.allowance(address(this), SPENDER), type(uint256).max, "unlimited allowance decreased");
        }
        _eq(token.balanceOf(address(this)), SUPPLY - 200 ether, "wrong repeated debit");
        _eq(token.balanceOf(ALICE), 198 ether, "wrong repeated receipt");
        _eq(tracker.totalBurned(), 2 ether, "repeated burns missing");
        _assertConservation();
    }

    function testTransferFromSelfBurnsAndConsumesGrossAllowance() public {
        require(token.approve(SPENDER, 100 ether), "approval failed");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), address(this), 100 ether), "delegated self-transfer failed");
        _eq(token.balanceOf(address(this)), SUPPLY - 1 ether, "delegated self-transfer balance wrong");
        _eq(token.allowance(address(this), SPENDER), 0, "self-transfer must consume gross allowance");
        _eq(tracker.totalBurned(), 1 ether, "delegated self-transfer burn missing");
        _assertConservation();
    }

    function testSpenderCanReceiveDelegatedTransfer() public {
        require(token.approve(SPENDER, 100 ether), "approval failed");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), SPENDER, 100 ether), "spender receipt failed");
        _eq(token.balanceOf(SPENDER), 99 ether, "wrong spender receipt");
        _eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "wrong owner debit");
        _eq(token.allowance(address(this), SPENDER), 0, "allowance not consumed");
        _assertConservation();
    }

    function testZeroTransferFromWithoutBalanceOrAllowance() public {
        vm.recordLogs();
        vm.prank(SPENDER);
        require(token.transferFrom(ALICE, BOB, 0), "zero delegated transfer failed");
        _eq(token.allowance(ALICE, SPENDER), 0, "zero transfer changed allowance");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "zero delegated transfer must emit one event");
        _assertTransferLog(entries[0], address(token), ALICE, BOB, 0);
        _assertInitialState();
    }

    function testTransferRejectsInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        _assertInitialState();
    }

    function testSelfTransferRequiresGrossBalanceEvenWhenBurnIsAffordable() public {
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(address(this), SUPPLY + 1);
        _assertInitialState();
    }

    function testTransferRejectsMaximumUintAmountWithoutOverflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max)
        );
        token.transfer(ALICE, type(uint256).max);
        _assertInitialState();
    }

    function testTransferRejectsZeroRecipientEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        _assertInitialState();
    }

    function testApproveRejectsZeroSpenderIncludingRevocation() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        _eq(token.allowance(address(this), address(0)), 0, "invalid approval changed allowance");
        _assertInitialState();
    }

    function testTransferFromRejectsMissingAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100 ether);
        _eq(token.allowance(address(this), SPENDER), 0, "failed transfer changed allowance");
        _assertInitialState();
    }

    function testTransferFromRequiresGrossAllowanceNotNetReceipt() public {
        require(token.approve(SPENDER, 99 ether), "approval failed");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 99 ether, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100 ether);
        _eq(token.allowance(address(this), SPENDER), 99 ether, "failed transfer spent allowance");
        _assertInitialState();
    }

    function testAllowanceIsBoundToBothOwnerAndSpender() public {
        require(token.approve(SPENDER, 100 ether), "approval failed");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, BOB, 0, 100 ether));
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        _eq(token.allowance(address(this), SPENDER), 100 ether, "unrelated caller spent allowance");
        _assertInitialState();
    }

    function testDeployerCannotBypassItsOwnTransferFromAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, address(this), 0, 100 ether));
        token.transferFrom(address(this), ALICE, 100 ether);
        _assertInitialState();
    }

    function testRevokedAllowanceCannotBeSpent() public {
        require(token.approve(SPENDER, type(uint256).max), "approval failed");
        require(token.approve(SPENDER, 0), "revocation failed");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        _eq(token.allowance(address(this), SPENDER), 0, "revocation was undone");
        _assertInitialState();
    }

    function testTransferFromBalanceFailureRollsBackAllowance() public {
        require(token.approve(SPENDER, SUPPLY + 1), "approval failed");
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, SUPPLY + 1);
        _eq(token.allowance(address(this), SPENDER), SUPPLY + 1, "balance failure consumed allowance");
        _assertInitialState();
    }

    function testTransferFromInvalidRecipientRollsBackAllowance() public {
        require(token.approve(SPENDER, 100 ether), "approval failed");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 100 ether);
        _eq(token.allowance(address(this), SPENDER), 100 ether, "receiver failure consumed allowance");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 0);
        _eq(token.allowance(address(this), SPENDER), 100 ether, "zero invalid transfer changed allowance");
        _assertInitialState();
    }

    function testTransferFromRejectsZeroSenderEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidSender.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), ALICE, 0);
        _eq(token.allowance(address(0), SPENDER), 0, "invalid sender allowance changed");
        _assertInitialState();
    }

    function testTransferFromMaximumAmountWithUnlimitedAllowanceRevertsOnBalance() public {
        require(token.approve(SPENDER, type(uint256).max), "approval failed");
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        _eq(token.allowance(address(this), SPENDER), type(uint256).max, "failed unlimited transfer changed allowance");
        _assertInitialState();
    }

    function testCommonAdminAndMintEntrypointsRejectBothDeployerAndStranger() public {
        bytes[9] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether),
            abi.encodeWithSignature("mint(uint256)", 1 ether),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("initialize(address)", ALICE),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("setOwner(address)", ALICE),
            abi.encodeWithSignature("setMinter(address)", ALICE),
            abi.encodeWithSignature("upgradeTo(address)", ALICE),
            abi.encodeWithSignature("setBurnRate(uint256)", 0)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(token).call(calls[i]);
            require(!deployerSucceeded, "deployer reached an unexpected admin entrypoint");
            vm.prank(ALICE);
            (bool strangerSucceeded,) = address(token).call(calls[i]);
            require(!strangerSucceeded, "stranger reached an unexpected admin entrypoint");
            _assertInitialState();
        }
    }

    function testFuzzTransferConservesSupply(uint256 seed) public {
        uint256 amount = seed % (SUPPLY + 1);
        uint256 burned = amount / 100;
        require(token.transfer(ALICE, amount), "fuzz transfer failed");
        _eq(token.balanceOf(address(this)), SUPPLY - amount, "fuzz sender debit wrong");
        _eq(token.balanceOf(ALICE), amount - burned, "fuzz recipient credit wrong");
        _eq(token.totalSupply(), SUPPLY - burned, "fuzz supply wrong");
        _eq(tracker.totalBurned(), burned, "fuzz tracked burn wrong");
        _assertConservation();
    }

    function testFuzzSelfTransferConservesSupply(uint256 seed) public {
        uint256 amount = seed % (SUPPLY + 1);
        uint256 burned = amount / 100;
        require(token.transfer(address(this), amount), "fuzz self-transfer failed");
        _eq(token.balanceOf(address(this)), SUPPLY - burned, "fuzz self-transfer balance wrong");
        _eq(token.totalSupply(), SUPPLY - burned, "fuzz self-transfer supply wrong");
        _eq(tracker.totalBurned(), burned, "fuzz self-transfer burn wrong");
        _assertConservation();
    }

    function testFuzzTransferFromConservesSupplyAndSpendsAllowance(uint256 amountSeed, uint256 extraSeed) public {
        uint256 amount = amountSeed % (SUPPLY + 1);
        uint256 approved = amount + extraSeed % (SUPPLY + 1);
        require(token.approve(SPENDER, approved), "fuzz approval failed");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, amount), "fuzz delegated transfer failed");
        _eq(token.allowance(address(this), SPENDER), approved - amount, "fuzz allowance debit wrong");
        _eq(token.balanceOf(address(this)), SUPPLY - amount, "fuzz delegated debit wrong");
        _eq(token.balanceOf(ALICE), amount - amount / 100, "fuzz delegated receipt wrong");
        _eq(tracker.totalBurned(), amount / 100, "fuzz delegated burn wrong");
        _assertConservation();
    }

    function testFuzzInsufficientAllowancePreservesState(uint256 amountSeed, uint256 allowanceSeed) public {
        uint256 amount = 1 + amountSeed % SUPPLY;
        uint256 approved = allowanceSeed % amount;
        require(token.approve(SPENDER, approved), "fuzz approval failed");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, approved, amount));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, amount);
        _eq(token.allowance(address(this), SPENDER), approved, "failed fuzz transfer spent allowance");
        _assertInitialState();
    }
}
