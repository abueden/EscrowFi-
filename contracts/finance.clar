;; EscrowFi - Decentralized Finance Meets Escrow
;; A trustless escrow protocol for secure peer-to-peer transactions

;; Protocol error constants
(define-constant ERR-UNAUTHORIZED-ACCESS (err u100))
(define-constant ERR-VAULT-ALREADY-ACTIVE (err u101))
(define-constant ERR-VAULT-NOT-FOUND (err u102))
(define-constant ERR-INVALID-DEPOSIT-AMOUNT (err u103))
(define-constant ERR-INSUFFICIENT-BALANCE (err u104))
(define-constant ERR-TRANSACTION-FINALIZED (err u105))
(define-constant ERR-VAULT-TERMINATED (err u106))
(define-constant ERR-INVALID-PROTOCOL-STATE (err u107))
(define-constant ERR-INVALID-COUNTERPARTY (err u108))
(define-constant ERR-INVALID-MEDIATOR (err u109))
(define-constant ERR-DUPLICATE-PARTICIPANTS (err u110))
(define-constant ERR-INVALID-PARTICIPANT (err u111))
(define-constant ERR-RESTRICTED-ADDRESS (err u112))
(define-constant ERR-BLACKLISTED-ENTITY (err u113))
(define-constant ERR-NULL-ADDRESS (err u114))

;; Protocol configuration
(define-data-var protocol-administrator principal tx-sender)
(define-data-var platform-commission uint u10) ;; Commission in basis points (0.1%)

;; Transaction vault states
(define-constant VAULT-STATE-ACTIVE u0)
(define-constant VAULT-STATE-SETTLED u1)
(define-constant VAULT-STATE-TERMINATED u2)

;; Access control and security registries
(define-map certified-mediators principal bool)
(define-map restricted-entities principal bool)
(define-map verified-participants principal bool)

;; Transaction vault structure
(define-map transaction-vaults
    uint
    {
        depositor: principal,
        beneficiary: principal,
        mediator: principal,
        deposit-amount: uint,
        commission-fee: uint,
        vault-state: uint,
        initiation-block: uint,
        settlement-block: (optional uint),
        termination-block: (optional uint)
    }
)

;; Vault identifier sequence
(define-data-var vault-sequence-counter uint u0)

;; Enhanced participant validation framework
(define-private (validate-participant-identity (participant principal))
    (begin
        (asserts! (not (is-eq participant tx-sender)) ERR-INVALID-PARTICIPANT)
        (asserts! (not (is-eq participant (var-get protocol-administrator))) ERR-INVALID-PARTICIPANT)
        (ok true)
    )
)

(define-private (is-protocol-contract (address principal))
    (begin
        (try! (validate-participant-identity address))
        (ok (is-eq address (as-contract tx-sender)))
    )
)

(define-private (is-system-reserved (address principal))
    (begin
        (try! (validate-participant-identity address))
        (ok (or
            (is-eq address tx-sender)
            (is-eq address (var-get protocol-administrator))
            (unwrap! (is-protocol-contract address) ERR-RESTRICTED-ADDRESS)
        ))
    )
)

