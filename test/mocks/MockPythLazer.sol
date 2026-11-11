// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Pyth's PythLazer verifier for local chains and tests: `verifyUpdate` checks an update
///         exactly as the deployed contract does, while the signer set and the fee are open for
///         anyone to set.
/// @dev The deployed PythLazer is an owner-administered upgradeable proxy. This keeps its
///      verification path — the envelope layout, the signature recovery, the signer expiry, the
///      fee and the refund of any excess — and drops the proxy and the owner, so a test can trust
///      a key it holds and move the fee without impersonating anyone.
contract MockPythLazer {
    /// @notice The fee, in wei, each `verifyUpdate` call must carry.
    uint256 public verification_fee;

    /// @notice signer => the timestamp its trust ends at; zero for a signer never trusted.
    mapping(address => uint256) public trustedSignerExpiresAt;

    /// @notice Emitted when `verifyUpdate` could not return the excess fee to its caller.
    event RefundFailed(address indexed payee, uint256 amount);

    /// @param fee The initial verification fee in wei
    constructor(uint256 fee) {
        verification_fee = fee;
    }

    /// @notice Sets the fee `verifyUpdate` requires.
    function setVerificationFee(uint256 fee) external {
        verification_fee = fee;
    }

    /// @notice Trusts `signer` until `expiresAt`; zero stops trusting it.
    function updateTrustedSigner(address signer, uint256 expiresAt) external {
        trustedSignerExpiresAt[signer] = expiresAt;
    }

    /// @notice Whether `signer` is trusted at the current block.
    function isValidSigner(address signer) public view returns (bool) {
        return block.timestamp < trustedSignerExpiresAt[signer];
    }

    /// @notice Verifies one signed update and returns its payload and signer.
    /// @dev An update is a 4-byte magic, a 65-byte signature (r, s, then the recovery ID as 0 or
    ///      1), the payload's length as two bytes, and the payload; the signature is over the
    ///      keccak256 hash of the payload.
    /// @param update The signed update
    /// @return payload The signed payload
    /// @return signer The address the signature recovers to
    function verifyUpdate(bytes calldata update) external payable returns (bytes calldata payload, address signer) {
        uint256 fee = verification_fee;
        require(msg.value >= fee, "Insufficient fee provided");

        if (update.length < 71) {
            revert("input too short");
        }
        uint32 EVM_FORMAT_MAGIC = 706910618;

        uint32 evm_magic = uint32(bytes4(update[0:4]));
        if (evm_magic != EVM_FORMAT_MAGIC) {
            revert("invalid evm magic");
        }
        uint16 payload_len = uint16(bytes2(update[69:71]));
        if (update.length < 71 + payload_len) {
            revert("input too short");
        }
        payload = update[71:71 + payload_len];
        bytes32 hash = keccak256(payload);
        (signer,,) = ECDSA.tryRecover(hash, uint8(update[68]) + 27, bytes32(update[4:36]), bytes32(update[36:68]));
        if (signer == address(0)) {
            revert("invalid signature");
        }
        if (!isValidSigner(signer)) {
            revert("invalid signer");
        }

        // A caller that cannot take the refund is still verified; the excess stays here.
        uint256 excess = msg.value - fee;
        if (excess > 0 && !payable(msg.sender).send(excess)) {
            emit RefundFailed(msg.sender, excess);
        }
    }
}
