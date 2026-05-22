// SPDX-License-Identifier: MPL-2.0

/// PanLL BoJ Engine - pure computation for the BoJ Server Console.

open BojModel

let categoryLabel = (cat: bojCategory): string => {
  switch cat {
  | Menu => "Today's Menu"
  | ActiveOrder => "Active Order"
  | Settings => "Console Settings"
  }
}

let allCategories: array<bojCategory> = [Menu, ActiveOrder, Settings]

let statusLabel = (status: cartridgeStatus): string => {
  switch status {
  | Ready => "Ready"
  | HighTraffic => "High Traffic"
  | Faulty => "Faulty"
  | Development => "Development"
  }
}

let statusColour = (status: cartridgeStatus): string => {
  switch status {
  | Ready => "text-green-400"
  | HighTraffic => "text-amber-400"
  | Faulty => "text-red-400"
  | Development => "text-gray-500"
  }
}

let interfaceLabel = (i: interfaceType): string => {
  switch i {
  | MCP => "MCP"
  | LSP => "LSP"
  | GRPC => "gRPC"
  | REST => "REST"
  }
}
