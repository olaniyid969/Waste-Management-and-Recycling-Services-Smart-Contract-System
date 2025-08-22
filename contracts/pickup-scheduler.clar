;; Pickup Scheduler Contract
;; Manages pickup scheduling and route optimization

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-INVALID-DATE (err u401))
(define-constant ERR-SCHEDULE-NOT-FOUND (err u402))
(define-constant ERR-INVALID-STATUS (err u403))
(define-constant ERR-PICKUP-CONFLICT (err u404))

;; Data Variables
(define-data-var next-pickup-id uint u1)
(define-data-var scheduling-window uint u14) ;; 14 days advance scheduling

;; Data Maps
(define-map pickup-schedules
  { pickup-id: uint }
  {
    service-id: uint,
    customer: principal,
    scheduled-date: uint,
    pickup-type: (string-ascii 20),
    waste-categories: (list 5 (string-ascii 20)),
    status: (string-ascii 20),
    route-id: uint,
    driver-assigned: (optional principal),
    created-at: uint,
    updated-at: uint
  }
)

(define-map service-schedules
  { service-id: uint }
  {
    regular-days: (list 7 uint), ;; Days of week (0-6)
    frequency: (string-ascii 20), ;; weekly, bi-weekly, monthly
    next-pickup: uint,
    last-pickup: uint,
    active: bool
  }
)

(define-map route-optimization
  { route-id: uint, date: uint }
  {
    pickup-ids: (list 50 uint),
    estimated-duration: uint,
    total-stops: uint,
    driver: (optional principal),
    status: (string-ascii 20),
    created-at: uint
  }
)

(define-map special-requests
  { pickup-id: uint }
  {
    request-type: (string-ascii 30),
    description: (string-ascii 200),
    additional-fee: uint,
    approved: bool,
    processed-by: (optional principal)
  }
)

(define-map holiday-adjustments
  { date: uint }
  {
    is-holiday: bool,
    adjustment-days: uint,
    description: (string-ascii 100),
    affects-routes: bool
  }
)

;; Private Functions
(define-private (is-valid-pickup-status (status (string-ascii 20)))
  (or
    (is-eq status "scheduled")
    (or
      (is-eq status "in-progress")
      (or
        (is-eq status "completed")
        (or
          (is-eq status "missed")
          (is-eq status "cancelled")
        )
      )
    )
  )
)

(define-private (is-valid-frequency (frequency (string-ascii 20)))
  (or
    (is-eq frequency "weekly")
    (or
      (is-eq frequency "bi-weekly")
      (is-eq frequency "monthly")
    )
  )
)

(define-private (calculate-next-pickup (last-pickup uint) (frequency (string-ascii 20)))
  (if (is-eq frequency "weekly")
    (+ last-pickup u7)
    (if (is-eq frequency "bi-weekly")
      (+ last-pickup u14)
      (+ last-pickup u30) ;; monthly
    )
  )
)

;; Public Functions
(define-public (setup-regular-schedule
  (service-id uint)
  (regular-days (list 7 uint))
  (frequency (string-ascii 20))
)
  (begin
    (asserts! (is-valid-frequency frequency) ERR-INVALID-STATUS)

    (map-set service-schedules
      { service-id: service-id }
      {
        regular-days: regular-days,
        frequency: frequency,
        next-pickup: (+ block-height u7), ;; Next week
        last-pickup: u0,
        active: true
      }
    )
    (ok true)
  )
)

(define-public (schedule-pickup
  (service-id uint)
  (scheduled-date uint)
  (waste-categories (list 5 (string-ascii 20)))
)
  (let
    (
      (pickup-id (var-get next-pickup-id))
      (current-time block-height)
    )
    (asserts! (> scheduled-date current-time) ERR-INVALID-DATE)
    (asserts! (<= scheduled-date (+ current-time (var-get scheduling-window))) ERR-INVALID-DATE)

    (map-set pickup-schedules
      { pickup-id: pickup-id }
      {
        service-id: service-id,
        customer: tx-sender,
        scheduled-date: scheduled-date,
        pickup-type: "regular",
        waste-categories: waste-categories,
        status: "scheduled",
        route-id: u0,
        driver-assigned: none,
        created-at: current-time,
        updated-at: current-time
      }
    )

    (var-set next-pickup-id (+ pickup-id u1))
    (ok pickup-id)
  )
)

