// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC3009Receive {
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

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWrappedNative {
    function withdraw(uint256 amount) external;
}

/// @notice Gasless swap. The sender signs one EIP-3009 authorization whose nonce is the swap id, so
/// the signature fixes both tokens, pool, amount, fee, minimum output, deadline and salt. A relayer
/// submits and pays the transaction fee. In one transaction the fee recipient gets `fee`, the rest is
/// sold through the fixed router, and the output goes to the sender, never anywhere else. tokenOut
/// equal to the wrapped native token pays out the native coin. The contract holds nothing between
/// transactions, and the router cannot be changed.
contract SwapRelay is EIP712, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Swap {
        address sender;
        address tokenIn;
        address tokenOut;
        uint24 poolFee;
        uint256 amount;
        uint256 fee;
        uint256 minOut;
        uint256 deadline;
        bytes32 salt;
    }

    bytes32 public constant SWAP_TYPEHASH = keccak256(
        "Swap(address sender,address tokenIn,address tokenOut,uint24 poolFee,uint256 amount,uint256 fee,uint256 minOut,uint256 deadline,bytes32 salt)"
    );

    address public immutable router;
    address public immutable wrappedNative;

    mapping(address => bool) public relayers;
    mapping(address => bool) public acceptedTokens;
    mapping(bytes32 => bool) public used;
    address public feeRecipient;

    event Swapped(bytes32 indexed id, address indexed sender, address tokenIn, address tokenOut, uint256 amount, uint256 fee, uint256 amountOut);
    event RelayerSet(address indexed relayer, bool allowed);
    event TokenSet(address indexed token, bool accepted);
    event FeeRecipientSet(address indexed feeRecipient);

    error NotRelayer();
    error TokenNotAccepted();
    error Expired();
    error SameToken();
    error FeeTooHigh();
    error NoMinimum();
    error AlreadyUsed();
    error PaymentMissing();
    error OutputTooLow();
    error PayoutFailed();
    error NotWrappedNative();

    modifier onlyRelayer() {
        if (!relayers[msg.sender]) revert NotRelayer();
        _;
    }

    constructor(address owner_, address relayer_, address feeRecipient_, address router_, address wrappedNative_)
        EIP712("SwapRelay", "1")
        Ownable(owner_)
    {
        relayers[relayer_] = true;
        feeRecipient = feeRecipient_;
        router = router_;
        wrappedNative = wrappedNative_;
        emit RelayerSet(relayer_, true);
        emit FeeRecipientSet(feeRecipient_);
    }

    /// @dev Only the wrapped native token pays native coins in, while unwrapping.
    receive() external payable {
        if (msg.sender != wrappedNative) revert NotWrappedNative();
    }

    function swapId(Swap calldata s) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(SWAP_TYPEHASH, s.sender, s.tokenIn, s.tokenOut, s.poolFee, s.amount, s.fee, s.minOut, s.deadline, s.salt))
        );
    }

    function swapWithAuthorization(Swap calldata s, uint8 v, bytes32 r, bytes32 ss)
        external
        onlyRelayer
        whenNotPaused
        nonReentrant
        returns (bytes32 id)
    {
        if (!acceptedTokens[s.tokenIn] || !acceptedTokens[s.tokenOut]) revert TokenNotAccepted();
        if (block.timestamp > s.deadline) revert Expired();
        if (s.tokenIn == s.tokenOut) revert SameToken();
        if (s.fee >= s.amount) revert FeeTooHigh();
        if (s.minOut == 0) revert NoMinimum();
        id = swapId(s);
        if (used[id]) revert AlreadyUsed();
        used[id] = true;

        IERC20 tokenIn = IERC20(s.tokenIn);
        uint256 before = tokenIn.balanceOf(address(this));
        IERC3009Receive(s.tokenIn).receiveWithAuthorization(s.sender, address(this), s.amount, 0, s.deadline, id, v, r, ss);
        // Fee-on-transfer or no-op tokens must not be swapped for less than what was signed.
        if (tokenIn.balanceOf(address(this)) - before < s.amount) revert PaymentMissing();
        if (s.fee > 0) tokenIn.safeTransfer(feeRecipient, s.fee);

        uint256 amountIn = s.amount - s.fee;
        bool toNative = s.tokenOut == wrappedNative;
        tokenIn.forceApprove(router, amountIn);
        uint256 amountOut = ISwapRouter(router).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: s.tokenIn,
                tokenOut: s.tokenOut,
                fee: s.poolFee,
                recipient: toNative ? address(this) : s.sender,
                amountIn: amountIn,
                amountOutMinimum: s.minOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut < s.minOut) revert OutputTooLow();
        if (toNative) {
            IWrappedNative(wrappedNative).withdraw(amountOut);
            (bool paid,) = s.sender.call{value: amountOut}("");
            if (!paid) revert PayoutFailed();
        }
        emit Swapped(id, s.sender, s.tokenIn, s.tokenOut, s.amount, s.fee, amountOut);
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
