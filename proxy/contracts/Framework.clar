;; Proxy Execution Framework Contract
;; Enables fee-free operations through delegation system

(define-constant framework-admin tx-sender)
(define-constant err-admin-only (err u100))
(define-constant err-invalid-proof (err u101))
(define-constant err-invalid-sequence (err u102))
(define-constant err-locked (err u103))
(define-constant err-unauthorized-executor (err u104))

;; Data Variables
(define-data-var framework-locked bool false)
(define-map sequence-numbers principal uint)
(define-map executors principal {score: uint, total-executed: uint})
(define-map operation-pool 
    uint 
    {requester: principal, 
     instruction: (string-ascii 64),
     sequence: uint,
     block-id: uint,
     proof: (buff 65),
     completed: bool})

(define-data-var pool-counter uint u0)

;; Read-only functions
(define-read-only (get-sequence (user principal))
    (default-to u0 (map-get? sequence-numbers user)))

(define-read-only (is-locked)
    (var-get framework-locked))

(define-read-only (get-executor-status (executor principal))
    (map-get? executors executor))

;; Read-only functions for proof verification
(define-read-only (verify-proof (message (buff 32)) (proof (buff 65)) (requester principal))
    (let ((recovered-public-key (unwrap! (secp256k1-recover? message proof) false)))
        (is-eq (unwrap! (principal-of? recovered-public-key) false) requester)))

;; Private functions
(define-private (increment-sequence (user principal))
    (let ((current-sequence (get-sequence user)))
        (map-set sequence-numbers 
            user 
            (+ current-sequence u1))))

(define-private (update-executor-metrics (executor principal))
    (let ((current-metrics (unwrap-panic (get-executor-status executor))))
        (map-set executors
            executor
            {score: (+ (get score current-metrics) u1),
             total-executed: (+ (get total-executed current-metrics) u1)})))

;; Public functions
(define-public (register-executor)
    (begin
        (asserts! (is-eq framework-admin tx-sender) err-admin-only)
        (ok (map-set executors
            tx-sender
            {score: u0,
             total-executed: u0}))))

(define-public (toggle-lock)
    (begin
        (asserts! (is-eq framework-admin tx-sender) err-admin-only)
        (ok (var-set framework-locked (not (var-get framework-locked))))))

(define-public (submit-operation 
    (instruction (string-ascii 64))
    (proof (buff 65)))
    (let
        ((requester tx-sender)
         (current-sequence (get-sequence requester))
         (message-hash (sha256 (concat (unwrap-panic (to-consensus-buff? instruction))
                                     (unwrap-panic (to-consensus-buff? current-sequence))))))
        (asserts! (not (var-get framework-locked)) err-locked)
        (asserts! (verify-proof message-hash proof requester) err-invalid-proof)
        (map-set operation-pool
            (var-get pool-counter)
            {requester: requester,
             instruction: instruction,
             sequence: current-sequence,
             block-id: block-height,
             proof: proof,
             completed: false})
        (var-set pool-counter (+ (var-get pool-counter) u1))
        (ok true)))

(define-public (execute-operation (pool-id uint))
    (let ((op (unwrap-panic (map-get? operation-pool pool-id)))
          (executor tx-sender))
        (asserts! (not (var-get framework-locked)) err-locked)
        (asserts! (is-some (get-executor-status executor)) err-unauthorized-executor)
        (asserts! (not (get completed op)) err-invalid-sequence)
        
        ;; Process the operation
        (map-set operation-pool
            pool-id
            (merge op {completed: true}))
        
        ;; Update sequence and executor stats
        (increment-sequence (get requester op))
        (update-executor-metrics executor)
        (ok true)))

;; Initialize contract
(begin
    ;; Register contract admin as first executor
    (try! (register-executor))
    ;; Contract successfully initialized
    (ok true))