(define-public (schedule-special-pickup
  (service-id uint)
  (scheduled-date uint)
  (pickup-type (string-ascii 20))
  (waste-categories (list 5 (string-ascii 20)))
  (request-description (string-ascii 200))
)
  (let
    (
      (pickup-id (var-get next-pickup-id))
      (current-time block-height)
    )
    (asserts! (> scheduled-date current-time) ERR-INVALID-DATE)

    (map-set pickup-schedules
      { pickup-id: pickup-id }
      {
        service-id: service-id,
        customer: tx-sender,
        scheduled-date: scheduled-date,
        pickup-type: pickup-type,
        waste-categories: waste-categories,
        status: "scheduled",
        route-id: u0,
        driver-assigned: none,
        created-at: current-time,
        updated-at: current-time
      }
    )

    (map-set special-requests
      { pickup-id: pickup-id }
      {
        request-type: pickup-type,
        description: request-description,
        additional-fee: u0,
        approved: false,
        processed-by: none
      }
    )

    (var-set next-pickup-id (+ pickup-id u1))
    (ok pickup-id)
  )
)

(define-public (update-pickup-status
  (pickup-id uint)
  (new-status (string-ascii 20))
)
  (let
    (
      (pickup (unwrap! (map-get? pickup-schedules { pickup-id: pickup-id })
                       ERR-SCHEDULE-NOT-FOUND))
    )
    (asserts! (is-valid-pickup-status new-status) ERR-INVALID-STATUS)

    (map-set pickup-schedules
      { pickup-id: pickup-id }
      (merge pickup {
        status: new-status,
        updated-at: block-height
      })
    )

    ;; Update service schedule if completed
    (if (is-eq new-status "completed")
      (let
        (
          (service-schedule (map-get? service-schedules { service-id: (get service-id pickup) }))
        )
        (match service-schedule
          schedule (map-set service-schedules
                     { service-id: (get service-id pickup) }
                     (merge schedule {
                       last-pickup: block-height,
                       next-pickup: (calculate-next-pickup block-height (get frequency schedule))
                     }))
          true
        )
      )
      true
    )
    (ok true)
  )
)

(define-public (assign-to-route
  (pickup-id uint)
  (route-id uint)
  (driver principal)
)
  (let
    (
      (pickup (unwrap! (map-get? pickup-schedules { pickup-id: pickup-id })
                       ERR-SCHEDULE-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)

    (map-set pickup-schedules
      { pickup-id: pickup-id }
      (merge pickup {
        route-id: route-id,
        driver-assigned: (some driver),
        updated-at: block-height
      })
    )
    (ok true)
  )
)

(define-public (set-holiday-adjustment
  (date uint)
  (adjustment-days uint)
  (description (string-ascii 100))
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)

    (map-set holiday-adjustments
      { date: date }
      {
        is-holiday: true,
        adjustment-days: adjustment-days,
        description: description,
        affects-routes: true
      }
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-pickup-schedule (pickup-id uint))
  (map-get? pickup-schedules { pickup-id: pickup-id })
)

(define-read-only (get-service-schedule (service-id uint))
  (map-get? service-schedules { service-id: service-id })
)

(define-read-only (get-route-optimization (route-id uint) (date uint))
  (map-get? route-optimization { route-id: route-id, date: date })
)

(define-read-only (get-special-request (pickup-id uint))
  (map-get? special-requests { pickup-id: pickup-id })
)

(define-read-only (get-holiday-adjustment (date uint))
  (map-get? holiday-adjustments { date: date })
)

(define-read-only (get-next-pickup-id)
  (var-get next-pickup-id)
)
