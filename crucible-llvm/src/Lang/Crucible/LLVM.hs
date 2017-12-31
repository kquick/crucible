{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE LambdaCase #-}
-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.LLVM
-- Description      : LLVM interface for Crucible
-- Copyright        : (c) Galois, Inc 2015-2016
-- License          : BSD3
-- Maintainer       : rdockins@galois.com
-- Stability        : provisional
------------------------------------------------------------------------
module Lang.Crucible.LLVM
( registerModuleFn
, llvmGlobals
, register_llvm_overrides
, llvmExtensionImpl
)
where

import           Control.Lens
import qualified Text.LLVM.AST as L

import           Lang.Crucible.Analysis.Postdom
import           Lang.Crucible.CFG.Core
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.LLVM.Intrinsics
import           Lang.Crucible.LLVM.MemModel
import           Lang.Crucible.Simulator.ExecutionTree
import           Lang.Crucible.Simulator.GlobalState
import           Lang.Crucible.Simulator.OverrideSim


registerModuleFn
   :: (L.Symbol, AnyCFG LLVM)
   -> OverrideSim p sym LLVM rtp l a ()
registerModuleFn (_,AnyCFG cfg) = do
  let h = cfgHandle cfg
      s = UseCFG cfg (postdomInfo cfg)
  stateContext . functionBindings %= insertHandleMap h s


llvmGlobals
   :: LLVMContext wptr
   -> MemImpl sym
   -> SymGlobalState sym
llvmGlobals ctx mem = emptyGlobals & insertGlobal var mem
  where var = llvmMemVar $ memModelOps ctx

llvmExtensionImpl :: ExtensionImpl p sym LLVM
llvmExtensionImpl =
  ExtensionImpl
  { extensionEval = \_ -> \case
  , extensionExec = \_ -> \case
  }