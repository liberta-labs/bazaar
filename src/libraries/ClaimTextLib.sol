// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ClaimTextLib
/// @notice External library holding the static text of the UMA claims Bazaar asserts: the
///         numbered eligibility checks of a pair listing, the validation steps of an identifier
///         upgrade, and the reason categories and validation steps of a termination proposal.
///         Linked as an external library so the text's bytecode lives outside the EIP-170
///         budgets of BazaarFactory and BazaarPairTerminator, which write each claim's
///         contract-specific parts (chain ID, feed IDs, pair and assertion IDs, the fenced
///         proposer text) and concatenate these blocks between them.
library ClaimTextLib {
    /// @notice The checks UMA verifiers apply to a pair listing claim, numbered (1) to (6), and
    ///         the rule that the assertion is invalid if any fails. The checks refer to the asset
    ///         description, feed IDs and trading flag the factory writes ahead of this block.
    /// @return The numbered checks and the invalidity rule, as UTF-8 text
    function listingChecks() external pure returns (bytes memory) {
        return abi.encodePacked(
            " UMA VERIFIERS MUST CHECK ALL OF THE FOLLOWING: "
            "(1) FEED: Every Pyth Pro feed ID listed above (for a composite, BOTH legs) is the numeric ID of an ACTIVE feed "
            "in the Pyth Pro price feed registry, and the base feed matches the asset description stated above. "
            "Pyth Core feed IDs are a different namespace and are INVALID. "
            "Every listed feed must publish a price, a non-zero confidence interval and a feed update timestamp; "
            "a feed that does not - e.g., a funding-rate or redemption-rate feed - is INVALID. "
            "(2) ELIGIBLE ASSET: The base feed (for a composite, the base leg) prices exactly one of: "
            "(a) the common shares of a publicly traded company, or a depositary receipt for those shares; "
            "(b) a currency, as a spot FX rate; (c) a physical commodity; (d) a cryptocurrency; "
            "(e) an unleveraged exchange-traded fund that holds the shares of a broad stock market index "
            "(e.g., the S&P 500 or the Nasdaq-100). "
            "Every other asset is INVALID, including: indices themselves; every other fund, ETF, ETN and trust; "
            "preferred shares, bonds and other fixed-income or yield-bearing instruments; "
            "futures, options, warrants and anything else with an expiry, settlement or resolution date; "
            "leveraged or inverse products; "
            "stablecoins and other assets pegged, rebased or managed toward a target price; "
            "interest-rate, funding-rate, volatility and economic-data series; prediction-market outcomes; "
            "and shares that are not publicly traded. "
            "(3) SPOT FEED ONLY, ONE MARKET PER ASSET: Where Pyth Pro has a feed for the asset's own spot price, "
            "that feed is the only eligible one. Every other feed that follows the same asset is INVALID - e.g., "
            "a Pyth-computed index, synthetic or 24/7 price of a stock that has its own feed; "
            "a tokenized, wrapped, bridged or staked version of the asset; a perpetual; "
            "or a feed restricted to an extended or partial trading session (symbols ending .PRE, .POST, .ON or .EXT). "
            "Such a feed is eligible only if Pyth Pro has NO spot feed for the asset in any currency, "
            "and it must still pass every other check. "
            "One security reachable through several spot feeds - a depositary receipt and the share it represents, "
            "or one share listed in several currencies - is ONE asset: only its USD-quoted feed is eligible, "
            "and it may be proposed as a composite only if no USD-quoted feed for it exists. "
            "Share classes of one issuer that differ only in voting rights are ONE asset: "
            "only the class with the greater trading volume is eligible. "
            "ETFs that track the same index are ONE asset: only the one with the highest average daily dollar trading "
            "volume over the 30 days before the proposal is eligible, and none is eligible while a Bazaar pair on "
            "another ETF tracking that index is live or proposed and pending. "
            "(4) USD PRICE: The pair must be priced in US dollars. A base feed quoted in USD is proposed on its own. "
            "A base feed quoted in another currency is eligible ONLY as a composite, and only if that currency is one of: "
            "EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH, CNY, KRW, TWD. "
            "Its quote leg must be the Pyth Pro spot FX feed between USD and EXACTLY that currency; "
            "an asset quoted in onshore CNY takes the offshore USD/CNH feed, not USD/CNY. "
            "The 'quote leg inverted' flag must be accurate: 'false' when the FX feed reports US dollars per unit of that "
            "currency (e.g., GBP/USD), 'true' when it reports units of that currency per US dollar (e.g., USD/JPY). "
            "In the Pyth Pro registry the FX feed's symbol shows it: FX.USD/XXX is 'true' and FX.XXX/USD is 'false'. "
            "As a sanity check, the composed price (the base leg divided by the quote leg when 'true', multiplied when "
            "'false') must be close to the asset's actual US dollar price. "
            "A spot FX rate is itself eligible only as a single feed quoted in USD (e.g., EUR/USD). "
            "(5) TRADING SCHEDULE: The 'continuously traded' flag is accurate: "
            "'true' only for an asset that trades 24/7 with no scheduled breaks (cryptocurrencies); "
            "'false' for shares, ETFs, FX, commodities and every composite, including an asset whose feed publishes around the "
            "clock on weekdays but stops over the weekend. "
            "(6) NO PENDING TERMINATION EVENT: No event that would be valid grounds for terminating the pair is already "
            "officially announced for the asset or for any feed listed above - e.g., a Pyth Pro feed decommission, a delisting, "
            "a merger or acquisition with a scheduled closing, a bankruptcy, a split, reverse split, spinoff, rights offering "
            "or one-time distribution exceeding 5% of the asset's price, or a redenomination. "
            "Propose such a market once the event has passed. " "Assertion is INVALID if ANY of the above checks fail."
        );
    }

    /// @notice The validation steps of an identifier-upgrade claim: the proposed identifier is
    ///         whitelisted and suited to truth assertions, and the upgrade is necessary.
    /// @return The validation steps and the invalidity rule, as UTF-8 text
    function identifierUpgradeHowToValidate() external pure returns (bytes memory) {
        return abi.encodePacked(
            " HOW TO VALIDATE: "
            "NOTE: Identifiers are displayed as hex-encoded bytes32 values. To verify, convert the hex to a UTF-8 string. "
            "UMA voters should verify that: "
            "(1) The proposed identifier is approved and active on UMA's IdentifierWhitelist, and is appropriate for "
            "adjudicating free-form truth assertions of the kind Bazaar submits (pair listings and market terminations). "
            "(2) The upgrade is necessary: the current identifier is deprecated, de-whitelisted, scheduled for removal, "
            "or otherwise unsuitable for those assertions. "
            "Assertion is INVALID if: the proposed identifier is not approved, is not suited to truth assertions, "
            "or there is no need for the change (the current identifier remains functional and appropriate)."
        );
    }

    /// @notice The reason categories a termination proposal declares, (1) to (4), each with the
    ///         grounds it accepts. The certainty each future-dated category demands exists
    ///         because acceptance is irrevocable: an event that is later cancelled still ends
    ///         the market.
    /// @return The reason categories and the grounds each accepts, as UTF-8 text
    function terminationReasons() external pure returns (bytes memory) {
        return abi.encodePacked(
            " VALID TERMINATION REASONS (the proposal declares one; the evidence must establish it): "
            "(1) ORACLE DECOMMISSION: A Pyth Pro feed listed above has stopped publishing prices or is scheduled to be "
            "decommissioned. For a composite, EITHER leg is sufficient grounds. "
            "(2) ASSET CESSATION: The asset has been or will be delisted from the exchange the feed tracks, even if it keeps "
            "trading OTC: an exchange delisting, a merger or acquisition (cash or stock), a bankruptcy, or an indefinite "
            "regulatory halt. A cessation still ahead counts only once it is officially confirmed with a fixed effective date - "
            "an exchange-published delisting date, a merger or acquisition with shareholder and regulatory approval and a "
            "scheduled closing date, a court-confirmed bankruptcy plan; one merely proposed, not yet approved, or contested "
            "is NOT sufficient grounds. "
            "(3) STRUCTURAL CHANGE: An event will make the asset's price series discontinuous: the price published after it "
            "is not comparable to the price before it. The event must be officially scheduled by the issuer, project or price "
            "provider with a fixed record, effective, or ex-date; a contemplated, proposed, or still-pending-approval event is "
            "NOT sufficient grounds. Examples (non-exhaustive): splits, reverse splits, spinoffs, rights offerings, special "
            "dividends or other one-time distributions exceeding 5% of the asset's price, token redenominations or "
            "migrations, a re-basing or methodology change of a computed price, and redenomination of the quote currency of "
            "a composite pair. NOT valid: regular cash dividends, and market-driven price moves of ANY expected size (e.g., "
            "earnings, court rulings, regulatory or macroeconomic news) - anticipated volatility is tradeable risk. "
            "(4) PYTH VERIFIER MIGRATION: The Pyth Pro verifier contract at the address listed above is deprecated, is being "
            "replaced by a contract at a new address, or no longer verifies the signed updates Pyth distributes, so the pair "
            "cannot verify prices."
        );
    }

    /// @notice The validation steps of a termination claim. Every figure is rendered from the
    ///         argument the terminator passes, read from the constant that enforces it, so the
    ///         text cannot drift from the contract.
    /// @param livenessHours The proposal liveness in hours: the earliest cutoff acceptance alone
    ///        enforces after submission
    /// @param voteLeadHours The earliest cutoff after submission the insurers' vote may enforce,
    ///        in hours
    /// @param haltLeadSeconds How long before the cutoff the pair halts, in seconds
    /// @param cutoffLeadSeconds The lead a cutoff already past, or sooner than this, is moved
    ///        to after acceptance, in seconds
    /// @param graceHours How long the cutoff's update is awaited before the pair settles at its own
    ///        last stored price, counted from the cutoff or, for a pair the vote halted, from when
    ///        the assertion's result is known if that is later, in hours; also how long after an
    ///        accepted proposal's timestamp that caps a chain the stored price may settle it
    /// @param verdictGraceDays How long after submission a pair the vote halted waits for this
    ///        assertion's result before settling without one, in days
    /// @param voterLockDays How long after the settlement the voters of a halt the assertion did
    ///        not uphold may not redeem, in days
    /// @param levyFloorPercent The least share of their voted shares those voters forfeit when the
    ///        assertion has no result, in percent
    /// @param sampleCount How many prices the median a halt the assertion did not uphold settles
    ///        at is taken over
    /// @param sampleSpacingMinutes How far apart in minutes those prices are taken, at least
    /// @param chainLastResortDays How long after the timestamp a pair the vote halted waits for
    ///        that median before settling at its own last stored price, in days
    /// @return The validation steps with each figure rendered, as UTF-8 text
    function terminationHowToValidate(
        uint256 livenessHours,
        uint256 voteLeadHours,
        uint256 haltLeadSeconds,
        uint256 cutoffLeadSeconds,
        uint256 graceHours,
        uint256 verdictGraceDays,
        uint256 voterLockDays,
        uint256 levyFloorPercent,
        uint256 sampleCount,
        uint256 sampleSpacingMinutes,
        uint256 chainLastResortDays
    ) external pure returns (bytes memory) {
        string memory liveness = Strings.toString(livenessHours);
        string memory voteLead = Strings.toString(voteLeadHours);
        string memory halt = Strings.toString(haltLeadSeconds);
        string memory lead = Strings.toString(cutoffLeadSeconds);
        string memory grace = Strings.toString(graceHours);
        string memory verdictGrace = Strings.toString(verdictGraceDays);
        string memory voterLock = Strings.toString(voterLockDays);
        string memory levyFloor = Strings.toString(levyFloorPercent);
        return bytes.concat(
            abi.encodePacked(
                " HOW TO VALIDATE: Identify the pair's asset from the feed IDs listed above, using the Pyth Pro price feed "
                "registry: the evidence must concern that asset and establish the declared reason category. "
                "Grounds that also fit another category do not invalidate the proposal. "
                "Verify the proposer's evidence (the bracket-fenced final section) against official sources: Pyth Network's "
                "announcements, status page and price feed registry for (1) and (4); exchange notices or regulatory filings "
                "for (2); the issuer's or project's official announcements, exchange bulletins or regulatory filings for (3). "
                "The proposed last trading timestamp must be reasonable: at or right before the last moment the asset trades "
                "under pre-event conditions, neither unnecessarily early nor later than the event requires. "
                "If the event has already occurred, the earliest timestamp acceptance alone can enforce (",
                liveness,
                " hours after submission) is the reasonable choice. "
            ),
            abi.encodePacked(
                "SETTLEMENT: The pair halts trading ",
                halt,
                " seconds before the scheduled timestamp and settles at the price carried by the Pyth Pro one-second update "
                "stamped with the scheduled timestamp, the feed's most recent price as of that second. "
                "A timestamp already past, or less than ",
                lead,
                " seconds away, when the proposal is accepted is moved to ",
                lead,
                " seconds after acceptance. For ",
                grace,
                " hours after the scheduled timestamp only that update settles the pair; after that, a call that does not "
                "bring it, or brings one that carries no price, settles the pair at its own last stored price. "
            ),
            abi.encodePacked(
                    "INSURER VOTE: This proposal also opens a vote of the holders of the pair's insurance fund shares: if holders "
                    "of 60 percent of the shares vote for it, the pair halts at the proposed timestamp whether or not this "
                    "assertion has resolved. A proposed timestamp sooner than ",
                    liveness,
                    " hours after submission, down to ",
                    voteLead,
                    " hours, takes effect as proposed only through that vote: without it this assertion is accepted only after "
                    "the timestamp, which is then moved as described above. "
                    "A pair the vote halted settles under this assertion's result. "
                    "Resolved TRUE: as described above, except that the ",
                    grace,
                    " hours run from the end of this assertion's liveness or, if it is disputed, from the on-chain recording of "
                    "its result, when that is later than the timestamp. Resolved FALSE: at the median of ",
                    Strings.toString(sampleCount),
                    " prices from Pyth Pro one-second updates - the first the earliest update carrying a price generated at or "
                    "after the timestamp, each later one the earliest carrying a price generated at least ",
                    Strings.toString(sampleSpacingMinutes),
                    " minutes after the update before it (for a composite feed, the later of its two legs' updates) - and the "
                    "holders who voted for it forfeit half of their voted shares. Where a proposal accepted for the pair names a "
                    "timestamp at or after this one, no price in an update stamped after that timestamp counts. From ",
                    Strings.toString(chainLastResortDays),
                    " days after the timestamp, or from ",
                    grace,
                    " hours after that accepted timestamp if that is sooner, a call that does not bring such a set of prices "
                    "settles the pair at its own last stored price. " "Without a result ",
                    verdictGrace,
                    " days after submission: as for FALSE, but those holders forfeit half of the dissenting fraction of their "
                    "voted shares, never less than ",
                    levyFloor,
                    " percent of them. In both cases they may not redeem for ",
                    voterLock,
                    " days after the settlement. "
                    "ACCEPTANCE IS FINAL: an accepted proposal cannot be withdrawn, and its cutoff can never be delayed or "
                    "cancelled. It can only move earlier: a later UMA proposal with an earlier cutoff, judged on its own event, "
                    "or a vote of the pair's insurance fund holders may bring it forward, and the protocol's stale-price and "
                    "insolvency paths end the pair at once. "
                    "An event that may still be cancelled or rescheduled therefore makes the assertion INVALID. "
                    "Assertion is INVALID if: the evidence does not establish the declared category, the event is not confirmed "
                    "as that category requires, evidence is fabricated or unverifiable, or the timestamp is unreasonable. "
                )
        );
    }
}
