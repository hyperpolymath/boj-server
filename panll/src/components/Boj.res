// SPDX-License-Identifier: PMPL-1.0-or-later

/// PanLL BoJ Component - The "Maître D'" interface for the BoJ Server.

open Model
open Msg
open Tea.Html
open BojModel

let renderStatusIndicator = (status: cartridgeStatus) => {
  let colour = BojEngine.statusColour(status)
  let label = BojEngine.statusLabel(status)
  span(
    list{Attrs.class_(`text-[10px] uppercase tracking-widest font-bold ${colour}`)},
    list{text(label)},
  )
}

let renderCartridgeCard = (cart: cartridge, isSelected: bool) => {
  let borderClass = isSelected ? "border-indigo-500 bg-indigo-950/20" : "border-gray-800 bg-gray-900/40"
  
  div(
    list{
      Attrs.class_(`p-4 border rounded-lg transition-all cursor-pointer hover:border-gray-600 ${borderClass}`),
      Events.onClick(Boj(ToggleCartridge(cart.name))),
    },
    list{
      div(
        list{Attrs.class_("flex justify-between items-start mb-2")},
        list{
          div(
            list{},
            list{
              h3(list{Attrs.class_("font-medium text-gray-200")}, list{text(cart.name)}),
              span(list{Attrs.class_("text-xs text-gray-500")}, list{text(cart.version)}),
            },
          ),
          renderStatusIndicator(cart.status),
        },
      ),
      div(
        list{Attrs.class_("flex gap-2 mt-3")},
        cart.interfaces->Array.map(i => 
          span(
            list{Attrs.class_("px-1.5 py-0.5 bg-gray-800 text-gray-400 text-[10px] rounded")}, 
            list{text(BojEngine.interfaceLabel(i))}
          )
        )->List.fromArray,
      ),
    },
  )
}

let renderMenu = (state: bojState) => {
  div(
    list{Attrs.class_("grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4")},
    state.cartridges->Array.map(c => 
      renderCartridgeCard(c, state.selectedCartridges->Array.includes(c.name))
    )->List.fromArray,
  )
}

let view = (state: bojState) => {
  div(
    list{Attrs.class_("flex-1 flex flex-col p-6 overflow-y-auto")},
    list{
      div(
        list{Attrs.class_("mb-8")},
        list{
          h1(list{Attrs.class_("text-3xl font-light text-gray-100 mb-2")}, list{text("The BoJ Menu")}),
          p(list{Attrs.class_("text-gray-500")}, list{text("Select your polystack cartridges for today's session.")}),
        },
      ),
      switch state.activeCategory {
      | Menu => renderMenu(state)
      | _ => div(list{}, list{text("Section under construction")})
      },
      div(
        list{Attrs.class_("mt-auto pt-8 flex justify-end")},
        list{
          button(
            list{
              Attrs.class_("px-6 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded font-medium transition-all"),
              Events.onClick(Boj(PlaceOrder)),
            },
            list{text("Place Order (Generate Ticket)")},
          ),
        },
      ),
    },
  )
}
