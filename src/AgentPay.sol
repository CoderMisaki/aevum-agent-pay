// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AgentPay — scoped autonomous-agent payments in tUSD8
/// @notice A payer creates an on-chain allowance for an agent address:
///         whitelisted payee(s), a per-payment cap, a total budget and an
///         expiry timestamp. The agent can only pay whitelisted payees,
///         within the caps, before expiry. The payer funds the allowance
///         up-front (escrow held by this contract) and can revoke at any
///         time, reclaiming the unspent balance. Every payment emits a
///         receipt event, forming a complete on-chain audit trail.
/// @dev Built for the Aevum Builder Challenge #1 (QDay Aevum Testnet).
///      Token is the test stablecoin tUSD8 (6 decimals).
contract AgentPay is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The stablecoin used for all payments (tUSD8 on Aevum Testnet).
    IERC20 public immutable token;

    /// @notice Auto-incrementing allowance id.
    uint256 public nextAllowanceId;

    struct Allowance {
        address payer;
        address agent;
        address[] payees;
        uint256 perPaymentCap;
        uint256 totalBudget;
        uint256 spent;
        uint256 expiry;
        bool revoked;
        uint256 escrowed;
    }

    mapping(uint256 => Allowance) private _allowances;
    /// @notice allowanceId => payee => whitelisted
    mapping(uint256 => mapping(address => bool)) public isPayee;

    event AllowanceCreated(
        uint256 indexed allowanceId,
        address indexed payer,
        address indexed agent,
        uint256 perPaymentCap,
        uint256 totalBudget,
        uint256 expiry,
        uint256 funded
    );
    event PayeeAdded(uint256 indexed allowanceId, address indexed payee);
    event PayeeRemoved(uint256 indexed allowanceId, address indexed payee);
    event AllowanceToppedUp(uint256 indexed allowanceId, uint256 amount);
    /// @notice Receipt for every agent payment (audit trail).
    event PaymentExecuted(
        uint256 indexed receiptId,
        uint256 indexed allowanceId,
        address indexed payer,
        address agent,
        address payee,
        uint256 amount,
        uint256 timestamp
    );
    event AllowanceRevoked(uint256 indexed allowanceId, uint256 refunded);

    uint256 private _receiptCounter;

    error ZeroAddress();
    error EmptyPayees();
    error InvalidCap();
    error InvalidBudget();
    error InvalidExpiry();
    error InsufficientFunding();
    error NotPayer();
    error NotAgent();
    error AlreadyRevoked();
    error AllowanceExpired();
    error PayeeNotWhitelisted();
    error AmountExceedsCap();
    error BudgetExceeded();
    error InsufficientEscrow();
    error PayeeAlreadyListed();
    error PayeeNotListed();

    constructor(address token_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
    }

    /// @notice Create an allowance and fund it with `deposit` tUSD8.
    /// @dev Caller must have approved this contract to pull `deposit` tUSD8.
    ///      `deposit` must cover the whole `totalBudget` so the agent can
    ///      never promise more than the escrow holds.
    function createAllowance(
        address agent,
        address[] calldata payees,
        uint256 perPaymentCap,
        uint256 totalBudget,
        uint256 expiry,
        uint256 deposit
    ) external nonReentrant returns (uint256 allowanceId) {
        if (agent == address(0)) revert ZeroAddress();
        if (payees.length == 0) revert EmptyPayees();
        if (perPaymentCap == 0) revert InvalidCap();
        if (totalBudget == 0 || totalBudget < perPaymentCap) revert InvalidBudget();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (deposit < totalBudget) revert InsufficientFunding();

        allowanceId = nextAllowanceId++;

        Allowance storage a = _allowances[allowanceId];
        a.payer = msg.sender;
        a.agent = agent;
        a.perPaymentCap = perPaymentCap;
        a.totalBudget = totalBudget;
        a.expiry = expiry;

        for (uint256 i = 0; i < payees.length; i++) {
            if (payees[i] == address(0)) revert ZeroAddress();
            if (isPayee[allowanceId][payees[i]]) revert PayeeAlreadyListed();
            isPayee[allowanceId][payees[i]] = true;
            a.payees.push(payees[i]);
        }

        a.escrowed = deposit;
        token.safeTransferFrom(msg.sender, address(this), deposit);

        emit AllowanceCreated(
            allowanceId, msg.sender, agent, perPaymentCap, totalBudget, expiry, deposit
        );
    }

    /// @notice The designated agent pays a whitelisted payee from the escrow.
    function executePayment(
        uint256 allowanceId,
        address payee,
        uint256 amount
    ) external nonReentrant returns (uint256 receiptId) {
        Allowance storage a = _allowances[allowanceId];
        if (a.revoked) revert AlreadyRevoked();
        if (block.timestamp > a.expiry) revert AllowanceExpired();
        if (msg.sender != a.agent) revert NotAgent();
        if (!isPayee[allowanceId][payee]) revert PayeeNotWhitelisted();
        if (amount == 0 || amount > a.perPaymentCap) revert AmountExceedsCap();
        if (a.spent + amount > a.totalBudget) revert BudgetExceeded();
        if (a.escrowed < amount) revert InsufficientEscrow();

        a.spent += amount;
        a.escrowed -= amount;
        token.safeTransfer(payee, amount);

        receiptId = _receiptCounter++;
        emit PaymentExecuted(
            receiptId, allowanceId, a.payer, a.agent, payee, amount, block.timestamp
        );
    }

    /// @notice Payer revokes the allowance and reclaims unspent escrow.
    function revokeAllowance(uint256 allowanceId) external nonReentrant returns (uint256 refunded) {
        Allowance storage a = _allowances[allowanceId];
        if (msg.sender != a.payer) revert NotPayer();
        if (a.revoked) revert AlreadyRevoked();

        a.revoked = true;
        refunded = a.escrowed;
        a.escrowed = 0;
        if (refunded > 0) token.safeTransfer(a.payer, refunded);

        emit AllowanceRevoked(allowanceId, refunded);
    }

    /// @notice Payer adds more tUSD8 escrow to an active allowance.
    function topUp(uint256 allowanceId, uint256 amount) external nonReentrant {
        Allowance storage a = _allowances[allowanceId];
        if (msg.sender != a.payer) revert NotPayer();
        if (a.revoked) revert AlreadyRevoked();
        if (block.timestamp > a.expiry) revert AllowanceExpired();
        if (amount == 0) revert InvalidBudget();

        a.escrowed += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit AllowanceToppedUp(allowanceId, amount);
    }

    /// @notice Payer whitelists an additional payee on an active allowance.
    function addPayee(uint256 allowanceId, address payee) external {
        Allowance storage a = _allowances[allowanceId];
        if (msg.sender != a.payer) revert NotPayer();
        if (a.revoked) revert AlreadyRevoked();
        if (block.timestamp > a.expiry) revert AllowanceExpired();
        if (payee == address(0)) revert ZeroAddress();
        if (isPayee[allowanceId][payee]) revert PayeeAlreadyListed();

        isPayee[allowanceId][payee] = true;
        a.payees.push(payee);
        emit PayeeAdded(allowanceId, payee);
    }

    /// @notice Payer removes a payee from an active allowance.
    function removePayee(uint256 allowanceId, address payee) external {
        Allowance storage a = _allowances[allowanceId];
        if (msg.sender != a.payer) revert NotPayer();
        if (a.revoked) revert AlreadyRevoked();
        if (!isPayee[allowanceId][payee]) revert PayeeNotListed();

        isPayee[allowanceId][payee] = false;
        address[] storage list = a.payees;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == payee) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit PayeeRemoved(allowanceId, payee);
    }

    // ---- Views ----

    function getAllowance(uint256 allowanceId) external view returns (Allowance memory) {
        return _allowances[allowanceId];
    }

    function getPayees(uint256 allowanceId) external view returns (address[] memory) {
        return _allowances[allowanceId].payees;
    }

    function remainingBudget(uint256 allowanceId) external view returns (uint256) {
        return _allowances[allowanceId].totalBudget - _allowances[allowanceId].spent;
    }

    function isActive(uint256 allowanceId) external view returns (bool) {
        Allowance storage a = _allowances[allowanceId];
        return !a.revoked && block.timestamp <= a.expiry;
    }
}
