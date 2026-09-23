// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Swarm, SwarmLaunchToken, SwarmConverter} from "../src/Swarm.sol";
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
/// or configuration changes are needed. The suite has 80 tests, including seven
/// fuzz tests (256 runs each by default), exact events, rounding boundaries,
/// allowance isolation, revert rollback, invalid tracker inputs and late binding.
/// Calls after expectRevert intentionally do not inspect a returned bool.
/// No test imports the removable protected harness. SwarmLaunchToken() supplies
/// the separate fixed-supply launch token: 1,000,000,000 SWLT with 18 decimals,
/// minted to its constructor caller. Deploy SwarmConverter(address(launchToken))
/// as the application; read its swarm() and burnTracker() child addresses. The
/// converter receives the initial SWORM supply, leaving factory SWLT untouched.
/// Holders approve the converter for SWLT and call convert(launchAmount), a
/// positive multiple of 1,000 minor units. It returns gross SWORM; the holder
/// receives that amount minus floor(amount / 100). To redeem, approve SWORM
/// and call redeem(grossSwarmAmount); it returns/pays 1,000 times the SWORM
/// actually received after the second burn. Both burns are irreversible.
/// Donations receive no conversion credit and there is no rescue/admin path.
/// The tests use the actual fixed-supply launch token, as required at deployment.
/// The added launch tests cover exact receipt, fixed supply, allowance failures,
/// zero/self transfers, mint/admin rejection and constructor isolation.
/// Converter coverage adds holder access, both burn legs, donation accounting,
/// supply exhaustion, invalid construction, allowance/balance rollback and
/// fuzzed round trips. Existing Swarm and launch-token unit tests are retained.
///
/// Gas report: Forge 1.7.1, solc 0.8.30, optimizer disabled. Reproduce the focused
/// sample with `forge test --gas-report --match-test
/// 'testTransfer(BurnsExactly|FromSpendsGross)'` (one shell command).
/// Swarm deployment: 829,082 gas, 3,655 creation bytes.
/// Transfer 100 SWORM to fresh ALICE: 59,759 gas.
/// Approve SPENDER for 200 SWORM from zero allowance: 46,540 gas.
/// TransferFrom 100 SWORM against that finite allowance: 65,954 gas.
/// BurnTracker deployment: 231,540 gas, 1,304 creation bytes.
/// BurnTracker.totalBurned(): 5,954 gas. Gas varies with state and calldata;
/// the full report also includes zero transfers, reverts and fuzzed inputs.
/// Launch sample: `forge test --gas-report --match-test
/// testLaunchTransfersAndSwarmBurnsRemainIndependent` (one shell command).
/// SwarmLaunchToken deployment: 774,307 gas, 3,405 creation bytes.
/// Transfer 100 SWLT to fresh ALICE: 52,191 gas.
/// Approve SPENDER for 200 SWLT from zero allowance: 46,540 gas.
/// TransferFrom 200 SWLT to fresh BOB, exhausting allowance: 53,574 gas.
/// Converter sample: `forge test --gas-report --match-test
/// testRedeemPaysForNetSwarmAndEmitsRedemption` (one shell command).
/// SwarmConverter deployment including its children: 1,712,048 gas,
/// 8,958 creation bytes including constructor arguments.
/// Convert 100,000 SWLT with exact allowance, emptying the holder: 96,322 gas.
/// Redeem the resulting 99 SWORM with exact allowance: 82,330 gas.
/// Measurements use solc 0.8.30; both legs include their token calls.
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

