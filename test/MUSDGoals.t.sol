// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MUSDGoals} from "../contracts/MUSDGoals.sol";
import {DemoMUSD} from "../contracts/DemoMUSD.sol";

/// @dev Minimal cheatcode interface — keeps the test suite dependency-free
///      (no forge-std download needed, builds fully offline).
interface Vm {
    function prank(address msgSender) external;
    function expectRevert() external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter)
        external;
}

/// @dev Minimal assertion helpers in place of forge-std's Test.
abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function fail(string memory why) internal pure {
        revert(string(abi.encodePacked("ASSERT FAIL: ", why)));
    }

    function assertTrue(bool cond, string memory why) internal pure {
        if (!cond) fail(why);
    }

    function assertEq(uint256 a, uint256 b, string memory why) internal pure {
        if (a != b) fail(why);
    }

    function assertEq(address a, address b, string memory why) internal pure {
        if (a != b) fail(why);
    }
}

contract MUSDGoalsTest is TestBase {
    // Mirror of MUSDGoals events for expectEmit checks.
    event GoalAchieved(address indexed user, uint256 indexed goalId);
    event GoalCreated(address indexed user, uint256 indexed goalId, string name, uint256 target, uint256 deadline);

    DemoMUSD internal musd;
    MUSDGoals internal goals;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        musd = new DemoMUSD();
        goals = new MUSDGoals(address(musd));
    }

    // --------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------

    function _fund(address user, uint256 faucetCalls) internal {
        for (uint256 i = 0; i < faucetCalls; i++) {
            vm.prank(user);
            musd.faucet();
        }
    }

    function _createAndApprove(address user) internal returns (uint256 goalId) {
        _fund(user, 1); // 1,000 dMUSD
        vm.prank(user);
        goalId = goals.createGoal("Emergency fund", 1000e18, 0);
        vm.prank(user);
        musd.approve(address(goals), type(uint256).max);
    }

    // --------------------------------------------------------------
    // DemoMUSD / faucet
    // --------------------------------------------------------------

    function testFaucetMintWorks() public {
        assertEq(musd.balanceOf(alice), 0, "alice starts at 0");
        vm.prank(alice);
        musd.faucet();
        assertEq(musd.balanceOf(alice), 1000e18, "faucet mints 1000 dMUSD");
        assertEq(musd.totalSupply(), 1000e18, "totalSupply tracks faucet");

        // No cooldown: a second call mints again.
        vm.prank(alice);
        musd.faucet();
        assertEq(musd.balanceOf(alice), 2000e18, "second faucet call mints again");
    }

    function testDemoTokenMetadata() public view {
        assertEq(address(goals.token()), address(musd), "goals wired to demo token");
        assertTrue(musd.decimals() == 18, "decimals 18");
    }

    function testDemoTransferAndAllowanceReverts() public {
        _fund(alice, 1);
        vm.prank(alice);
        musd.transfer(bob, 100e18);
        assertEq(musd.balanceOf(bob), 100e18, "transfer credits bob");

        vm.prank(alice);
        vm.expectRevert();
        musd.transfer(bob, 10_000e18); // more than balance

        vm.prank(bob);
        vm.expectRevert();
        musd.transferFrom(alice, bob, 1e18); // no allowance
    }

    // --------------------------------------------------------------
    // createGoal
    // --------------------------------------------------------------

    function testCreateGoalHappyPath() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(goals));
        emit GoalCreated(alice, 0, "Emergency fund", 500e18, 0);
        uint256 goalId = goals.createGoal("Emergency fund", 500e18, 0);

        assertEq(goalId, 0, "first goalId is 0");
        assertEq(goals.goalCount(alice), 1, "alice has 1 goal");

        MUSDGoals.Goal[] memory list = goals.getGoals(alice);
        assertEq(list.length, 1, "getGoals length 1");
        assertEq(list[0].target, 500e18, "target stored");
        assertEq(list[0].saved, 0, "saved starts 0");
        assertEq(uint256(list[0].deadline), 0, "deadline 0 = none");
        assertTrue(list[0].active, "goal active");
        assertTrue(keccak256(bytes(list[0].name)) == keccak256(bytes("Emergency fund")), "name stored");
    }

    function testCreateGoalWithDeadline() public {
        vm.prank(alice);
        uint256 goalId = goals.createGoal("Trip", 100e18, 1_900_000_000);
        MUSDGoals.Goal[] memory list = goals.getGoals(alice);
        assertEq(uint256(list[goalId].deadline), 1_900_000_000, "deadline stored as uint64");
    }

    function testCreateGoalTargetZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        goals.createGoal("Bad", 0, 0);
    }

    function testCreateGoalEmptyNameReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        goals.createGoal("", 100e18, 0);
    }

    // --------------------------------------------------------------
    // deposit
    // --------------------------------------------------------------

    function testCreateDepositHappyPathBalances() public {
        uint256 goalId = _createAndApprove(alice);

        uint256 aliceBefore = musd.balanceOf(alice);
        vm.prank(alice);
        goals.deposit(goalId, 250e18);

        assertEq(musd.balanceOf(alice), aliceBefore - 250e18, "alice debited 250");
        assertEq(musd.balanceOf(address(goals)), 250e18, "contract holds 250");

        MUSDGoals.Goal[] memory list = goals.getGoals(alice);
        assertEq(list[goalId].saved, 250e18, "saved = 250");
    }

    function testGoalAchievedEmittedWhenTargetReached() public {
        uint256 goalId = _createAndApprove(alice);

        // Partial deposit: no achievement yet (no emit expectation here;
        // the dedicated assertion is the crossing deposit below).
        vm.prank(alice);
        goals.deposit(goalId, 400e18);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(goals));
        emit GoalAchieved(alice, goalId);
        goals.deposit(goalId, 600e18); // pushes saved to exactly the 1000 target

        MUSDGoals.Goal[] memory list = goals.getGoals(alice);
        assertEq(list[goalId].saved, 1000e18, "saved reached target");
    }

    function testDepositZeroReverts() public {
        uint256 goalId = _createAndApprove(alice);
        vm.prank(alice);
        vm.expectRevert();
        goals.deposit(goalId, 0);
    }

    function testDepositNonexistentGoalReverts() public {
        _fund(alice, 1);
        vm.prank(alice);
        musd.approve(address(goals), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        goals.deposit(0, 1e18);
    }

    function testDepositWithoutAllowanceReverts() public {
        _fund(alice, 1);
        vm.prank(alice);
        uint256 goalId = goals.createGoal("No allowance", 100e18, 0);
        // Deliberately no approve().
        vm.prank(alice);
        vm.expectRevert();
        goals.deposit(goalId, 1e18);
    }

    // --------------------------------------------------------------
    // withdraw
    // --------------------------------------------------------------

    function testWithdrawPartialAndFull() public {
        uint256 goalId = _createAndApprove(alice);
        vm.prank(alice);
        goals.deposit(goalId, 250e18);

        // Partial withdraw.
        uint256 aliceBefore = musd.balanceOf(alice);
        vm.prank(alice);
        goals.withdraw(goalId, 100e18);
        assertEq(musd.balanceOf(alice), aliceBefore + 100e18, "partial withdraw credits alice");
        MUSDGoals.Goal[] memory list = goals.getGoals(alice);
        assertEq(list[0].saved, 150e18, "saved reduced to 150");

        // Full withdraw of the remainder — allowed even after saving.
        vm.prank(alice);
        goals.withdraw(goalId, 150e18);
        list = goals.getGoals(alice);
        assertEq(list[0].saved, 0, "saved emptied");
        assertEq(musd.balanceOf(address(goals)), 0, "contract emptied");
        assertEq(musd.balanceOf(alice), 1000e18, "alice whole again");
    }

    function testWithdrawAfterTargetReachedAllowed() public {
        uint256 goalId = _createAndApprove(alice);
        vm.prank(alice);
        goals.deposit(goalId, 1000e18); // hits target exactly
        vm.prank(alice);
        goals.withdraw(goalId, 1000e18); // funds stay the user's
        assertEq(musd.balanceOf(alice), 1000e18, "full withdraw after achievement works");
    }

    function testWithdrawMoreThanSavedReverts() public {
        uint256 goalId = _createAndApprove(alice);
        vm.prank(alice);
        goals.deposit(goalId, 10e18);
        vm.prank(alice);
        vm.expectRevert();
        goals.withdraw(goalId, 11e18);
    }

    function testWithdrawZeroReverts() public {
        uint256 goalId = _createAndApprove(alice);
        vm.prank(alice);
        goals.deposit(goalId, 10e18);
        vm.prank(alice);
        vm.expectRevert();
        goals.withdraw(goalId, 0);
    }

    // --------------------------------------------------------------
    // Per-user isolation
    // --------------------------------------------------------------

    /// Goals live in a per-user array, so Bob literally has no handle on
    /// Alice's goalId 0: for Bob, goalId 0 is *his own* (nonexistent) goal.
    function testUserIsolation() public {
        uint256 aliceGoal = _createAndApprove(alice);
        vm.prank(alice);
        goals.deposit(aliceGoal, 250e18);

        // Bob sees no goals at all.
        assertEq(goals.goalCount(bob), 0, "bob has no goals");
        MUSDGoals.Goal[] memory bobGoals = goals.getGoals(bob);
        assertEq(bobGoals.length, 0, "bob getGoals empty");

        // Bob depositing into "goal 0" targets his own list -> reverts.
        _fund(bob, 1);
        vm.prank(bob);
        musd.approve(address(goals), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert();
        goals.deposit(0, 1e18);

        // Bob withdrawing "goal 0" likewise reverts.
        vm.prank(bob);
        vm.expectRevert();
        goals.withdraw(0, 1e18);

        // Alice's goal and funds are untouched by all of the above.
        MUSDGoals.Goal[] memory list = goals.getGoals(alice);
        assertEq(list[0].saved, 250e18, "alice saved untouched");
        assertEq(musd.balanceOf(address(goals)), 250e18, "contract balance untouched");

        // And when Bob creates his own goal 0, it is fully independent.
        vm.prank(bob);
        uint256 bobGoal = goals.createGoal("Bob's jar", 50e18, 0);
        assertEq(bobGoal, 0, "bob's own first goal is also index 0");
        vm.prank(bob);
        goals.deposit(bobGoal, 50e18);
        assertEq(goals.getGoals(bob)[0].saved, 50e18, "bob saved his own 50");
        assertEq(goals.getGoals(alice)[0].saved, 250e18, "alice still at 250");
    }

    function testMultipleGoalsIndependent() public {
        _fund(alice, 1);
        vm.prank(alice);
        uint256 g0 = goals.createGoal("Emergency fund", 1000e18, 0);
        vm.prank(alice);
        uint256 g1 = goals.createGoal("New laptop", 500e18, 0);
        assertEq(g0, 0, "g0 index");
        assertEq(g1, 1, "g1 index");

        vm.prank(alice);
        musd.approve(address(goals), type(uint256).max);
        vm.prank(alice);
        goals.deposit(g1, 125e18);

        MUSDGoals.Goal[] memory list = goals.getGoals(alice);
        assertEq(list[g0].saved, 0, "g0 untouched");
        assertEq(list[g1].saved, 125e18, "g1 funded");
    }
}
