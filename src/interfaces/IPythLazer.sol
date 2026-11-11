// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

/// @title IPythLazer
/// @notice The part of Pyth's PythLazer contract, the on-chain verifier of Pyth Pro price updates,
///         that BazaarOracle calls.
/// @dev PythLazer stores no prices. It checks that an update is signed by a signer Pyth currently
///      trusts and hands back the signed payload; reading the payload, and judging how old it is,
///      is left to the caller.
interface IPythLazer {
    /// @notice The fee, in wei, that one `verifyUpdate` call must carry.
    function verification_fee() external view returns (uint256);

    /// @notice Verifies one signed update and returns its payload.
    /// @dev Reverts unless `update` is in the EVM envelope format, its signature recovers to a
    ///      signer whose trust has not expired, and `msg.value` covers `verification_fee`. Any
    ///      excess is sent back to the caller with a 2300-gas stipend and stays in PythLazer if
    ///      the caller cannot receive it.
    /// @param update The signed update: envelope magic, signature, payload length, payload
    /// @return payload The signed payload
    /// @return signer The address the signature recovers to
    function verifyUpdate(bytes calldata update) external payable returns (bytes memory payload, address signer);
}
