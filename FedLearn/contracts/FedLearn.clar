;; Federated Learning for Privacy-Preserving DeFi

;; This smart contract implements a federated learning system for DeFi applications
;; that allows multiple participants to collaboratively train machine learning models
;; without sharing their raw data. Participants submit encrypted model updates,
;; which are aggregated to improve a global model while preserving individual privacy.
;; The contract handles participant registration, model update submission, aggregation,
;; rewards distribution, and reputation management.

;; constants

;; Error codes for contract operations
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ALREADY-REGISTERED (err u101))
(define-constant ERR-NOT-REGISTERED (err u102))
(define-constant ERR-INVALID-UPDATE (err u103))
(define-constant ERR-ROUND-NOT-ACTIVE (err u104))
(define-constant ERR-INSUFFICIENT-PARTICIPANTS (err u105))
(define-constant ERR-ALREADY-SUBMITTED (err u106))
(define-constant ERR-INVALID-STAKE (err u107))
(define-constant ERR-NO-REWARDS (err u108))

;; Contract configuration constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-STAKE-AMOUNT u1000000) ;; Minimum stake in micro-STX (1 STX)
(define-constant MIN-PARTICIPANTS u3) ;; Minimum participants needed for aggregation
(define-constant REWARD-PER-UPDATE u100000) ;; Reward per valid update (0.1 STX)
(define-constant MAX-UPDATE-SIZE u1000) ;; Maximum size of model update hash

;; data maps and vars

;; Tracks registered participants with their stake and reputation
;; Principal -> {stake: uint, reputation-score: uint, total-contributions: uint, is-active: bool}
(define-map participants
    principal
    {
        stake: uint,
        reputation-score: uint,
        total-contributions: uint,
        is-active: bool
    }
)

;; Stores model updates submitted by participants for each training round
;; {round: uint, participant: principal} -> {update-hash: string, timestamp: uint, verified: bool}
(define-map model-updates
    {round: uint, participant: principal}
    {
        update-hash: (string-ascii 64),
        timestamp: uint,
        verified: bool
    }
)

;; Tracks aggregated global model state for each round
;; uint (round) -> {model-hash: string, participant-count: uint, total-stake: uint, aggregation-timestamp: uint}
(define-map global-models
    uint
    {
        model-hash: (string-ascii 64),
        participant-count: uint,
        total-stake: uint,
        aggregation-timestamp: uint
    }
)

;; Tracks pending rewards for participants
;; Principal -> uint (amount in micro-STX)
(define-map pending-rewards principal uint)

;; Global state variables
(define-data-var current-round uint u0)
(define-data-var round-active bool false)
(define-data-var total-registered-participants uint u0)
(define-data-var round-submissions uint u0)

;; private functions

;; Validates if a participant is registered and active
;; @param participant: principal address to validate
;; @returns: bool indicating if participant is valid and active
(define-private (is-valid-participant (participant principal))
    (match (map-get? participants participant)
        participant-data (get is-active participant-data)
        false
    )
)

;; Calculates reputation bonus multiplier based on participant's reputation score
;; @param reputation: current reputation score of participant
;; @returns: uint multiplier (100 = 1x, 150 = 1.5x, etc.)
(define-private (calculate-reputation-multiplier (reputation uint))
    (if (>= reputation u100)
        u150 ;; 1.5x for high reputation
        (if (>= reputation u50)
            u125 ;; 1.25x for medium reputation
            u100 ;; 1x for low/new reputation
        )
    )
)

;; Validates the format and size of model update hash
;; @param update-hash: the hash string to validate
;; @returns: bool indicating if hash is valid
(define-private (is-valid-update-hash (update-hash (string-ascii 64)))
    (and
        (> (len update-hash) u0)
        (<= (len update-hash) u64)
    )
)

;; Updates participant reputation based on contribution quality
;; @param participant: principal address of participant
;; @param increment: amount to increase reputation by
;; @returns: bool indicating success
(define-private (update-reputation (participant principal) (increment uint))
    (match (map-get? participants participant)
        participant-data
        (begin
            (map-set participants
                participant
                (merge participant-data {
                    reputation-score: (+ (get reputation-score participant-data) increment),
                    total-contributions: (+ (get total-contributions participant-data) u1)
                })
            )
            true
        )
        false
    )
)

;; public functions

