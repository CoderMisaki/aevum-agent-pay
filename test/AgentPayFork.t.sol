// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentPay} from "../src/AgentPay.sol";

/// @notice Live-fork test against the REAL tUSD8 on QDay Aevum Testnet.
/// @dev Runs with: forge test --match-contract AgentPayForkTest
///      No gas is spent; the top tUSD8 holder is impersonated (vm.prank)
///      to fund the payer, exactly as the faucet would.
contract AgentPayForkTest is Test {
    // Real tUSD8 on Aevum Testnet (chain 44005), verified on-chain.
    address constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    // Top holder at time of writing (Blockscout holders API), ~1.09M tUSD8.
    address constant HOLDER = 0x94ef5dB164e7BBf4149e298c5588C035Ea8E9C05;

    AgentPay public pay;
    IERC20 public usd;

    address public payer = address(0x1001);
    address public agent = address(0x2002);
    address public payee = address(0x3003);

    uint256 constant ONE = 1_000_000; // 1 tUSD8, 6 decimals

    function setUp() public {
        vm.createSelectFork("https://rpc-test.qday.info");
        usd = IERC20(TUSD8);
        pay = new AgentPay(TUSD8);

        // Fund the payer with real tUSD8 from the top holder.
        vm.prank(HOLDER);
        usd.transfer(payer, 1_000 * ONE);
        assertEq(usd.balanceOf(payer), 1_000 * ONE);

        vm.prank(payer);
        usd.approve(address(pay), type(uint256).max);
    }

    function testForkEndToEndWithRealTUSD8() public {
        address[] memory payees = new address[](1);
        payees[0] = payee;

        vm.prank(payer);
        uint256 id = pay.createAllowance(
            agent, payees, 100 * ONE, 500 * ONE, block.timestamp + 7 days, 500 * ONE
        );

        vm.prank(agent);
        uint256 receipt = pay.executePayment(id, payee, 25 * ONE);
        assertEq(receipt, 0);
        assertEq(usd.balanceOf(payee), 25 * ONE);
        assertEq(pay.remainingBudget(id), 475 * ONE);

        // Payer revokes; unspent 475 tUSD8 returns.
        vm.prank(payer);
        uint256 refunded = pay.revokeAllowance(id);
        assertEq(refunded, 475 * ONE);
        assertEq(usd.balanceOf(payer), 1_000 * ONE - 25 * ONE);
    }
}
