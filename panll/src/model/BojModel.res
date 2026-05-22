// SPDX-License-Identifier: MPL-2.0

/// PanLL BoJ Model - state types for the BoJ Server Console panel.
///
/// This model represents the "Daily Menu" and "Order Ticket" for the
/// Bundle of Joy (BoJ) unified server.

type cartridgeStatus = 
  | Ready 
  | HighTraffic 
  | Faulty 
  | Development

type interfaceType = 
  | MCP 
  | LSP 
  | GRPC 
  | REST

type cartridge = {
  name: string,
  version: string,
  status: cartridgeStatus,
  interfaces: array<interfaceType>,
}

type bojCategory =
  | Menu
  | ActiveOrder
  | Settings

type bojState = {
  loaded: bool,
  loading: bool,
  error: option<string>,
  activeCategory: bojCategory,
  cartridges: array<cartridge>,
  selectedCartridges: array<string>,
  lastOrderTimestamp: option<string>,
}
