{-# LANGUAGE TypeFamilies, FlexibleInstances, MultiParamTypeClasses #-}
-- | A simple representation with known shapes, but no other
-- particular information.
module Futhark.Representation.Basic
       ( -- * The Lore definition
         Basic
         -- * Syntax types
       , Prog
       , Body
       , Binding
       , Pattern
       , PrimOp
       , LoopOp
       , Exp
       , Lambda
       , FunDec
         -- * Module re-exports
       , module Futhark.Representation.AST.Attributes
       , module Futhark.Representation.AST.Traversals
       , module Futhark.Representation.AST.Pretty
       , module Futhark.Representation.AST.Syntax
       , AST.LambdaT(Lambda)
       , AST.BodyT(Body)
       , AST.PatternT(Pattern)
       , AST.ProgT(Prog)
       , AST.ExpT(PrimOp)
       , AST.ExpT(LoopOp)
       , AST.FunDecT(FunDec)
         -- Removing lore
       , removeProgLore
       , removeFunDecLore
       , removeBodyLore
       )
where

import qualified Futhark.Representation.AST.Lore as Lore
import qualified Futhark.Representation.AST.Syntax as AST
import Futhark.Representation.AST.Syntax
  hiding (Prog, PrimOp, LoopOp, Exp, Body, Binding, Pattern, Lambda, FunDec)
import Futhark.Representation.AST.Attributes
import Futhark.Representation.AST.Traversals
import Futhark.Representation.AST.Pretty
import Futhark.Renamer
import Futhark.Binder
import Futhark.Substitute
import qualified Futhark.TypeCheck as TypeCheck
import Futhark.Analysis.Rephrase

-- This module could be written much nicer if Haskell had functors
-- like Standard ML.  Instead, we have to abuse the namespace/module
-- system.

-- | The lore for the basic representation.
data Basic

instance Lore.Lore Basic where

type Prog = AST.Prog Basic
type PrimOp = AST.PrimOp Basic
type LoopOp = AST.LoopOp Basic
type Exp = AST.Exp Basic
type Body = AST.Body Basic
type Binding = AST.Binding Basic
type Pattern = AST.Pattern Basic
type Lambda = AST.Lambda Basic
type FunDec = AST.FunDecT Basic

instance TypeCheck.Checkable Basic where
  checkExpLore = return
  checkBindingLore = return
  checkBodyLore = return

instance Renameable Basic where
instance Substitutable Basic where
instance Proper Basic where

instance Bindable Basic where
  mkBody = AST.Body ()
  mkLet pat = AST.Let (AST.Pattern $ map (`Bindee` ()) pat) ()

instance PrettyLore Basic where

removeLore :: Rephraser lore Basic
removeLore =
  Rephraser { rephraseExpLore = const ()
            , rephraseBindeeLore = const ()
            , rephraseBodyLore = const ()
            , rephraseFParamLore = const ()
            }

removeProgLore :: AST.Prog lore -> Prog
removeProgLore = rephraseProg removeLore

removeFunDecLore :: AST.FunDec lore -> FunDec
removeFunDecLore = rephraseFunDec removeLore

removeBodyLore :: AST.Body lore -> Body
removeBodyLore = rephraseBody removeLore