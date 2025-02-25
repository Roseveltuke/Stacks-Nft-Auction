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
(define-constant ERR_INVALID_AUCTION_DURATION u9)
(define-constant ERR_INVALID_INITIAL_PRICE u10)
(define-constant ERR_INVALID_NFT_CONTRACT u11)
(define-constant ERR_INVALID_NFT_TOKEN_ID u12)
(define-constant ERR_INVALID_PAYMENT_TOKEN u13)

;; Define the contract
(define-data-var auction-counter uint u0)
(define-map active-auctions
  { auction-id: uint }
  {
    seller-address: principal,
    nft-asset-info: (optional (tuple (nft-contract-address principal) (nft-token-id uint))),
    payment-token-contract: (optional principal),
    is-stx-payment: bool,
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

;; Helper function for STX transfers
(define-private (transfer-stx (amount uint) (sender principal) (recipient principal))
  (stx-transfer? amount sender recipient)
)

;; Validate the auction ID
(define-private (get-auction-by-id (auction-id uint))
  (match (map-get? active-auctions { auction-id: auction-id })
    auction-data (ok auction-data)
    (err ERR_NOT_FOUND)
  ))

;; Validate the bid amount
(define-private (validate-bid-amount 
  (auction-data { 
    seller-address: principal, 
    nft-asset-info: (optional (tuple (nft-contract-address principal) (nft-token-id uint))), 
    payment-token-contract: (optional principal), 
    is-stx-payment: bool,
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
    (err ERR_INVALID_BID)
  )
)

;; Place a bid on an auction
(define-public (place-bid (auction-id uint) (bid-amount uint) (token-contract <sip-010-trait>))
  (let 
    ((auction-data (try! (get-auction-by-id auction-id))))
    (asserts! (> bid-amount u0) (err ERR_INVALID_BID))
    (try! (validate-bid-amount auction-data bid-amount))
    (asserts! (< block-height (get auction-end-block auction-data)) (err ERR_AUCTION_ENDED)) 
    (asserts! (is-some (get nft-asset-info auction-data)) (err ERR_NO_NFT_IN_AUCTION))

    ;; Check sufficient balance and transfer the bid amount to the contract
    (if (get is-stx-payment auction-data)
      (begin
        (asserts! (>= (stx-get-balance tx-sender) bid-amount) (err ERR_INSUFFICIENT_BALANCE))
        (try! (stx-transfer? bid-amount tx-sender (as-contract tx-sender)))
      )
      (begin
        (asserts! (is-eq (unwrap! (get payment-token-contract auction-data) (err ERR_INVALID_TOKEN_CONTRACT)) (contract-of token-contract)) (err ERR_INVALID_TOKEN_CONTRACT))
        (asserts! (>= (unwrap! (contract-call? token-contract get-balance tx-sender) (err ERR_INVALID_TOKEN_CONTRACT)) bid-amount) (err ERR_INSUFFICIENT_BALANCE))
        (try! (contract-call? token-contract transfer bid-amount tx-sender (as-contract tx-sender) none))
      )
    )

    ;; Refund the previous highest bidder if exists
    (match (get current-highest-bidder auction-data)
      previous-bidder 
      (if (get is-stx-payment auction-data)
        (try! (as-contract (stx-transfer? (get current-highest-bid-amount auction-data) tx-sender previous-bidder)))
        (try! (as-contract (contract-call? token-contract transfer (get current-highest-bid-amount auction-data) tx-sender previous-bidder none)))
      )
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
(define-public (end-auction (auction-id uint) (nft-contract <nft-trait>) (token-contract <sip-010-trait>))
  (let ((auction-data (try! (get-auction-by-id auction-id))))
    (asserts! (>= block-height (get auction-end-block auction-data)) (err ERR_AUCTION_NOT_ENDED_YET))
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
              (if (get is-stx-payment auction-data)
                (try! (as-contract (stx-transfer? winning-bid-amount tx-sender seller-address)))
                (begin
                  (asserts! (is-eq (unwrap! (get payment-token-contract auction-data) (err ERR_INVALID_TOKEN_CONTRACT)) (contract-of token-contract)) (err ERR_INVALID_TOKEN_CONTRACT))
                  (try! (as-contract (contract-call? token-contract transfer winning-bid-amount tx-sender seller-address none)))
                )
              ))
            
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

;; Helper function to validate NFT ownership
(define-private (validate-nft-ownership (nft-contract <nft-trait>) (nft-token-id uint))
  (match (contract-call? nft-contract get-owner nft-token-id)
    owner (ok (asserts! (is-eq tx-sender owner) (err ERR_INVALID_NFT_TOKEN_ID)))
    error (err ERR_INVALID_NFT_TOKEN_ID)
  )
)

;; Create a new auction
(define-public (create-auction (nft-contract <nft-trait>) (nft-token-id uint) (payment-token-contract (optional <sip-010-trait>)) (initial-price uint) (auction-duration uint))
  (let
    (
      (auction-id (+ (var-get auction-counter) u1))
      (auction-end-block (+ block-height auction-duration))
    )
    ;; Validate inputs
    (asserts! (is-ok (contract-call? nft-contract get-owner nft-token-id)) (err ERR_INVALID_NFT_TOKEN_ID))
    (asserts! (> initial-price u0) (err ERR_INVALID_INITIAL_PRICE))
    (asserts! (> auction-duration u0) (err ERR_INVALID_AUCTION_DURATION))
    (asserts! (< auction-end-block (+ block-height u10000)) (err ERR_INVALID_AUCTION_DURATION))
    (try! (validate-nft-ownership nft-contract nft-token-id))
    
    ;; Validate payment token if present
    (let ((validated-payment-token-contract
           (match payment-token-contract
             token (begin
               ;; Validate SIP-010 implementation
               (asserts! (is-ok (contract-call? token get-name)) (err ERR_INVALID_PAYMENT_TOKEN))
               (asserts! (is-ok (contract-call? token get-symbol)) (err ERR_INVALID_PAYMENT_TOKEN))
               (asserts! (is-ok (contract-call? token get-decimals)) (err ERR_INVALID_PAYMENT_TOKEN))
               (some (contract-of token))
             )
             none
           )))
    
      ;; Transfer NFT to the contract
      (try! (contract-call? nft-contract transfer nft-token-id tx-sender (as-contract tx-sender)))
    
      ;; Create the auction with properly typed data
      (map-set active-auctions
        { auction-id: auction-id }
        {
          seller-address: tx-sender,
          nft-asset-info: (some { nft-contract-address: (contract-of nft-contract), nft-token-id: nft-token-id }),
          payment-token-contract: validated-payment-token-contract,
          is-stx-payment: (is-none validated-payment-token-contract),
          initial-price: initial-price,
          auction-end-block: auction-end-block,
          current-highest-bidder: none,
          current-highest-bid-amount: u0
        }
      )
      (var-set auction-counter auction-id)
      (ok auction-id)
    )
  )
)