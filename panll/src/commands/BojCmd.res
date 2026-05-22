// SPDX-License-Identifier: MPL-2.0

/// PanLL BoJ Commands - TEA message types for the BoJ Server Console.
///
/// Defines the update cycle for the BoJ panel: each `bojMsg` variant
/// triggers a pure state transition via `update`, keeping all side
/// effects at the boundary.  `initialState` is the cold-start default
/// before any cartridge data has been fetched.

open BojModel

type bojMsg =
  | ToggleCartridge(string)
  | PlaceOrder
  | SelectCategory(bojCategory)
  | LoadCartridges
  | CartridgesLoaded(array<cartridge>)
  | LoadError(string)
  | ClearSelection
  | RefreshMenu

let update = (state: bojState, msg: bojMsg): bojState => {
  switch msg {
  | ToggleCartridge(name) => {
      let isSelected = state.selectedCartridges->Array.includes(name)
      let newSelected = isSelected
        ? state.selectedCartridges->Array.filter(n => n != name)
        : state.selectedCartridges->Array.concat([name])
      {...state, selectedCartridges: newSelected}
    }
  | SelectCategory(cat) => {...state, activeCategory: cat}
  | LoadCartridges => {...state, loading: true, error: None}
  | CartridgesLoaded(carts) => {...state, cartridges: carts, loading: false, loaded: true}
  | LoadError(err) => {...state, error: Some(err), loading: false}
  | PlaceOrder => {...state, lastOrderTimestamp: Some("pending")}
  | ClearSelection => {...state, selectedCartridges: []}
  | RefreshMenu => {...state, loading: true}
  }
}

let initialState: bojState = {
  loaded: false,
  loading: false,
  error: None,
  activeCategory: Menu,
  cartridges: [],
  selectedCartridges: [],
  lastOrderTimestamp: None,
}
