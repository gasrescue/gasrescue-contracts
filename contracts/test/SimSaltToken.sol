// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Local test token only: 6 decimals and an EIP-2612 permit whose EIP-712 domain has a salt
/// (the chain id) instead of a chainId field, like USDT0 and USDC.e on Polygon. No EIP-3009.
contract SimSaltToken is ERC20 {
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => uint256) public nonces;

    constructor(string memory name_) ERC20(name_, name_) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract,bytes32 salt)"),
                keccak256(bytes(name_)),
                keccak256(bytes("1")),
                address(this),
                bytes32(block.chainid)
            )
        );
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(block.timestamp <= deadline, "permit expired");
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline)))
        );
        require(ECDSA.recover(digest, v, r, s) == owner, "invalid permit");
        _approve(owner, spender, value);
    }
}
