// SPDX-License-Identifier: MPL-2.0

/// PanLL BoJ Module - capability registration.

open BojModel

type bojCapability =
  | ViewMenu
  | CreateOrder
  | ManageConsole
  | FederatedLink

type bojModuleConfig = {
  id: string,
  name: string,
  version: string,
  description: string,
  capabilities: array<bojCapability>,
  icon: option<string>,
}

let config: bojModuleConfig = {
  id: "bojServer",
  name: "BoJ Console",
  version: "1.0.0",
  description: "Unified AI-driven server management for polystacks",
  capabilities: [ViewMenu, CreateOrder, ManageConsole, FederatedLink],
  icon: Some("terminal"),
}
