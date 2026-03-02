-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Boj.Menu: Menu generation from catalogue state.
|||
||| The Teranga Menu is the public face of the BoJ server.
||| AI agents (the "Maitre D'") present this menu to users,
||| showing what cartridges are available, their status,
||| and which protocols they support.
|||
||| The menu has three tiers:
|||   - Teranga (Core): Maintained by the project
|||   - Shield: Privacy and security cartridges
|||   - Ayo (Joy): Community-contributed cartridges
|||
||| The order-ticket protocol lets AI agents request specific
||| cartridges to be mounted for a session.
module Boj.Menu

import Data.List
import Boj.Protocol
import Boj.Domain
import Boj.Catalogue
import Boj.Federation

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Menu Entry (what the AI sees)
-- ═══════════════════════════════════════════════════════════════════════════

||| A single entry in the Teranga menu.
||| This is the presentation layer — what the Maitre D' shows to guests.
public export
record MenuEntry where
  constructor MkMenuEntry
  cartridgeName : String
  cartridgeVersion : String
  tier : MenuTier
  domainLabel : String
  supportedProtocols : List String
  statusLabel : String
  isAvailable : Bool

||| Convert a cartridge status to a human-readable label.
public export
statusLabel : CartridgeStatus -> String
statusLabel Development = "In Development"
statusLabel Ready       = "Available"
statusLabel Deprecated  = "Deprecated"
statusLabel Faulty      = "Unavailable"

||| Convert a cartridge to a menu entry for display.
public export
toMenuEntry : Cartridge -> MenuEntry
toMenuEntry c = MkMenuEntry
  (name c)
  (version c)
  (tier c)
  (domainLabel (domain c))
  (map protocolLabel (protocols c))
  (statusLabel (status c))
  (status c == Ready)

||| Generate the full menu from a catalogue.
public export
generateMenu : List Cartridge -> List MenuEntry
generateMenu = map toMenuEntry

-- ═══════════════════════════════════════════════════════════════════════════
-- Order Ticket
-- ═══════════════════════════════════════════════════════════════════════════

||| An order ticket is a request from an AI agent to mount specific
||| cartridges for a session. The Maitre D' reads the menu, the
||| agent writes an order, and BoJ mounts the selected cartridges.
public export
record OrderTicket where
  constructor MkOrder
  timestamp    : Int
  requestedBy  : String       -- Agent identifier
  cartridges   : List String  -- Names of requested cartridges
  protocols    : List ProtocolType  -- Desired protocol types
  preferredNode : Maybe String -- Preferred Umoja node (or Nothing for local)

||| Validate an order ticket against the catalogue.
||| Returns the list of cartridges that can actually be mounted.
public export
validateOrder : OrderTicket -> List Cartridge -> List Cartridge
validateOrder order catalogue =
  let ready = getReadyCartridges catalogue
      requested = cartridges order
  in filter (\c => elem (name c) requested) ready

||| Check if an order can be fully satisfied.
public export
isFullySatisfied : OrderTicket -> List Cartridge -> Bool
isFullySatisfied order catalogue =
  let validated = validateOrder order catalogue
  in length validated == length (cartridges order)

-- ═══════════════════════════════════════════════════════════════════════════
-- Menu Statistics (for the matrix display)
-- ═══════════════════════════════════════════════════════════════════════════

||| Count cartridges per tier.
public export
countByTier : MenuTier -> List Cartridge -> Nat
countByTier t = length . byTier t

||| Summary of the catalogue state for display.
public export
record CatalogueSummary where
  constructor MkSummary
  totalCartridges : Nat
  readyCartridges : Nat
  terangaCount    : Nat
  shieldCount     : Nat
  ayoCount        : Nat
  totalMatrixCells : Nat

||| Generate a summary from a catalogue.
public export
summarise : List Cartridge -> CatalogueSummary
summarise cs = MkSummary
  (length cs)
  (countReady cs)
  (countByTier Teranga cs)
  (countByTier Shield cs)
  (countByTier Ayo cs)
  (totalCells cs)