/// @dev Regression coverage for the separate launch token added after the
/// original Swarm suite. Keep its fixed-supply expectations distinct from SWORM.
contract SwarmLaunchTokenTest is SwarmTestBase {
    uint256 internal constant LAUNCH_SUPPLY = 1_000_000_000 ether;
    SwarmLaunchToken internal launchToken;

    function setUp() public override {
        launchToken = new SwarmLaunchToken();
        super.setUp();
    }

    function _assertLaunchBalances(uint256 ownerBalance, uint256 aliceBalance, uint256 bobBalance) internal view {
        _eq(launchToken.totalSupply(), LAUNCH_SUPPLY, "launch supply must remain fixed");
        _eq(launchToken.balanceOf(address(this)), ownerBalance, "wrong launch deployer balance");
        _eq(launchToken.balanceOf(ALICE), aliceBalance, "wrong launch Alice balance");
        _eq(launchToken.balanceOf(BOB), bobBalance, "wrong launch Bob balance");
        _eq(launchToken.balanceOf(SPENDER), 0, "launch spender took tokens");
        _eq(launchToken.balanceOf(address(0)), 0, "launch credited zero address");
        _eq(ownerBalance + aliceBalance + bobBalance, LAUNCH_SUPPLY, "launch balances do not conserve supply");
        _assertInitialState();
    }

    function testLaunchConstructorMetadataSupplyAndMintEvent() public {
        require(keccak256(bytes(launchToken.name())) == keccak256("Swarm Launch Token"), "wrong launch name");
        require(keccak256(bytes(launchToken.symbol())) == keccak256("SWLT"), "wrong launch symbol");
        _eq(launchToken.decimals(), 18, "wrong launch decimals");
        _eq(launchToken.TOTAL_SUPPLY(), LAUNCH_SUPPLY, "wrong launch supply constant");
        _eq(launchToken.allowance(address(this), SPENDER), 0, "launch starts with allowance");
        _assertLaunchBalances(LAUNCH_SUPPLY, 0, 0);

        vm.recordLogs();
        vm.prank(ALICE);
        SwarmLaunchToken other = new SwarmLaunchToken();
        _eq(other.totalSupply(), LAUNCH_SUPPLY, "wrong other launch supply");
        _eq(other.balanceOf(ALICE), LAUNCH_SUPPLY, "launch mint did not reach constructor caller");
        _eq(other.balanceOf(address(this)), 0, "launch mint reached the wrong deployer");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "launch constructor must emit one mint");
        _assertTransferLog(entries[0], address(other), address(0), ALICE, LAUNCH_SUPPLY);
    }

    function testLaunchTransferMovesExactAmountWithoutBurn() public {
        // The protected token floor uses this exact fraction of initial supply.
        uint256 amount = LAUNCH_SUPPLY / 1_000;
        vm.recordLogs();
        require(launchToken.transfer(ALICE, amount), "launch transfer returned false");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "launch transfer emitted an extra event");
        _assertTransferLog(entries[0], address(launchToken), address(this), ALICE, amount);
        _assertLaunchBalances(LAUNCH_SUPPLY - amount, amount, 0);
    }

    function testLaunchEntireSupplyAndRepeatedSelfTransfersPreserveBalances() public {
        require(launchToken.transfer(ALICE, LAUNCH_SUPPLY), "launch full-supply transfer failed");
        for (uint256 i; i < 2; ++i) {
            vm.recordLogs();
            vm.prank(ALICE);
            require(launchToken.transfer(ALICE, LAUNCH_SUPPLY), "launch self-transfer failed");
            SwarmVm.Log[] memory entries = vm.getRecordedLogs();
            _eq(entries.length, 1, "launch self-transfer must emit one event");
            _assertTransferLog(entries[0], address(launchToken), ALICE, ALICE, LAUNCH_SUPPLY);
            _assertLaunchBalances(0, LAUNCH_SUPPLY, 0);
        }
    }

    function testLaunchZeroTransfersWithoutBalanceOrAllowanceEmitEvents() public {
        vm.recordLogs();
        vm.prank(ALICE);
        require(launchToken.transfer(BOB, 0), "launch zero transfer failed");
        vm.prank(SPENDER);
        require(launchToken.transferFrom(ALICE, ALICE, 0), "launch delegated zero self-transfer failed");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 2, "launch zero transfers must each emit an event");
        _assertTransferLog(entries[0], address(launchToken), ALICE, BOB, 0);
        _assertTransferLog(entries[1], address(launchToken), ALICE, ALICE, 0);
        _eq(launchToken.allowance(ALICE, SPENDER), 0, "launch zero transfer changed allowance");
        _assertLaunchBalances(LAUNCH_SUPPLY, 0, 0);
    }

    function testLaunchTransferFromUsesExactAllowanceAndRejectsReuse() public {
        require(launchToken.approve(SPENDER, 100 ether), "launch approval failed");
        vm.recordLogs();
        vm.prank(SPENDER);
        require(launchToken.transferFrom(address(this), ALICE, 100 ether), "launch delegated transfer failed");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 1, "launch delegated transfer must emit one event");
        _assertTransferLog(entries[0], address(launchToken), address(this), ALICE, 100 ether);
        _eq(launchToken.allowance(address(this), SPENDER), 0, "launch exact allowance not consumed");
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        launchToken.transferFrom(address(this), ALICE, 1);
        _assertLaunchBalances(LAUNCH_SUPPLY - 100 ether, 100 ether, 0);
    }

    function testLaunchUnlimitedAllowanceSurvivesDelegatedSelfAndRepeatedTransfers() public {
        require(launchToken.approve(SPENDER, type(uint256).max), "launch unlimited approval failed");
        vm.prank(SPENDER);
        require(
            launchToken.transferFrom(address(this), address(this), LAUNCH_SUPPLY),
            "launch delegated self-transfer failed"
        );
        _assertLaunchBalances(LAUNCH_SUPPLY, 0, 0);
        for (uint256 i; i < 2; ++i) {
            vm.prank(SPENDER);
            require(launchToken.transferFrom(address(this), ALICE, 100 ether), "launch unlimited transfer failed");
            _eq(
                launchToken.allowance(address(this), SPENDER), type(uint256).max, "launch unlimited allowance decreased"
            );
        }
        _assertLaunchBalances(LAUNCH_SUPPLY - 200 ether, 200 ether, 0);
    }

    function testLaunchInsufficientBalancesRejectDirectSelfAndDelegatedTransfers() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        launchToken.transfer(BOB, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmLaunchToken.ERC20InsufficientBalance.selector, address(this), LAUNCH_SUPPLY, type(uint256).max
            )
        );
        launchToken.transfer(ALICE, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmLaunchToken.ERC20InsufficientBalance.selector, address(this), LAUNCH_SUPPLY, LAUNCH_SUPPLY + 1
            )
        );
        launchToken.transfer(address(this), LAUNCH_SUPPLY + 1);

        require(launchToken.approve(SPENDER, LAUNCH_SUPPLY + 1), "launch excessive approval failed");
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmLaunchToken.ERC20InsufficientBalance.selector, address(this), LAUNCH_SUPPLY, LAUNCH_SUPPLY + 1
            )
        );
        vm.prank(SPENDER);
        launchToken.transferFrom(address(this), ALICE, LAUNCH_SUPPLY + 1);
        _eq(launchToken.allowance(address(this), SPENDER), LAUNCH_SUPPLY + 1, "launch balance failure spent allowance");
        _assertLaunchBalances(LAUNCH_SUPPLY, 0, 0);
    }

    function testLaunchInvalidAddressesRevertAndRestoreAllowance() public {
        require(launchToken.approve(SPENDER, 100 ether), "launch approval failed");
        uint256[2] memory amounts = [uint256(0), 100 ether];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidReceiver.selector, address(0)));
            launchToken.transfer(address(0), amounts[i]);
            vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(SPENDER);
            launchToken.transferFrom(address(this), address(0), amounts[i]);
            _eq(launchToken.allowance(address(this), SPENDER), 100 ether, "invalid launch receiver spent allowance");
            vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidSpender.selector, address(0)));
            launchToken.approve(address(0), amounts[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(SPENDER);
        launchToken.transferFrom(address(0), ALICE, 0);
        _eq(launchToken.allowance(address(this), address(0)), 0, "launch invalid spender gained allowance");
        _assertLaunchBalances(LAUNCH_SUPPLY, 0, 0);
    }

    function testLaunchAllowanceIsolationReplacementAndRevocation() public {
        require(launchToken.approve(SPENDER, 100 ether), "launch approval failed");
        require(launchToken.approve(SPENDER, 50 ether), "launch replacement failed");
        vm.expectRevert(
            abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 50 ether, 100 ether)
        );
        vm.prank(SPENDER);
        launchToken.transferFrom(address(this), ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        launchToken.transferFrom(address(this), ALICE, 1);
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        launchToken.transferFrom(ALICE, BOB, 1);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, address(this), 0, 1)
        );
        launchToken.transferFrom(address(this), ALICE, 1);
        _eq(launchToken.allowance(address(this), SPENDER), 50 ether, "failed launch calls changed allowance");
        require(launchToken.approve(SPENDER, 0), "launch revocation failed");
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        launchToken.transferFrom(address(this), ALICE, 1);
        _eq(launchToken.allowance(address(this), SPENDER), 0, "launch revocation undone");
        _assertLaunchBalances(LAUNCH_SUPPLY, 0, 0);
    }

    function testLaunchAdminCallsRejectDeployerAndStranger() public {
        bytes[10] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether),
            abi.encodeWithSignature("mint(uint256)", 1 ether),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("issue(uint256)", 1 ether),
            abi.encodeWithSignature("setOwner(address)", ALICE),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("upgradeTo(address)", ALICE),
            abi.encodeWithSignature("initialize(address)", ALICE),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("setMinter(address)", ALICE)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(launchToken).call(calls[i]);
            require(!deployerSucceeded, "launch deployer reached an admin entrypoint");
            vm.prank(ALICE);
            (bool strangerSucceeded,) = address(launchToken).call(calls[i]);
            require(!strangerSucceeded, "launch stranger reached an admin entrypoint");
            _assertLaunchBalances(LAUNCH_SUPPLY, 0, 0);
        }
    }

    function testFuzzLaunchTransfersConserveFixedSupply(uint256 directSeed, uint256 delegatedSeed, bool self) public {
        uint256 directAmount = directSeed % (LAUNCH_SUPPLY + 1);
        uint256 delegatedAmount = delegatedSeed % (directAmount + 1);
        require(launchToken.transfer(ALICE, directAmount), "fuzz launch transfer failed");
        _assertLaunchBalances(LAUNCH_SUPPLY - directAmount, directAmount, 0);
        vm.prank(ALICE);
        require(launchToken.approve(SPENDER, delegatedAmount), "fuzz launch approval failed");
        vm.prank(SPENDER);
        require(
            launchToken.transferFrom(ALICE, self ? ALICE : BOB, delegatedAmount),
            "fuzz launch delegated transfer failed"
        );
        _eq(launchToken.allowance(ALICE, SPENDER), 0, "fuzz launch allowance not consumed");
        _assertLaunchBalances(
            LAUNCH_SUPPLY - directAmount,
            self ? directAmount : directAmount - delegatedAmount,
            self ? 0 : delegatedAmount
        );
    }
}

