// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title TestnetUSDC
/// @notice A USDC stand-in for a public testnet, with a faucet anyone can claim from and an owner
///         who mints at will to seed listings and market makers.
/// @dev Matches USDC where the protocol depends on it: 6 decimals, which every BAZAAR_SCALE
///      conversion assumes, and an ERC-2612 permit, which relayed calls execute before pulling the
///      relayer fee. It has none of Circle's blacklist, pause or upgradeable proxy, and its permit
///      domain carries its own name, so a run that must exercise those deploys against Circle's
///      token instead (HelperConfig's SEPOLIA_OFFICIAL_USDC).
///
///      The cooldown is per address, so it paces a tester rather than bounding supply: on a testnet
///      the faucet only has to keep anyone from minting an unbounded balance in one call.
contract TestnetUSDC is ERC20, ERC20Permit, Ownable2Step {
    /// @notice What one faucet claim pays, in USDC units (6 decimals).
    uint256 public constant FAUCET_AMOUNT = 10_000 * 1e6;

    /// @notice How long an address waits between faucet claims.
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    /// @notice When each address last claimed from the faucet; 0 for never.
    mapping(address => uint256) public lastClaimTs;

    /// @notice A faucet claim paid out.
    /// @param to The claimer
    /// @param amount The amount minted, in USDC units
    event FaucetClaimed(address indexed to, uint256 amount);

    /// @param nextClaimTs The first timestamp at which the caller may claim again
    error TestnetUSDC__FaucetCooldown(uint256 nextClaimTs);

    /// @param initialOwner The account that may mint without limit
    constructor(address initialOwner)
        ERC20("Bazaar Testnet USDC", "USDC")
        ERC20Permit("Bazaar Testnet USDC")
        Ownable(initialOwner)
    {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints FAUCET_AMOUNT to the caller, at most once per FAUCET_COOLDOWN per address.
    function claim() external {
        uint256 last = lastClaimTs[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_COOLDOWN) {
            revert TestnetUSDC__FaucetCooldown(last + FAUCET_COOLDOWN);
        }
        lastClaimTs[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }

    /// @notice Mints any amount to any account.
    /// @param to The recipient
    /// @param amount The amount, in USDC units (6 decimals)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
