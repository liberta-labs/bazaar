import { CompositeFeedRegistered } from "../generated/BazaarOracle/BazaarOracle"
import { CompositeFeed } from "../generated/schema"

export function handleCompositeFeedRegistered(event: CompositeFeedRegistered): void {
  // The registry is write-once: a composite ID is registered at most once.
  let feed = new CompositeFeed(event.params.compositeId)
  feed.baseId = event.params.baseId
  feed.quoteId = event.params.quoteId
  feed.invertQuote = event.params.invertQuote
  feed.registeredAtTimestamp = event.block.timestamp
  feed.transactionHash = event.transaction.hash
  feed.save()
}