(define-private (verify-entity-status (address principal))
    (begin
        (try! (validate-participant-identity address))
        (asserts! (not (unwrap! (is-system-reserved address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (ok (not (default-to false (map-get? restricted-entities address))))
    )
)

(define-private (check-participant-verification (address principal))
    (begin
        (try! (validate-participant-identity address))
        (asserts! (not (unwrap! (is-system-reserved address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (ok (default-to false (map-get? verified-participants address)))
    )
)

(define-private (is-eligible-participant (address principal))
    (begin
        (try! (validate-participant-identity address))
        (asserts! (not (unwrap! (is-system-reserved address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (asserts! (unwrap! (verify-entity-status address) ERR-BLACKLISTED-ENTITY) ERR-RESTRICTED-ADDRESS)
        (ok true)
    )
)

(define-private (register-verified-participant (address principal))
    (begin
        (try! (validate-participant-identity address))
        (asserts! (not (unwrap! (is-system-reserved address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (try! (is-eligible-participant address))
        (ok (map-set verified-participants address true))
    )
)

(define-private (validate-unique-participants (p1 principal) (p2 principal) (p3 principal))
    (begin
        (try! (validate-participant-identity p2))
        (try! (validate-participant-identity p3))
        (asserts! (not (unwrap! (is-system-reserved p2) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (asserts! (not (unwrap! (is-system-reserved p3) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (ok (and
            (not (is-eq p1 p2))
            (not (is-eq p2 p3))
            (not (is-eq p1 p3))
        ))
    )
)

;; Protocol administration functions
(define-public (certify-mediator (mediator-address principal))
    (begin
        (asserts! (is-eq tx-sender (var-get protocol-administrator)) ERR-UNAUTHORIZED-ACCESS)
        (try! (validate-participant-identity mediator-address))
        (asserts! (not (unwrap! (is-system-reserved mediator-address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (try! (is-eligible-participant mediator-address))
        (try! (register-verified-participant mediator-address))
        (ok (map-set certified-mediators mediator-address true))
    )
)

(define-public (revoke-mediator-certification (mediator-address principal))
    (begin
        (asserts! (is-eq tx-sender (var-get protocol-administrator)) ERR-UNAUTHORIZED-ACCESS)
        (try! (validate-participant-identity mediator-address))
        (asserts! (not (unwrap! (is-system-reserved mediator-address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (asserts! (unwrap! (check-participant-verification mediator-address) ERR-RESTRICTED-ADDRESS) ERR-RESTRICTED-ADDRESS)
        (map-delete verified-participants mediator-address)
        (ok (map-delete certified-mediators mediator-address))
    )
)

(define-public (restrict-entity (entity-address principal))
    (begin
        (asserts! (is-eq tx-sender (var-get protocol-administrator)) ERR-UNAUTHORIZED-ACCESS)
        (try! (validate-participant-identity entity-address))
        (asserts! (not (unwrap! (is-system-reserved entity-address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (try! (is-eligible-participant entity-address))
        (map-delete verified-participants entity-address)
        (map-delete certified-mediators entity-address)
        (ok (map-set restricted-entities entity-address true))
    )
)

;; Core vault creation function
(define-public (create-transaction-vault (beneficiary-address principal) (mediator-address principal) (deposit-amount uint))
    (let
        (
            (vault-id (+ (var-get vault-sequence-counter) u1))
            (commission-amount (/ (* deposit-amount (var-get platform-commission)) u10000))
            (total-deposit (+ deposit-amount commission-amount))
        )
        ;; Comprehensive participant validation
        (try! (validate-participant-identity beneficiary-address))
        (try! (validate-participant-identity mediator-address))
        (asserts! (not (unwrap! (is-system-reserved beneficiary-address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (asserts! (not (unwrap! (is-system-reserved mediator-address) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (try! (is-eligible-participant beneficiary-address))
        (try! (is-eligible-participant mediator-address))
        (try! (register-verified-participant beneficiary-address))
        (try! (register-verified-participant mediator-address))
        (asserts! (default-to false (map-get? certified-mediators mediator-address)) ERR-INVALID-MEDIATOR)
        (asserts! (unwrap! (validate-unique-participants tx-sender beneficiary-address mediator-address) ERR-DUPLICATE-PARTICIPANTS) ERR-DUPLICATE-PARTICIPANTS)
        (asserts! (> deposit-amount u0) ERR-INVALID-DEPOSIT-AMOUNT)
        
        ;; Secure STX transfer to protocol vault
        (try! (stx-transfer? total-deposit tx-sender (as-contract tx-sender)))
        
        ;; Initialize transaction vault
        (map-set transaction-vaults
            vault-id
            {
                depositor: tx-sender,
                beneficiary: beneficiary-address,
                mediator: mediator-address,
                deposit-amount: deposit-amount,
                commission-fee: commission-amount,
                vault-state: VAULT-STATE-ACTIVE,
                initiation-block: block-height,
                settlement-block: none,
                termination-block: none
            }
        )
        
        ;; Advance vault sequence
        (var-set vault-sequence-counter vault-id)
        (ok vault-id)
    )
)

;; Platform commission configuration
(define-public (configure-platform-commission (new-commission uint))
    (begin
        (asserts! (is-eq tx-sender (var-get protocol-administrator)) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (<= new-commission u1000) ERR-INVALID-DEPOSIT-AMOUNT) ;; Maximum 10% commission
        (var-set platform-commission new-commission)
        (ok true)
    )
)

;; Protocol ownership transfer
(define-public (transfer-protocol-ownership (new-administrator principal))
    (begin
        (asserts! (is-eq tx-sender (var-get protocol-administrator)) ERR-UNAUTHORIZED-ACCESS)
        (try! (validate-participant-identity new-administrator))
        (asserts! (not (unwrap! (is-system-reserved new-administrator) ERR-RESTRICTED-ADDRESS)) ERR-RESTRICTED-ADDRESS)
        (try! (is-eligible-participant new-administrator))
        (try! (register-verified-participant new-administrator))
        (var-set protocol-administrator new-administrator)
        (ok true)
    )
)