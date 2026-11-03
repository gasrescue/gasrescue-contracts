// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Local test only: wrapped native coin with 18 decimals.
contract SimWrapped is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool paid,) = msg.sender.call{value: amount}("");
        require(paid, "withdraw failed");
    }
}

/// @notice Local test only: a router and quoter with the Uniswap v3 interface and one fixed rate per
/// pair. `rates` holds output units per 1e6 input units; a pair without a rate has no pool.
contract SimRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    mapping(address => mapping(address => mapping(uint24 => uint256))) public rates;
    address public wrapped;
    uint256 public held; // wrapped coin bought for address(2), waiting for unwrapWETH9

    receive() external payable {}

    function setRate(address tokenIn, address tokenOut, uint24 fee, uint256 rate) external {
        rates[tokenIn][tokenOut][fee] = rate;
    }

    function setWrapped(address wrapped_) external {
        wrapped = wrapped_;
    }

    /// Like SwapRouter02: runs several calls on this router with the caller as msg.sender.
    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory results) {
        require(block.timestamp <= deadline, "Transaction too old");
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            require(ok, "multicall failed");
            results[i] = result;
        }
    }

    /// Like SwapRouter02: unwraps what a swap left for address(2) and pays it out as the native coin.
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable {
        uint256 amount = held;
        require(amount >= amountMinimum, "Insufficient WETH9");
        held = 0;
        if (amount > 0) {
            SimWrapped(payable(wrapped)).withdraw(amount);
            (bool paid,) = recipient.call{value: amount}("");
            require(paid, "pay failed");
        }
    }

    function quoteExactInputSingle(QuoteParams calldata p) external view returns (uint256 amountOut, uint160, uint32, uint256) {
        uint256 rate = rates[p.tokenIn][p.tokenOut][p.fee];
        require(rate > 0, "no pool");
        return ((p.amountIn * rate) / 1e6, 0, 0, 100000);
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        uint256 rate = rates[p.tokenIn][p.tokenOut][p.fee];
        require(rate > 0, "no pool");
        amountOut = (p.amountIn * rate) / 1e6;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn), "pull failed");
        // address(2) is SwapRouter02's "keep it in the router" until unwrapWETH9 pays it out.
        if (p.recipient == address(2)) held += amountOut;
        else require(IERC20(p.tokenOut).transfer(p.recipient, amountOut), "pay failed");
    }
}
