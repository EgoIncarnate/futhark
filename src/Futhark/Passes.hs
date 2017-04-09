{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Optimisation pipelines.
module Futhark.Passes
  ( standardPipeline
  , sequentialPipeline
  , sequentialPipelineWithMemoryBlockMerging
  , gpuPipeline
  , gpuPipelineWithMemoryBlockMerging
  , defaultToMemoryBlockMerging
  , CompilationMode (..)
  )
where

import Control.Category ((>>>), id)
import Control.Monad.Except
import Data.Maybe

import Prelude hiding (id)

import Futhark.Optimise.CSE
import Futhark.Optimise.Fusion
import Futhark.Optimise.InPlaceLowering
import Futhark.Optimise.InliningDeadFun
import Futhark.Optimise.TileLoops
import Futhark.Optimise.DoubleBuffer
import Futhark.Optimise.Unstream
import Futhark.Pass.MemoryBlockMerging
import Futhark.Pass.ExpandAllocations
import Futhark.Pass.ExplicitAllocations
import Futhark.Pass.ExtractKernels
import Futhark.Pass.FirstOrderTransform
import Futhark.Pass.KernelBabysitting
import Futhark.Pass.Simplify
import Futhark.Pass
import Futhark.Pipeline
import Futhark.Representation.ExplicitMemory (ExplicitMemory)
import Futhark.Representation.SOACS (SOACS)
import Futhark.Representation.AST.Syntax

-- | Are we compiling the Futhark program as an executable or a
-- library?  This affects which functions are considered as roots for
-- dead code elimination and ultimately exist in generated code.
data CompilationMode = Executable
                     -- ^ Only the top-level function named @main@ is
                       -- alive.
                     | Library
                       -- ^ Only top-level functions marked @entry@
                       -- are alive.

standardPipeline :: CompilationMode -> Pipeline SOACS SOACS
standardPipeline mode =
  checkForEntryPoints mode >>>
  passes [ simplifySOACS
         , inlineAndRemoveDeadFunctions
         , performCSE True
         , simplifySOACS
           -- We run fusion twice
         , fuseSOACs
         , performCSE True
         , simplifySOACS
         , fuseSOACs
         , performCSE True
         , simplifySOACS
         , removeDeadFunctions
         ]
  where checkForEntryPoints :: CompilationMode -> Pipeline SOACS SOACS
        checkForEntryPoints Library = id
        checkForEntryPoints Executable =
          onePass Pass { passName = "Check for main function"
                       , passDescription = "Check if an entry point exists"
                       , passFunction = \prog -> do checkForMain $ progFunctions prog
                                                    return prog
                       }

        checkForMain ps
          | not $ any (isJust . funDefEntryPoint) ps =
              throwError "No entry points defined."
          | otherwise =
              return ()

sequentialPipeline :: CompilationMode -> Pipeline SOACS ExplicitMemory
sequentialPipeline mode =
  standardPipeline mode >>>
  onePass firstOrderTransform >>>
  passes [ simplifyKernels
         , inPlaceLowering
         ] >>>
  onePass explicitAllocations >>>
  passes [ simplifyExplicitMemory
         , performCSE False
         , simplifyExplicitMemory
         , doubleBuffer
         , simplifyExplicitMemory
         ]

sequentialPipelineWithMemoryBlockMerging :: CompilationMode -> Pipeline SOACS ExplicitMemory
sequentialPipelineWithMemoryBlockMerging mode =
  sequentialPipeline mode >>>
  passes [ mergeMemoryBlocks
         , simplifyExplicitMemory
         ]

gpuPipeline :: CompilationMode -> Pipeline SOACS ExplicitMemory
gpuPipeline mode =
  standardPipeline mode >>>
  onePass extractKernels >>>
  passes [ simplifyKernels
         , babysitKernels
         , simplifyKernels
         , tileLoops
         , unstream
         , simplifyKernels
         , performCSE True
         , simplifyKernels
         , inPlaceLowering
         ] >>>
  onePass explicitAllocations >>>
  passes [ simplifyExplicitMemory
         , performCSE False
         , simplifyExplicitMemory
         , doubleBuffer
         , simplifyExplicitMemory
         , expandAllocations
         , simplifyExplicitMemory
         ]

gpuPipelineWithMemoryBlockMerging :: CompilationMode -> Pipeline SOACS ExplicitMemory
gpuPipelineWithMemoryBlockMerging mode =
  gpuPipeline mode >>>
  passes [ mergeMemoryBlocks
         , simplifyExplicitMemory
         ]

-- | Flag to determine whether futhark-c and futhark-opencl should default to
-- doing memory block merging.  Useful when using futhark-test and
-- futhark-bench.
defaultToMemoryBlockMerging :: Bool
defaultToMemoryBlockMerging = False