/// @dev Exercises the real launch-token/converter/Swarm dependency graph.
contract SwarmConverterTest is SwarmTestBase {
    uint256 internal constant RATE = 1_000;
    uint256 internal constant LAUNCH_SUPPLY = 1_000_000_000 ether;
    SwarmLaunchToken internal launchToken;
    SwarmConverter internal converter;

    function setUp() public override {
        launchToken = new SwarmLaunchToken();
        converter = new SwarmConverter(address(launchToken));
        token = converter.swarm();
        tracker = converter.burnTracker();
    }

    function _convertForAlice(uint256 launchAmount) internal {
        require(launchToken.transfer(ALICE, launchAmount), "funding failed");
        vm.prank(ALICE);
        require(launchToken.approve(address(converter), launchAmount), "conversion approval failed");
        vm.prank(ALICE);
        _eq(converter.convert(launchAmount), launchAmount / RATE, "wrong gross conversion return");
    }

    function _assertConverterAccounting() internal view {
        uint256 reserve = token.balanceOf(address(converter));
        _eq(
            reserve + token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB)
                + token.balanceOf(SPENDER),
            token.totalSupply(),
            "converter SWORM balances do not sum to supply"
        );
        _eq(token.totalSupply() + tracker.totalBurned(), SUPPLY, "converter burns do not match supply loss");
        _eq(launchToken.totalSupply(), LAUNCH_SUPPLY, "conversion changed launch supply");
        uint256 locked = launchToken.balanceOf(address(converter));
        _eq(
            locked + launchToken.balanceOf(address(this)) + launchToken.balanceOf(ALICE) + launchToken.balanceOf(BOB)
                + launchToken.balanceOf(SPENDER),
            LAUNCH_SUPPLY,
            "converter launch balances do not sum to supply"
        );
        require(locked >= RATE * (SUPPLY - reserve), "converter backing is insufficient");
        _eq(token.balanceOf(address(0)), 0, "burn credited zero address");
    }

    function _state() internal view returns (bytes32 result) {
        result = keccak256(abi.encode(token.totalSupply(), launchToken.totalSupply(), tracker.totalBurned()));
        address[5] memory accounts = [address(this), ALICE, BOB, SPENDER, address(converter)];
        for (uint256 i; i < accounts.length; ++i) {
            result = keccak256(
                abi.encode(
                    result,
                    token.balanceOf(accounts[i]),
                    launchToken.balanceOf(accounts[i]),
                    token.allowance(accounts[i], address(converter)),
                    launchToken.allowance(accounts[i], address(converter))
                )
            );
        }
    }

    function _assertConversionEvent(SwarmVm.Log memory entry, string memory signature, uint256 first, uint256 second)
        internal
        view
    {
        require(entry.emitter == address(converter), "wrong converter event emitter");
        _eq(entry.topics.length, 2, "wrong converter event topic count");
        require(entry.topics[0] == keccak256(bytes(signature)), "wrong converter event signature");
        require(entry.topics[1] == bytes32(uint256(uint160(ALICE))), "wrong converter event account");
        (uint256 actualFirst, uint256 actualSecond) = abi.decode(entry.data, (uint256, uint256));
        _eq(actualFirst, first, "wrong converter event first amount");
        _eq(actualSecond, second, "wrong converter event second amount");
    }

    function testConverterRejectsInvalidLaunchDependencies() public {
        address[3] memory invalid = [address(0), ALICE, address(token)];
        bytes32 beforeState = _state();
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(SwarmConverter.InvalidLaunchToken.selector, invalid[i]));
            new SwarmConverter(invalid[i]);
        }
        vm.expectRevert();
        new SwarmConverter(address(tracker)); // Code exists, but no totalSupply interface.
        require(_state() == beforeState, "failed constructor changed existing deployment");
        _assertConverterAccounting();
    }

    function testConvertLocksGrossLaunchAmountAndEmitsBurnAndConversion() public {
        require(launchToken.transfer(ALICE, 100_000 ether), "funding failed");
        vm.prank(ALICE);
        require(launchToken.approve(address(converter), 100_000 ether), "approval failed");
        vm.recordLogs();
        vm.prank(ALICE);
        _eq(converter.convert(100_000 ether), 100 ether, "wrong gross conversion return");
        _eq(launchToken.balanceOf(ALICE), 0, "conversion did not lock all input");
        _eq(launchToken.balanceOf(address(converter)), 100_000 ether, "wrong launch collateral");
        _eq(launchToken.allowance(ALICE, address(converter)), 0, "conversion allowance not spent");
        _eq(token.balanceOf(ALICE), 99 ether, "conversion did not deliver net SWORM");
        _eq(token.balanceOf(address(converter)), SUPPLY - 100 ether, "wrong reserve debit");
        _eq(tracker.totalBurned(), 1 ether, "conversion burn missing");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 4, "wrong conversion event count");
        _assertTransferLog(entries[0], address(launchToken), ALICE, address(converter), 100_000 ether);
        _assertTransferLog(entries[1], address(token), address(converter), ALICE, 99 ether);
        _assertTransferLog(entries[2], address(token), address(converter), address(0), 1 ether);
        _assertConversionEvent(entries[3], "Converted(address,uint256,uint256)", 100_000 ether, 100 ether);
        _assertConverterAccounting();
    }

    function testRedeemPaysForNetSwarmAndEmitsRedemption() public {
        _convertForAlice(100_000 ether);
        vm.prank(ALICE);
        require(token.approve(address(converter), 99 ether), "redemption approval failed");
        vm.recordLogs();
        vm.prank(ALICE);
        _eq(converter.redeem(99 ether), 98_010 ether, "redemption must price net incoming SWORM");
        _eq(token.balanceOf(ALICE), 0, "redemption did not debit gross SWORM");
        _eq(token.allowance(ALICE, address(converter)), 0, "redemption allowance not spent");
        _eq(token.balanceOf(address(converter)), SUPPLY - 1.99 ether, "wrong reserve after redemption");
        _eq(launchToken.balanceOf(ALICE), 98_010 ether, "wrong redemption payment");
        _eq(launchToken.balanceOf(address(converter)), 1_990 ether, "wrong remaining collateral");
        _eq(tracker.totalBurned(), 1.99 ether, "both burn legs must be counted");
        SwarmVm.Log[] memory entries = vm.getRecordedLogs();
        _eq(entries.length, 4, "wrong redemption event count");
        _assertTransferLog(entries[0], address(token), ALICE, address(converter), 98.01 ether);
        _assertTransferLog(entries[1], address(token), ALICE, address(0), 0.99 ether);
        _assertTransferLog(entries[2], address(launchToken), address(converter), ALICE, 98_010 ether);
        _assertConversionEvent(entries[3], "Redeemed(address,uint256,uint256)", 98.01 ether, 98_010 ether);
        _assertConverterAccounting();
    }

    function testConverterRoundsEachBurnAtMinorUnitBoundaries() public {
        uint256[6] memory gross = [uint256(1), 99, 100, 101, 199, 200];
        uint256[6] memory outboundBurn = [uint256(0), 0, 1, 1, 1, 2];
        uint256[6] memory inboundBurn = [uint256(0), 0, 0, 1, 1, 1];
        uint256 burned;
        for (uint256 i; i < gross.length; ++i) {
            _convertForAlice(gross[i] * RATE);
            uint256 received = gross[i] - outboundBurn[i];
            _eq(token.balanceOf(ALICE), received, "wrong rounded conversion receipt");
            vm.prank(ALICE);
            require(token.approve(address(converter), received), "rounding approval failed");
            uint256 previousLaunch = launchToken.balanceOf(ALICE);
            vm.prank(ALICE);
            _eq(converter.redeem(received), (received - inboundBurn[i]) * RATE, "wrong rounded redemption");
            _eq(
                launchToken.balanceOf(ALICE) - previousLaunch,
                (received - inboundBurn[i]) * RATE,
                "wrong rounded payout"
            );
            burned += outboundBurn[i] + inboundBurn[i];
            _eq(tracker.totalBurned(), burned, "wrong rounded cumulative burns");
            _eq(launchToken.balanceOf(address(converter)), burned * RATE, "wrong round-trip collateral remainder");
            _assertConverterAccounting();
        }
    }

    function testConverterInvalidAmountsPreserveBalancesAllowancesAndBurns() public {
        _convertForAlice(100_000 ether);
        vm.prank(ALICE);
        require(launchToken.approve(address(converter), type(uint256).max), "launch approval failed");
        vm.prank(ALICE);
        require(token.approve(address(converter), type(uint256).max), "Swarm approval failed");
        bytes32 beforeState = _state();
        uint256[5] memory invalid = [uint256(0), 1, RATE - 1, RATE + 1, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(SwarmConverter.InvalidAmount.selector, invalid[i]));
            vm.prank(ALICE);
            converter.convert(invalid[i]);
            require(_state() == beforeState, "invalid conversion changed state");
        }
        vm.expectRevert(abi.encodeWithSelector(SwarmConverter.InvalidAmount.selector, 0));
        vm.prank(ALICE);
        converter.redeem(0);
        require(_state() == beforeState, "zero redemption changed state");
    }

    function testConvertRequiresCallersFullAllowanceAndRejectsReuse() public {
        uint256 amount = 100_000 ether;
        require(launchToken.transfer(ALICE, amount), "funding failed");
        uint256[2] memory insufficient = [uint256(0), amount - 1];
        for (uint256 i; i < insufficient.length; ++i) {
            vm.prank(ALICE);
            require(launchToken.approve(address(converter), insufficient[i]), "approval failed");
            bytes32 beforeState = _state();
            vm.expectRevert(
                abi.encodeWithSelector(
                    SwarmLaunchToken.ERC20InsufficientAllowance.selector, address(converter), insufficient[i], amount
                )
            );
            vm.prank(ALICE);
            converter.convert(amount);
            require(_state() == beforeState, "insufficient allowance changed conversion state");
        }
        vm.prank(ALICE);
        require(launchToken.approve(address(converter), amount), "approval failed");
        bytes32 approvedState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, address(converter), 0, amount)
        );
        vm.prank(BOB);
        converter.convert(amount);
        require(_state() == approvedState, "another caller spent Alice's conversion allowance");
        vm.prank(ALICE);
        _eq(converter.convert(amount), 100 ether, "conversion failed");
        bytes32 convertedState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, address(converter), 0, amount)
        );
        vm.prank(ALICE);
        converter.convert(amount);
        require(_state() == convertedState, "conversion allowance reused");
        _assertConverterAccounting();
    }

    function testConvertInsufficientBalanceRestoresSpentAllowance() public {
        require(launchToken.transfer(ALICE, RATE - 1), "funding failed");
        vm.prank(ALICE);
        require(launchToken.approve(address(converter), RATE), "approval failed");
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientBalance.selector, ALICE, RATE - 1, RATE)
        );
        vm.prank(ALICE);
        converter.convert(RATE);
        require(_state() == beforeState, "failed launch pull changed state");
        _assertConverterAccounting();
    }

    function testRedeemRequiresGrossAllowanceAndRejectsReuse() public {
        _convertForAlice(100_000 ether);
        uint256[2] memory insufficient = [uint256(0), 98.01 ether];
        for (uint256 i; i < insufficient.length; ++i) {
            vm.prank(ALICE);
            require(token.approve(address(converter), insufficient[i]), "approval failed");
            bytes32 beforeState = _state();
            vm.expectRevert(
                abi.encodeWithSelector(
                    Swarm.ERC20InsufficientAllowance.selector, address(converter), insufficient[i], 99 ether
                )
            );
            vm.prank(ALICE);
            converter.redeem(99 ether);
            require(_state() == beforeState, "insufficient redemption allowance changed state");
        }
        vm.prank(ALICE);
        require(token.approve(address(converter), 99 ether), "approval failed");
        vm.prank(ALICE);
        _eq(converter.redeem(99 ether), 98_010 ether, "redemption failed");
        bytes32 redeemedState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, address(converter), 0, 99 ether)
        );
        vm.prank(ALICE);
        converter.redeem(99 ether);
        require(_state() == redeemedState, "redemption allowance reused");
        _assertConverterAccounting();
    }

    function testRedeemInsufficientBalanceRestoresAllowanceAndPreservesBurns() public {
        _convertForAlice(100_000 ether);
        uint256[2] memory excessive = [uint256(100 ether), type(uint256).max];
        for (uint256 i; i < excessive.length; ++i) {
            vm.prank(ALICE);
            require(token.approve(address(converter), excessive[i]), "approval failed");
            bytes32 beforeState = _state();
            vm.expectRevert(
                abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, ALICE, 99 ether, excessive[i])
            );
            vm.prank(ALICE);
            converter.redeem(excessive[i]);
            require(_state() == beforeState, "failed Swarm pull changed state");
        }
        _assertConverterAccounting();
    }

    function testTransferredSwarmCanBeRedeemedByAnotherHolder() public {
        _convertForAlice(100_000 ether);
        vm.prank(ALICE);
        require(token.transfer(BOB, 40 ether), "holder transfer failed");
        vm.prank(BOB);
        require(token.approve(address(converter), 39.6 ether), "holder approval failed");
        vm.prank(BOB);
        _eq(converter.redeem(39.6 ether), 39_204 ether, "wrong new-holder payout");
        _eq(launchToken.balanceOf(BOB), 39_204 ether, "redemption did not pay caller");
        _eq(launchToken.balanceOf(ALICE), 0, "redemption paid original converter user");
        _eq(token.balanceOf(ALICE), 59 ether, "redemption debited original holder");
        _eq(token.balanceOf(BOB), 0, "new holder did not spend gross SWORM");
        _eq(tracker.totalBurned(), 1.796 ether, "inter-holder and redemption burns missing");
        _assertConverterAccounting();
    }

    function testDonationsCannotInflateRedemptionPayment() public {
        _convertForAlice(100_000 ether);
        require(launchToken.transfer(address(converter), 777), "launch donation failed");
        vm.prank(ALICE);
        require(token.transfer(address(converter), 10 ether), "Swarm donation failed");
        vm.prank(ALICE);
        require(token.approve(address(converter), 89 ether), "approval failed");
        vm.prank(ALICE);
        _eq(converter.redeem(89 ether), 88_110 ether, "donation inflated redemption return");
        _eq(launchToken.balanceOf(ALICE), 88_110 ether, "donation inflated payout");
        _eq(launchToken.balanceOf(address(converter)), 11_890 ether + 777, "donated collateral was spent");
        _eq(token.balanceOf(address(converter)), SUPPLY - 1.99 ether, "wrong donated reserve");
        _eq(tracker.totalBurned(), 1.99 ether, "donation burn missing");
        _assertConverterAccounting();
    }

    function testEntireSupplyCanConvertRedeemAndConvertAgain() public {
        _convertForAlice(LAUNCH_SUPPLY);
        _eq(token.balanceOf(address(converter)), 0, "full conversion did not exhaust reserve");
        _eq(token.balanceOf(ALICE), 990_000 ether, "wrong full conversion receipt");
        vm.prank(ALICE);
        require(token.approve(address(converter), 990_000 ether), "approval failed");
        vm.prank(ALICE);
        _eq(converter.redeem(990_000 ether), 980_100_000 ether, "wrong full redemption");
        _eq(token.balanceOf(address(converter)), 980_100 ether, "redemption did not replenish reserve");
        _eq(tracker.totalBurned(), 19_900 ether, "wrong full round-trip burns");
        vm.prank(ALICE);
        require(launchToken.approve(address(converter), 980_100_000 ether), "reconversion approval failed");
        vm.prank(ALICE);
        _eq(converter.convert(980_100_000 ether), 980_100 ether, "returned launch tokens cannot reconvert");
        _eq(token.balanceOf(address(converter)), 0, "second full conversion did not exhaust reserve");
        _eq(token.balanceOf(ALICE), 970_299 ether, "wrong reconversion receipt");
        _eq(tracker.totalBurned(), 29_701 ether, "wrong reconversion burn");
        _eq(launchToken.balanceOf(address(converter)), LAUNCH_SUPPLY, "wrong final collateral");
        _assertConverterAccounting();
    }

    function testConverterHasNoAdminOrWithdrawalPrivileges() public {
        _convertForAlice(100_000 ether);
        bytes[6] memory calls = [
            abi.encodeWithSignature("withdraw(address,uint256)", ALICE, 1 ether),
            abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(launchToken), ALICE, 1 ether),
            abi.encodeWithSignature("setRate(uint256)", 1),
            abi.encodeWithSignature("setLaunchToken(address)", ALICE),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("initialize(address)", ALICE)
        ];
        bytes32 beforeState = _state();
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSucceeded,) = address(converter).call(calls[i]);
            require(!deployerSucceeded, "converter deployer reached admin entrypoint");
            vm.prank(ALICE);
            (bool holderSucceeded,) = address(converter).call(calls[i]);
            require(!holderSucceeded, "converter holder reached admin entrypoint");
            require(_state() == beforeState, "admin call changed accounting");
        }
        require(address(converter.launchToken()) == address(launchToken), "launch binding changed");
        require(address(converter.swarm()) == address(token), "Swarm binding changed");
        require(address(converter.burnTracker()) == address(tracker), "tracker binding changed");
        _eq(converter.RATE(), RATE, "conversion rate changed");
        _assertConverterAccounting();
    }

    function testFuzzConverterRoundTripConservesCollateral(uint256 grossSeed, uint256 redeemSeed) public {
        uint256 gross = 1 + grossSeed % SUPPLY;
        uint256 outboundBurn = gross / 100;
        uint256 received = gross - outboundBurn;
        uint256 redeemed = 1 + redeemSeed % received;
        uint256 inboundBurn = redeemed / 100;
        uint256 payout = (redeemed - inboundBurn) * RATE;
        _convertForAlice(gross * RATE);
        _eq(token.balanceOf(ALICE), received, "fuzz conversion receipt wrong");
        _eq(launchToken.allowance(ALICE, address(converter)), 0, "fuzz conversion allowance not spent");
        vm.prank(ALICE);
        require(token.approve(address(converter), redeemed), "fuzz redemption approval failed");
        vm.prank(ALICE);
        _eq(converter.redeem(redeemed), payout, "fuzz redemption return wrong");
        _eq(token.balanceOf(ALICE), received - redeemed, "fuzz holder balance wrong");
        _eq(token.balanceOf(address(converter)), SUPPLY - gross + redeemed - inboundBurn, "fuzz reserve wrong");
        _eq(token.allowance(ALICE, address(converter)), 0, "fuzz redemption allowance not spent");
        _eq(tracker.totalBurned(), outboundBurn + inboundBurn, "fuzz round-trip burns wrong");
        _eq(launchToken.balanceOf(ALICE), payout, "fuzz redemption payment wrong");
        _eq(launchToken.balanceOf(address(converter)), gross * RATE - payout, "fuzz locked collateral wrong");
        _eq(launchToken.balanceOf(address(this)), LAUNCH_SUPPLY - gross * RATE, "fuzz launch funding debit wrong");
        _assertConverterAccounting();
    }
}
