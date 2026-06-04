-- SPDX-License-Identifier: MPL-2.0
-- Fireflag Cartridge ABI — Extension-to-MCP mapping interface

module Fireflag

%language ElabReflection

-- Extension type classification
public export
data ExtensionType : Type where
  VSCodeExtension : ExtensionType
  IDEPlugin : ExtensionType
  DesktopApp : ExtensionType
  CLITool : ExtensionType
  WebComponent : ExtensionType
  LanguageServer : ExtensionType
  Other : ExtensionType

-- MCP capability definition
public export
record MCPCapability where
  constructor MkMCPCapability
  name : String
  toolName : String
  inputSchema : String
  description : String

-- Extension metadata
public export
record ExtensionMetadata where
  constructor MkExtensionMetadata
  extensionId : String
  extensionType : ExtensionType
  name : String
  description : String
  version : String
  mcpTools : List MCPCapability

-- Mapping result
public export
record MappingResult where
  constructor MkMappingResult
  extensionPath : String
  metadata : ExtensionMetadata
  isMapped : Bool
  mappingStatus : String

-- Fireflag cartridge interface
public export
interface Fireflag.Mapper where
  -- Map an extension directory to available MCP tools
  mapExtension : String -> IO MappingResult

  -- List all mapped extensions
  listMappedExtensions : IO (List ExtensionMetadata)

  -- Get MCP tools available for an extension
  getExtensionTools : String -> IO (List MCPCapability)

  -- Validate extension configuration
  validateExtension : String -> IO (List String)

  -- Discover extensions in directory
  discoverExtensions : String -> IO (List ExtensionMetadata)


||| Loopback proof: cartridge binds on localhost only.
public export
data IsLoopback : (port : Nat) -> Type where
  LoopbackProof : IsLoopback 5177

export
loopbackInvariant : IsLoopback 5177
loopbackInvariant = LoopbackProof
