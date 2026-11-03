// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @notice Gasless token transfer. The sender signs "send `amount` to `recipient`, of which
/// `fee` covers gas and service"; a relayer submits and pays the transaction fee. In one
/// transaction the recipient gets amount - fee and the fee recipient gets fee. The contract
/// holds nothing between transactions and never sells or buys anything.
/// - EIP-3009 tokens (USDC): one signature. The authorization nonce is the transfer id, so the
///   token signature also fixes recipient, fee, deadline and salt.
/// - EIP-2612 tokens: a permit plus an EIP-712 signature of the transfer itself.
contract GasRelay is EIP712, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Transfer {
        address sender;
        address recipient;
        address token;
        uint256 amount;
        uint256 fee;
        uint256 deadline;
        bytes32 salt;
    }

    bytes32 public constant TRANSFER_TYPEHASH = keccak256(
        "Transfer(address sender,address recipient,address token,uint256 amount,uint256 fee,uint256 deadline,bytes32 salt)"
    );

    mapping(address => bool) public relayers;
    mapping(address => bool) public acceptedTokens;
    mapping(bytes32 => bool) public used;
    address public feeRecipient;

    event Relayed(bytes32 indexed id, address indexed sender, address indexed recipient, address token, uint256 amount, uint256 fee);
    event RelayerSet(address indexed relayer, bool allowed);
    event TokenSet(address indexed token, bool accepted);
    event FeeRecipientSet(address indexed feeRecipient);

    error NotRelayer();
    error TokenNotAccepted();
    error Expired();
    error BadRecipient();
    error FeeTooHigh();
    error AlreadyUsed();
    error BadTransferSignature();
    error PaymentMissing();

    modifier onlyRelayer() {
        if (!relayers[msg.sender]) revert NotRelayer();
        _;
    }

    constructor(address owner_, address relayer_, address feeRecipient_) EIP712("GasRelay", "1") Ownable(owner_) {
        relayers[relayer_] = true;
        feeRecipient = feeRecipient_;
        emit RelayerSet(relayer_, true);
        emit FeeRecipientSet(feeRecipient_);
    }

    function transferId(Transfer calldata t) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(TRANSFER_TYPEHASH, t.sender, t.recipient, t.token, t.amount, t.fee, t.deadline, t.salt))
        );
    }

    function relayWithAuthorization(Transfer calldata t, uint8 v, bytes32 r, bytes32 s)
        external
        onlyRelayer
        whenNotPaused
        nonReentrant
        returns (bytes32 id)
    {
        id = _open(t);
        uint256 before = IERC20(t.token).balanceOf(address(this));
        IERC3009(t.token).receiveWithAuthorization(t.sender, address(this), t.amount, 0, t.deadline, id, v, r, s);
        _payout(t, id, before);
    }

    function relayWithPermit(Transfer calldata t, uint8 v, bytes32 r, bytes32 s, bytes calldata transferSignature)
        external
        onlyRelayer
        whenNotPaused
        nonReentrant
        returns (bytes32 id)
    {
        id = _open(t);
        if (!SignatureChecker.isValidSignatureNow(t.sender, id, transferSignature)) revert BadTransferSignature();
        // A permit that was already used (front-run) is fine as long as the allowance exists.
        try IERC20Permit(t.token).permit(t.sender, address(this), t.amount, t.deadline, v, r, s) {} catch {}
        uint256 before = IERC20(t.token).balanceOf(address(this));
        IERC20(t.token).safeTransferFrom(t.sender, address(this), t.amount);
        _payout(t, id, before);
    }

    function _open(Transfer calldata t) private returns (bytes32 id) {
        if (!acceptedTokens[t.token]) revert TokenNotAccepted();
        if (block.timestamp > t.deadline) revert Expired();
        if (t.recipient == address(0) || t.recipient == address(this) || t.recipient == t.sender) revert BadRecipient();
        if (t.fee >= t.amount) revert FeeTooHigh();
        id = transferId(t);
        if (used[id]) revert AlreadyUsed();
        used[id] = true;
    }

    function _payout(Transfer calldata t, bytes32 id, uint256 balanceBefore) private {
        // Fee-on-transfer or no-op tokens must not be relayed for less than what was signed.
        if (IERC20(t.token).balanceOf(address(this)) - balanceBefore < t.amount) revert PaymentMissing();
        IERC20(t.token).safeTransfer(t.recipient, t.amount - t.fee);
        if (t.fee > 0) IERC20(t.token).safeTransfer(feeRecipient, t.fee);
        emit Relayed(id, t.sender, t.recipient, t.token, t.amount, t.fee);
    }

    function setRelayer(address relayer, bool allowed) external onlyOwner {
        relayers[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    function setToken(address token, bool accepted) external onlyOwner {
        acceptedTokens[token] = accepted;
        emit TokenSet(token, accepted);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Returns tokens someone sent to this contract by mistake.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
