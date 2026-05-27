// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice GCC — Guaranteed Capacity Credit.
/// @dev OpenZeppelin ERC20 + ERC20Permit (EIP-2612) + a custom EIP-3009
///      authorization-transfer surface used by the AI.GG x402 facilitator.
///      Maintained errors mirror the prior in-house GCT implementation so
///      callers (facilitator client, tests, dashboards) keep stable selectors.
contract GCC is ERC20, ERC20Permit, Ownable {
    uint256 public immutable maxSupply;
    bool public mintingFinalized;

    /// @notice EIP-3009 authorization replay table: authorization is single-use.
    mapping(address authorizer => mapping(bytes32 nonce => bool used)) public authorizationState;

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);
    event MintingFinalized(address indexed owner);

    error NotOwner();
    error ZeroAddress();
    error InvalidMaxSupply();
    error MaxSupplyExceeded();
    error MintingClosed();
    error AuthorizationAlreadyUsed();
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error InvalidSignature();
    error CallerMustBePayee();

    constructor(
        string memory name_,
        string memory symbol_,
        address initialRecipient,
        uint256 initialSupply,
        uint256 maxSupply_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {
        if (initialRecipient == address(0) && initialSupply != 0) {
            revert ZeroAddress();
        }
        if (maxSupply_ == 0 || initialSupply > maxSupply_) revert InvalidMaxSupply();
        maxSupply = maxSupply_;
        if (initialSupply != 0) {
            _mintCapped(initialRecipient, initialSupply);
        }
    }

    function mint(address to, uint256 value) external onlyOwner {
        if (mintingFinalized) revert MintingClosed();
        _mintCapped(to, value);
    }

    function finalizeMinting() external onlyOwner {
        mintingFinalized = true;
        emit MintingFinalized(_msgSender());
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _requireValidAuthorizationWindow(from, validAfter, validBefore, nonce);
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        _requireValidSignature(from, structHash, v, r, s);
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

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
    ) external {
        if (msg.sender != to) revert CallerMustBePayee();
        _requireValidAuthorizationWindow(from, validAfter, validBefore, nonce);
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
            )
        );
        _requireValidSignature(from, structHash, v, r, s);
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        _requireValidSignature(authorizer, structHash, v, r, s);
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /// @notice Override OpenZeppelin Ownable's owner check so the revert
    ///         selector stays `GCC.NotOwner` for downstream tooling parity.
    function _checkOwner() internal view override {
        if (owner() != _msgSender()) revert NotOwner();
    }

    function _requireValidAuthorizationWindow(
        address authorizer,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[authorizer][nonce]) revert AuthorizationAlreadyUsed();
    }

    function _requireValidSignature(
        address expectedSigner,
        bytes32 structHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        // Accept 0/1 V (some wallets normalize to 0/1 instead of 27/28).
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignature();

        bytes32 digest = _hashTypedDataV4(structHash);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
        if (err != ECDSA.RecoverError.NoError) revert InvalidSignature();
        if (recovered == address(0) || recovered != expectedSigner) revert InvalidSignature();
    }

    function _mintCapped(address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() + value > maxSupply) revert MaxSupplyExceeded();
        _mint(to, value);
    }
}
