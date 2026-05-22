-- SPDX-License-Identifier: MPL-2.0
-- Academic Workflow Cartridge ABI — Citations, Zotero, paper review

module AcademicWorkflow

||| Paper metadata
public record Paper where
  constructor MkPaper
  title : String
  authors : List String
  doi : String
  year : Nat
  abstract : String

||| Citation format
public data CitationFormat =
  | BibTeX
  | CSL
  | RIS
  | EndNote

||| Proof that a citation format is supported
public data Supported : CitationFormat -> Type where
  SupportedBibTeX : Supported BibTeX
  SupportedCSL : Supported CSL
  SupportedRIS : Supported RIS
  SupportedEndNote : Supported EndNote

||| Review annotation
public record ReviewNote where
  constructor MkReviewNote
  page : Nat
  text : String
  category : String  -- "typo", "unclear", "question", "suggestion"

||| Zotero collection reference
public record ZoteroCollection where
  constructor MkZoteroCollection
  id : String
  name : String
  itemCount : Nat

||| Academic workflow operations
public interface AcademicWorkflow.Workflow (m : Type -> Type) where
  ||| Search Zotero collections
  searchZotero : (query : String) -> m (List ZoteroCollection)

  ||| Fetch paper metadata from Zotero
  getPaperMetadata : (itemId : String) -> m Paper

  ||| Generate citation in requested format
  generateCitation : {fmt : CitationFormat} ->
                     (paper : Paper) ->
                     Supported fmt -> m String

  ||| Extract BibTeX keys from text
  extractBibKeys : (text : String) -> m (List String)

  ||| Add review annotations to paper
  addReviewNote : (paperId : String) -> (note : ReviewNote) -> m ()

  ||| Export collection as BibTeX
  exportCollection : (collectionId : String) -> m String

||| Loopback proof: academic-mcp runs on 127.0.0.1:5174
public data IsLoopback : (port : Nat) -> Type where
  LoopbackProof : IsLoopback 5174

export
loopbackInvariant : IsLoopback 5174
loopbackInvariant = LoopbackProof
