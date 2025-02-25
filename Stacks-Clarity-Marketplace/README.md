# NFT Auction Smart Contract

A Clarity smart contract for running decentralized NFT auctions on the Stacks blockchain with SIP-010 token payment support.

## Overview

This smart contract enables the creation and management of NFT auctions on the Stacks blockchain. It allows users to auction their NFTs and accept bids in any SIP-010 compliant token.

## Features

- Create auctions for any NFT implementing the NFT trait
- Accept bids in any SIP-010 compliant token
- Automatic refund of outbid participants
- Secure transfer of NFT to the winning bidder
- Secure payment to the NFT seller

## Functions

### Place Bid

```clarity
(define-public (place-bid (auction-id uint) (bid-amount uint) (token-contract <sip-010-trait>)))
```

This function allows users to place a bid on an active auction.

**Parameters:**
- `auction-id`: The ID of the auction to bid on
- `bid-amount`: The amount of tokens to bid
- `token-contract`: The SIP-010 token contract to use for payment

**Requirements:**
- Bid amount must be greater than 0
- Bid amount must be greater than the current highest bid and the initial price
- Bidder must have sufficient token balance
- Auction must not have ended
- The NFT must be in the auction
- The token contract must match the one specified for the auction

**Behavior:**
- Transfers the bid amount from the bidder to the contract
- Refunds the previous highest bidder if one exists
- Updates the auction with the new highest bid

### End Auction

```clarity
(define-public (end-auction (auction-id uint) (token-contract <sip-010-trait>) (nft-contract <nft-trait>)))
```

This function ends an auction and transfers the NFT to the winning bidder.

**Parameters:**
- `auction-id`: The ID of the auction to end
- `token-contract`: The SIP-010 token contract used for payment
- `nft-contract`: The NFT contract for the auctioned NFT

**Requirements:**
- The auction must have reached its end block
- The token contract must match the one specified for the auction
- There must be at least one bid placed
- The NFT must be in the auction

**Behavior:**
- Transfers the NFT to the winner
- Transfers the winning bid amount to the seller
- Removes the auction from the active auctions map

### Get Auction Details

```clarity
(define-read-only (get-auction-details (auction-id uint)))
```

This function retrieves the details of an auction.

**Parameters:**
- `auction-id`: The ID of the auction to get details for

**Returns:**
- The auction data if found, or an error if not found

## Error Codes

| Code | Constant | Description |
|------|----------|-------------|
| 404 | ERR_NOT_FOUND | Auction not found |
| 1 | ERR_INVALID_BID | Bid is too low or invalid |
| 2 | ERR_AUCTION_ENDED | Auction has already ended |
| 3 | ERR_NO_NFT_IN_AUCTION | No NFT in the auction |
| 4 | ERR_AUCTION_NOT_ENDED_YET | Auction has not ended yet |
| 5 | ERR_NO_NFT_ASSET | NFT asset not found |
| 6 | ERR_NO_BIDS_PLACED | No bids have been placed |
| 7 | ERR_INVALID_TOKEN_CONTRACT | Invalid token contract |
| 8 | ERR_INSUFFICIENT_BALANCE | Insufficient token balance |

## Data Structures

### Auction

```
{
  seller-address: principal,
  nft-asset-info: (optional (tuple (nft-contract-address principal) (nft-token-id uint))),
  payment-token-contract: principal,
  initial-price: uint,
  auction-end-block: uint,
  current-highest-bidder: (optional principal),
  current-highest-bid-amount: uint
}
```

## Implementation Notes

- The contract includes a counter for generating unique auction IDs
- Auctions are stored in a map called `active-auctions`
- When a bid is placed, the previous highest bidder is automatically refunded
- The contract uses the SIP-010 trait for token transfers
- The contract uses the NFT trait for NFT transfers

## Dependencies

- SIP-010 Fungible Token Standard
- NFT Trait Implementation

## Security Considerations

- The contract holds tokens and NFTs during active auctions
- All transfers happen within atomic transactions to prevent partial state updates
- Validation checks ensure bids are valid and sufficient
- The contract does not allow ended auctions to accept bids