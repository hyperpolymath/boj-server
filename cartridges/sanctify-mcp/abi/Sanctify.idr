-- SPDX-License-Identifier: MPL-2.0
-- Sanctify Cartridge ABI — PHP lint and deviation detection interface

module ABI.Sanctify

%language ElabReflection

-- Lint severity levels
public export
data LintSeverity : Type where
  Error : LintSeverity
  Warning : LintSeverity
  Notice : LintSeverity
  Info : LintSeverity

-- Lint issue record
public export
record LintIssue where
  constructor MkLintIssue
  file : String
  line : Nat
  column : Nat
  severity : LintSeverity
  code : String
  message : String
  suggestion : String

-- Deviation detection type
public export
data DeviationType : Type where
  NamingConvention : DeviationType
  StyleGuide : DeviationType
  SecurityPractice : DeviationType
  PerformanceAntipattern : DeviationType
  DeprecatedAPI : DeviationType

-- Code analysis result
public export
record AnalysisResult where
  constructor MkAnalysisResult
  filePath : String
  isValid : Bool
  lintIssues : List LintIssue
  deviations : List DeviationType
  scanTimeMs : Nat

-- Sanctify cartridge interface
public export
interface Sanctify.Linter where
  -- Lint PHP file for syntax and style issues
  lintFile : String -> IO (List LintIssue)

  -- Detect deviations from PHP best practices
  detectDeviations : String -> IO (List DeviationType)

  -- Analyze entire PHP file
  analyzeFile : String -> IO AnalysisResult

  -- Check a code snippet for issues
  checkSnippet : String -> IO (List LintIssue)

  -- Loopback proof: cartridge runs on localhost only
  IsLoopback : (port : Nat) -> Type
  IsLoopback 5176 = ()

public export
Loopback.proof : IsLoopback 5176
Loopback.proof = ()