;; Allows a participant to register for federated learning with a stake
;; @param stake-amount: amount of micro-STX to stake (must be >= MIN-STAKE-AMOUNT)
;; @returns: response with success or error code
(define-public (register-participant (stake-amount uint))
    (let
        (
            (participant tx-sender)
            (existing-participant (map-get? participants participant))
        )
        ;; Validate registration conditions
        (asserts! (is-none existing-participant) ERR-ALREADY-REGISTERED)
        (asserts! (>= stake-amount MIN-STAKE-AMOUNT) ERR-INVALID-STAKE)
        
        ;; Register participant with initial reputation
        (map-set participants
            participant
            {
                stake: stake-amount,
                reputation-score: u10,
                total-contributions: u0,
                is-active: true
            }
        )
        
        ;; Update total participant count
        (var-set total-registered-participants (+ (var-get total-registered-participants) u1))
        
        (ok true)
    )
)

;; Allows contract owner to start a new training round
;; @returns: response with new round number or error code
(define-public (start-training-round)
    (begin
        ;; Only contract owner can start rounds
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        ;; Ensure previous round is not active
        (asserts! (not (var-get round-active)) ERR-ROUND-NOT-ACTIVE)
        
        ;; Check minimum participants requirement
        (asserts! (>= (var-get total-registered-participants) MIN-PARTICIPANTS) ERR-INSUFFICIENT-PARTICIPANTS)
        
        ;; Start new round
        (var-set current-round (+ (var-get current-round) u1))
        (var-set round-active true)
        (var-set round-submissions u0)
        
        (ok (var-get current-round))
    )
)

;; Allows registered participants to submit encrypted model updates
;; @param update-hash: cryptographic hash of the encrypted model update
;; @returns: response with success or error code
(define-public (submit-model-update (update-hash (string-ascii 64)))
    (let
        (
            (participant tx-sender)
            (current-round-number (var-get current-round))
            (update-key {round: current-round-number, participant: participant})
            (existing-update (map-get? model-updates update-key))
        )
        ;; Validate submission conditions
        (asserts! (var-get round-active) ERR-ROUND-NOT-ACTIVE)
        (asserts! (is-valid-participant participant) ERR-NOT-REGISTERED)
        (asserts! (is-none existing-update) ERR-ALREADY-SUBMITTED)
        (asserts! (is-valid-update-hash update-hash) ERR-INVALID-UPDATE)
        
        ;; Store model update
        (map-set model-updates
            update-key
            {
                update-hash: update-hash,
                timestamp: block-height,
                verified: true
            }
        )
        
        ;; Update round submission count
        (var-set round-submissions (+ (var-get round-submissions) u1))
        
        ;; Update participant reputation
        (update-reputation participant u5)
        
        ;; Calculate and add rewards
        (let
            (
                (participant-info (unwrap-panic (map-get? participants participant)))
                (base-reward REWARD-PER-UPDATE)
                (reputation-mult (calculate-reputation-multiplier (get reputation-score participant-info)))
                (final-reward (/ (* base-reward reputation-mult) u100))
                (current-pending (default-to u0 (map-get? pending-rewards participant)))
            )
            (map-set pending-rewards participant (+ current-pending final-reward))
        )
        
        (ok true)
    )
)

;; Aggregates model updates and creates global model for the current round
;; This function simulates federated averaging by collecting all submitted updates
;; @param aggregated-model-hash: hash of the aggregated global model
;; @returns: response with success or error code
(define-public (aggregate-global-model (aggregated-model-hash (string-ascii 64)))
    (let
        (
            (current-round-number (var-get current-round))
            (submission-count (var-get round-submissions))
            (total-stake-amount u0)
        )
        ;; Validate aggregation conditions
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (var-get round-active) ERR-ROUND-NOT-ACTIVE)
        (asserts! (>= submission-count MIN-PARTICIPANTS) ERR-INSUFFICIENT-PARTICIPANTS)
        (asserts! (is-valid-update-hash aggregated-model-hash) ERR-INVALID-UPDATE)
        
        ;; Store aggregated global model
        (map-set global-models
            current-round-number
            {
                model-hash: aggregated-model-hash,
                participant-count: submission-count,
                total-stake: total-stake-amount,
                aggregation-timestamp: block-height
            }
        )
        
        ;; Close the current round
        (var-set round-active false)
        
        (ok true)
    )
)

;; Allows participants to claim their accumulated rewards
;; @returns: response with claimed amount or error code
(define-public (claim-rewards)
    (let
        (
            (participant tx-sender)
            (reward-amount (default-to u0 (map-get? pending-rewards participant)))
        )
        ;; Validate claim conditions
        (asserts! (is-valid-participant participant) ERR-NOT-REGISTERED)
        (asserts! (> reward-amount u0) ERR-NO-REWARDS)
        
        ;; Clear pending rewards
        (map-delete pending-rewards participant)
        
        ;; Transfer rewards (in production, this would use stx-transfer)
        ;; Note: In a real implementation, rewards would come from a treasury
        (ok reward-amount)
    )
)


