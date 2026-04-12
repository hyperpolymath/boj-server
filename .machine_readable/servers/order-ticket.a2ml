; SPDX-License-Identifier: PMPL-1.0-or-later
; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;
; Order Ticket Protocol Specification
;
; The order-ticket protocol defines how AI agents request specific
; cartridges to be mounted for a session. The flow is:
;
;   1. AI reads the Teranga menu (menu.a2ml)
;   2. AI writes an order ticket (this format)
;   3. BoJ validates the order against the catalogue
;   4. BoJ mounts requested cartridges via Zig FFI
;   5. V-lang adapter exposes mounted cartridges as REST+gRPC+GraphQL
;   6. AI receives confirmation with endpoints
;
; The metaphor: AI is the Maitre D', presenting the menu to the user,
; taking their order, and having the kitchen (Idris2+Zig) prepare it.

(order-ticket-spec
  (version "1.0.0")
  (last-updated "2026-03-02")

  ; --- Order Format ---
  ;
  ; An order ticket is a structured request. Example:
  ;
  ; (order
  ;   (timestamp 1740916800)
  ;   (requested-by "claude-code-v4.6")
  ;   (session-id "abc123")
  ;   (cartridges
  ;     ("database-mcp" (protocols (MCP LSP)))
  ;     ("nesy-mcp" (protocols (MCP NeSy)))
  ;     ("fleet-mcp" (protocols (MCP Fleet))))
  ;   (preferred-node "node-eu-west-01")  ; optional
  ;   (fallback local)                    ; local | any | none
  ; )

  (fields
    (required
      (timestamp     "Unix timestamp of order creation")
      (requested-by  "Identifier of the AI agent placing the order")
      (session-id    "Unique session identifier for tracking")
      (cartridges    "List of (cartridge-name (protocols ...)) pairs"))
    (optional
      (preferred-node "Node ID from the Umoja network to route to")
      (fallback       "What to do if preferred node unavailable: local | any | none")))

  ; --- Validation Rules ---
  ;
  ; The BoJ server validates orders before mounting:
  ; 1. Each requested cartridge must exist in the catalogue
  ; 2. Each cartridge must have status = Ready (IsUnbreakable proof)
  ; 3. Requested protocols must be supported by the cartridge
  ; 4. If preferred-node is set, node must be attested (hash match)
  ; 5. Maximum 16 cartridges per order (to prevent abuse)

  (validation-rules
    (max-cartridges 16)
    (require-ready #t)
    (require-attested-node #t)
    (allow-local-fallback #t))

  ; --- Response Format ---
  ;
  ; After validation, BoJ returns a confirmation:
  ;
  ; (order-confirmation
  ;   (order-id "order-abc123")
  ;   (status accepted)  ; accepted | partial | rejected
  ;   (mounted
  ;     ("database-mcp" (endpoints
  ;       (mcp "stdio://boj/database-mcp")
  ;       (lsp "tcp://[::1]:9010")))
  ;     ("nesy-mcp" (endpoints
  ;       (mcp "stdio://boj/nesy-mcp")
  ;       (nesy "tcp://[::1]:9011")
  ;       (grpc "tcp://[::1]:9012"))))
  ;   (rejected
  ;     ("fleet-mcp" (reason "status = Development, not Ready")))
  ;   (node "node-eu-west-01")
  ;   (expires 1740920400))

  (response-fields
    (order-id    "Unique identifier for tracking")
    (status      "accepted (all mounted) | partial (some mounted) | rejected (none)")
    (mounted     "List of cartridges successfully mounted with their endpoints")
    (rejected    "List of cartridges that could not be mounted with reasons")
    (node        "Which Umoja node is serving this order")
    (expires     "Unix timestamp when the session expires"))

  ; --- Security ---
  ;
  ; Orders are validated cryptographically:
  ; - Agent identity verified (if the agent provides a signed token)
  ; - Order hash recorded in the audit log
  ; - Mounted cartridges are sandboxed (each gets its own address space)
  ; - Sessions expire after 1 hour by default (configurable)
  ;
  ; Community nodes additionally verify:
  ; - Binary hash matches canonical build (Attested proof in Federation.idr)
  ; - Cartridge hashes match the menu attestation
  ; - PMPL provenance chain is intact

  (security
    (session-timeout-seconds 3600)
    (sandbox-cartridges #t)
    (require-agent-identity #f)    ; optional but recommended
    (audit-log #t)
    (pmpl-provenance #t))
)
