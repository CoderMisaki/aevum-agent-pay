// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentPay} from "../src/AgentPay.sol";
import {MockUSD8} from "./MockUSD8.sol";

contract AgentPayTest is Test {
    AgentPay public pay;
    MockUSD8 public usd;

    address public payer = address(0x1001);
    address public agent = address(0x2002);
    address public payeeA = address(0x3003);
    address public payeeB = address(0x4004);
    address public stranger = address(0x5005);

    uint256 constant ONE = 1_000_000; // 1 tUSD8 = 1e6 units (6 decimals)

    event PaymentExecuted(
        uint256 indexed receiptId,
        uint256 indexed allowanceId,
        address indexed payer,
        address agent,
        address payee,
        uint256 amount,
        uint256 timestamp
    );

    function setUp() public {
        usd = new MockUSD8();
        pay = new AgentPay(address(usd));
        usd.mint(payer, 10_000 * ONE);
        vm.prank(payer);
        usd.approve(address(pay), type(uint256).max);
    }

    function _createAllowance() internal returns (uint256 id) {
        address[] memory payees = new address[](2);
        payees[0] = payeeA;
        payees[1] = payeeB;
        vm.prank(payer);
        id = pay.createAllowance(agent, payees, 100 * ONE, 500 * ONE, block.timestamp + 7 days, 500 * ONE);
    }

    function testCreateAllowance() public {
        uint256 id = _createAllowance();
        AgentPay.Allowance memory a = pay.getAllowance(id);
        assertEq(a.payer, payer);
        assertEq(a.agent, agent);
        assertEq(a.perPaymentCap, 100 * ONE);
        assertEq(a.totalBudget, 500 * ONE);
        assertEq(a.spent, 0);
        assertEq(a.escrowed, 500 * ONE);
        assertFalse(a.revoked);
        assertTrue(pay.isPayee(id, payeeA));
        assertTrue(pay.isPayee(id, payeeB));
        assertEq(usd.balanceOf(address(pay)), 500 * ONE);
        assertEq(usd.balanceOf(payer), 10_000 * ONE - 500 * ONE);
    }

    function testCreateAllowanceRejectsBadParams() public {
        address[] memory empty = new address[](0);
        vm.prank(payer);
        vm.expectRevert(AgentPay.EmptyPayees.selector);
        pay.createAllowance(agent, empty, 100 * ONE, 500 * ONE, block.timestamp + 1 days, 500 * ONE);

        address[] memory payees = new address[](1);
        payees[0] = payeeA;
        vm.prank(payer);
        vm.expectRevert(AgentPay.InvalidBudget.selector);
        pay.createAllowance(agent, payees, 100 * ONE, 50 * ONE, block.timestamp + 1 days, 50 * ONE);

        vm.prank(payer);
        vm.expectRevert(AgentPay.InvalidExpiry.selector);
        pay.createAllowance(agent, payees, 100 * ONE, 500 * ONE, block.timestamp, 500 * ONE);

        vm.prank(payer);
        vm.expectRevert(AgentPay.InsufficientFunding.selector);
        pay.createAllowance(agent, payees, 100 * ONE, 500 * ONE, block.timestamp + 1 days, 100 * ONE);
    }

    function testAgentPaymentHappyPath() public {
        uint256 id = _createAllowance();
        vm.expectEmit(true, true, true, true, address(pay));
        emit PaymentExecuted(0, id, payer, agent, payeeA, 40 * ONE, block.timestamp);
        vm.prank(agent);
        uint256 receipt = pay.executePayment(id, payeeA, 40 * ONE);
        assertEq(receipt, 0);
        assertEq(usd.balanceOf(payeeA), 40 * ONE);
        AgentPay.Allowance memory a = pay.getAllowance(id);
        assertEq(a.spent, 40 * ONE);
        assertEq(a.escrowed, 460 * ONE);
        assertEq(pay.remainingBudget(id), 460 * ONE);
    }

    function testPaymentToNonWhitelistedPayeeReverts() public {
        uint256 id = _createAllowance();
        vm.prank(agent);
        vm.expectRevert(AgentPay.PayeeNotWhitelisted.selector);
        pay.executePayment(id, stranger, 10 * ONE);
    }

    function testPaymentAbovePerPaymentCapReverts() public {
        uint256 id = _createAllowance();
        vm.prank(agent);
        vm.expectRevert(AgentPay.AmountExceedsCap.selector);
        pay.executePayment(id, payeeA, 101 * ONE);
    }

    function testPaymentAboveTotalBudgetReverts() public {
        uint256 id = _createAllowance();
        // 5 payments of the 100 tUSD8 cap exactly exhaust the 500 budget.
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(agent);
            pay.executePayment(id, payeeA, 100 * ONE);
        }
        vm.prank(agent);
        vm.expectRevert(AgentPay.BudgetExceeded.selector);
        pay.executePayment(id, payeeA, 1 * ONE);
    }

    function testOnlyAgentCanPay() public {
        uint256 id = _createAllowance();
        vm.prank(stranger);
        vm.expectRevert(AgentPay.NotAgent.selector);
        pay.executePayment(id, payeeA, 10 * ONE);
        vm.prank(payer);
        vm.expectRevert(AgentPay.NotAgent.selector);
        pay.executePayment(id, payeeA, 10 * ONE);
    }

    function testPaymentAfterExpiryReverts() public {
        uint256 id = _createAllowance();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(agent);
        vm.expectRevert(AgentPay.AllowanceExpired.selector);
        pay.executePayment(id, payeeA, 10 * ONE);
    }

    function testRevokeRefundsAndBlocksPayments() public {
        uint256 id = _createAllowance();
        vm.prank(agent);
        pay.executePayment(id, payeeA, 40 * ONE);

        vm.prank(payer);
        uint256 refunded = pay.revokeAllowance(id);
        assertEq(refunded, 460 * ONE);
        assertEq(usd.balanceOf(payer), 10_000 * ONE - 40 * ONE);
        assertTrue(pay.getAllowance(id).revoked);

        vm.prank(agent);
        vm.expectRevert(AgentPay.AlreadyRevoked.selector);
        pay.executePayment(id, payeeA, 10 * ONE);
    }

    function testOnlyPayerCanRevoke() public {
        uint256 id = _createAllowance();
        vm.prank(stranger);
        vm.expectRevert(AgentPay.NotPayer.selector);
        pay.revokeAllowance(id);
    }

    function testTopUpAndPayeeManagement() public {
        uint256 id = _createAllowance();
        // Remove payeeB, then it can no longer be paid.
        vm.prank(payer);
        pay.removePayee(id, payeeB);
        assertFalse(pay.isPayee(id, payeeB));
        vm.prank(agent);
        vm.expectRevert(AgentPay.PayeeNotWhitelisted.selector);
        pay.executePayment(id, payeeB, 10 * ONE);

        // Add a new payee and pay it.
        vm.prank(payer);
        pay.addPayee(id, stranger);
        vm.prank(agent);
        pay.executePayment(id, stranger, 10 * ONE);
        assertEq(usd.balanceOf(stranger), 10 * ONE);

        // Top up escrow.
        vm.prank(payer);
        pay.topUp(id, 100 * ONE);
        assertEq(pay.getAllowance(id).escrowed, 500 * ONE - 10 * ONE + 100 * ONE);
    }

    function testFuzzPayments(uint256 amount) public {
        amount = bound(amount, 1, 100 * ONE);
        uint256 id = _createAllowance();
        vm.prank(agent);
        pay.executePayment(id, payeeA, amount);
        assertEq(usd.balanceOf(payeeA), amount);
    }
}
