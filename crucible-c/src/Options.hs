module Options where

data Options = Options
  { clangBin :: FilePath
    -- ^ Path to Clang binary

  , libDir   :: FilePath
    -- ^ Path to our C file

  , outDir   :: FilePath
    -- ^ Store results in this directory

  , optsBCFile :: FilePath
    -- ^ Use this bit-code file.

  , inputFile :: FilePath
    -- ^ The file to analyze

  , checkPathSat :: Bool
    -- ^ Should we enable path satisfiability checking?
  }

