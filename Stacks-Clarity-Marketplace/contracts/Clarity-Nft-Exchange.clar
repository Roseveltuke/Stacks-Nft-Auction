;; Define the SIP-010 trait
(define-trait sip-010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
    (get-decimals () (response uint uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
  )
)

;; Define the NFT trait
(define-trait nft-trait
  (
    (transfer (uint principal principal) (response bool uint))
    (get-owner (uint) (response principal uint))
  )
)

;; ERROR constants
(define-constant ERR_NOT_FOUND u404)
(define-constant ERR_INVALID_BID u1)
(define-constant ERR_AUCTION_ENDED u2)
(define-constant ERR_NO_NFT_IN_AUCTION u3)
(define-constant ERR_AUCTION_NOT_ENDED_YET u4)
(define-constant ERR_NO_NFT_ASSET u5)
(define-constant ERR_NO_BIDS_PLACED u6)
(define-constant ERR_INVALID_TOKEN_CONTRACT u7)
(define-constant ERR_INSUFFICIENT_BALANCE u8)

;; Define the contract
(define-data-var auction-counter uint u0)
(define-map active-auctions
  { auction-id: uint }
  {
    seller-address: principal,
    nft-asset-info: (optional (tuple (nft-contract-address principal) (nft-token-id uint))),
    payment-token-contract: principal,
    initial-price: uint,
    auction-end-block: uint,
    current-highest-bidder: (optional principal),
    current-highest-bid-amount: uint
  }
)

;; Helper function for token transfers
(define-private (transfer-token (token-contract <sip-010-trait>) (transfer-amount uint) (sender-address principal) (recipient-address principal))
  (contract-call? token-contract transfer transfer-amount sender-address recipient-address none)
)

;; Validate the auction ID
(define-private (get-auction-by-id (auction-id uint))
  (match (map-get? active-auctions { auction-id: auction-id })
    auction-data (ok auction-data)
    (err ERR_NOT_FOUND) ;; Not found error
  ))

;; Validate the bid amount
(define-private (validate-bid-amount 
  (auction-data { 
    seller-address: principal, 
    nft-asset-info: (optional (tuple (nft-contract-address principal) (nft-token-id uint))), 
    payment-token-contract: principal, 
    initial-price: uint, 
    auction-end-block: uint, 
    current-highest-bidder: (optional principal), 
    current-highest-bid-amount: uint 
  }) 
  (bid-amount uint))
  (if (and 
        (> bid-amount (get current-highest-bid-amount auction-data))
        (> bid-amount (get initial-price auction-data)))
    (ok true)
    (err ERR_INVALID_BID) ;; Invalid bid
  )
)

;; Check if the bidder has sufficient balance
(define-private (check-sufficient-balance (token-contract <sip-010-trait>) (bid-amount uint))
  (match (contract-call? token-contract get-balance tx-sender)
    balance (if (>= balance bid-amount)
              (ok true)
              (err ERR_INSUFFICIENT_BALANCE))
    error (err ERR_INSUFFICIENT_BALANCE)
  )
)

;; Place a bid on an auction
(define-public (place-bid (auction-id uint) (bid-amount uint) (token-contract <sip-010-trait>))
  (let 
    ((auction-data (try! (get-auction-by-id auction-id))))
    (asserts! (> bid-amount u0) (err ERR_INVALID_BID))
    (try! (validate-bid-amount auction-data bid-amount))
    (try! (check-sufficient-balance token-contract bid-amount))
    (asserts! (< block-height (get auction-end-block auction-data)) (err ERR_AUCTION_ENDED)) 
    (asserts! (is-some (get nft-asset-info auction-data)) (err ERR_NO_NFT_IN_AUCTION))
    (asserts! (is-eq (contract-of token-contract) (get payment-token-contract auction-data)) (err ERR_INVALID_TOKEN_CONTRACT))

    ;; Transfer the bid amount to the contract
    (try! (transfer-token token-contract bid-amount tx-sender (as-contract tx-sender)))

    ;; Refund the previous highest bidder if exists
    (match (get current-highest-bidder auction-data)
      previous-bidder (try! (transfer-token token-contract (get current-highest-bid-amount auction-data) (as-contract tx-sender) previous-bidder))
      true
    )

    ;; Update the auction with the new highest bid
    (map-set active-auctions
      { auction-id: auction-id }
      (merge auction-data { 
        current-highest-bidder: (some tx-sender), 
        current-highest-bid-amount: bid-amount 
      }))
    (ok true)
  )
)

;; End the auction
(define-public (end-auction (auction-id uint) (token-contract <sip-010-trait>) (nft-contract <nft-trait>))
  (let ((auction-data (try! (get-auction-by-id auction-id))))
    (asserts! (>= block-height (get auction-end-block auction-data)) (err ERR_AUCTION_NOT_ENDED_YET))
    (asserts! (is-eq (contract-of token-contract) (get payment-token-contract auction-data)) (err ERR_INVALID_TOKEN_CONTRACT))
    (match (get current-highest-bidder auction-data)
      winner-address 
      (begin
        ;; Transfer the NFT to the winner
        (match (get nft-asset-info auction-data)
          nft-details
          (begin
            (let ((nft-contract-address (get nft-contract-address nft-details))
                  (nft-id (get nft-token-id nft-details)))
              ;; Verify that the provided nft-contract matches the one in the auction
              (asserts! (is-eq (contract-of nft-contract) nft-contract-address) (err ERR_NOT_FOUND))
              (try! (as-contract (contract-call? nft-contract transfer nft-id tx-sender winner-address))))

            ;; Transfer the winning bid to the seller
            (let ((winning-bid-amount (get current-highest-bid-amount auction-data))
                  (seller-address (get seller-address auction-data)))
              (try! (as-contract (transfer-token token-contract winning-bid-amount tx-sender seller-address))))
            
            ;; Remove the auction from the map after it's ended
            (map-delete active-auctions { auction-id: auction-id })
            (ok true))
          (err ERR_NO_NFT_ASSET)
        ))
      (err ERR_NO_BIDS_PLACED)
    )
  )
)

;; Getter for auction details
(define-read-only (get-auction-details (auction-id uint))
  (get-auction-by-id auction-id)
)