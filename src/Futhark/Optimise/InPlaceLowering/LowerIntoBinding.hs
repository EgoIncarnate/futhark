{-# LANGUAGE FlexibleContexts #-}
module Futhark.Optimise.InPlaceLowering.LowerIntoBinding
       (
         lowerUpdate
       , DesiredUpdate (..)
       ) where

import Control.Applicative
import Control.Monad
import Control.Monad.Writer
import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.Either
import qualified Data.HashSet as HS

import Prelude

import Futhark.Representation.AST
import Futhark.Construct
import Futhark.MonadFreshNames
import Futhark.Optimise.InPlaceLowering.SubstituteIndices

data DesiredUpdate =
  DesiredUpdate { updateName :: VName -- ^ Name of result.
                , updateType :: Type -- ^ Type of result.
                , updateCertificates :: Certificates
                , updateSource :: VName
                , updateIndices :: [SubExp]
                , updateValue :: VName
                }
  deriving (Show)

updateHasValue :: VName -> DesiredUpdate -> Bool
updateHasValue name = (name==) . updateValue

lowerUpdate :: (Bindable lore, MonadFreshNames m) =>
               Binding lore -> [DesiredUpdate] -> Maybe (m [Binding lore])
lowerUpdate (Let pat _ (LoopOp (DoLoop res merge form body))) updates = do
  canDo <- lowerUpdateIntoLoop updates pat res merge body
  Just $ do
    (prebnds, postbnds, ctxpat, valpat, res', merge', body') <- canDo
    return $
      prebnds ++
      [mkLet' ctxpat valpat $ LoopOp $ DoLoop res' merge' form body'] ++
      postbnds
lowerUpdate
  (Let pat _ (PrimOp (SubExp (Var v))))
  [DesiredUpdate bindee_nm bindee_tp cs src is val]
  | patternNames pat == [src] =
    Just $ return [mkLet [] [(Ident bindee_nm bindee_tp,BindInPlace cs v is)] $
                   PrimOp $ SubExp $ Var val]
lowerUpdate
  (Let (Pattern [] [PatElem v BindVar v_attr]) _ e)
  [DesiredUpdate bindee_nm bindee_tp cs src is val]
  | v == val =
      Just $ return [mkLet [] [(Ident bindee_nm bindee_tp,BindInPlace cs src is)] e,
                     mkLet' [] [Ident v $ typeOf v_attr] $ PrimOp $ Index cs bindee_nm is]
lowerUpdate _ _ =
  Nothing

lowerUpdateIntoLoop :: (Bindable lore, MonadFreshNames m) =>
                       [DesiredUpdate]
                    -> Pattern lore
                    -> [VName]
                    -> [(FParam lore, SubExp)]
                    -> Body lore
                    -> Maybe (m ([Binding lore],
                                 [Binding lore],
                                 [Ident],
                                 [Ident],
                                 [VName],
                                 [(FParam lore, SubExp)],
                                 Body lore))
lowerUpdateIntoLoop updates pat res merge body = do
  -- Algorithm:
  --
  --   0) Map each result of the loop body to a corresponding in-place
  --      update, if one exists.
  --
  --   1) Create new merge variables corresponding to the arrays being
  --      updated; extend the pattern and the @res@ list with these,
  --      and remove the parts of the result list that have a
  --      corresponding in-place update.
  --
  --      (The creation of the new merge variable identifiers is
  --      actually done at the same time as step (0)).
  --
  --   2) Create in-place updates at the end of the loop body.
  --
  --   3) Create index expressions that read back the values written
  --      in (2).  If the merge parameter corresponding to this value
  --      is unique, also @copy@ this value.
  --
  --   4) Update the result of the loop body to properly pass the new
  --      arrays and indexed elements to the next iteration of the
  --      loop.
  --
  -- We also check that the merge parameters we work with have
  -- loop-invariant shapes.
  mk_in_place_map <- summariseLoop updates usedInBody resmap merge
  Just $ do
    in_place_map <- mk_in_place_map
    (merge',prebnds,postbnds) <- mkMerges in_place_map
    let (ctxpat,valpat,res') = mkResAndPat in_place_map
        idxsubsts = indexSubstitutions in_place_map
    (idxsubsts', newbnds) <- substituteIndices idxsubsts $ bodyBindings body
    (body_res, res_bnds) <- manipulateResult in_place_map idxsubsts'
    let body' = mkBody (newbnds++res_bnds) body_res
    return (prebnds, postbnds, ctxpat, valpat, map identName res', merge', body')
  where mergeparams = map fst merge
        usedInBody = freeInBody body
        resmap = loopResultValues
                 (patternValueIdents pat) res
                 (map paramName mergeparams) $
                 bodyResult body

        mkMerges :: (MonadFreshNames m, Bindable lore) =>
                    [LoopResultSummary]
                 -> m ([(Param DeclType, SubExp)], [Binding lore], [Binding lore])
        mkMerges summaries = do
          ((origmerge, extramerge), (prebnds, postbnds)) <-
            runWriterT $ partitionEithers <$> mapM mkMerge summaries
          return (origmerge ++ extramerge, prebnds, postbnds)

        mkMerge summary
          | Just (update, mergeident) <- relatedUpdate summary = do
            source <- newVName "modified_source"
            let updpat = [(Ident source $ updateType update,
                           BindInPlace
                           (updateCertificates update)
                           (updateSource update)
                           (updateIndices update))]
                elmident = Ident (updateValue update) $
                           rowType $ updateType update
            tell ([mkLet [] updpat $ PrimOp $ SubExp $ snd $ mergeParam summary],
                  [mkLet' [] [elmident] $ PrimOp $ Index []
                   (updateName update) (updateIndices update)])
            return $ Right (Param
                            (identName mergeident)
                            (toDecl (identType mergeident) Unique),
                            Var source)
          | otherwise = return $ Left $ mergeParam summary

        mkResAndPat summaries =
          let (orig,extra) = partitionEithers $ mapMaybe mkResAndPat' summaries
              (origpat, origres) = unzip orig
              (extrapat, extrares) = unzip extra
          in (patternContextIdents pat,
              origpat ++ extrapat,
              origres ++ extrares)

        mkResAndPat' summary
          | Just (update, mergeident) <- relatedUpdate summary =
              Just $ Right (Ident (updateName update) (updateType update), mergeident)
          | Just v <- inPatternAs summary =
              Just $ Left (v, paramIdent $ fst $ mergeParam summary)
          | otherwise =
              Nothing

summariseLoop :: MonadFreshNames m =>
                 [DesiredUpdate]
              -> Names
              -> [(SubExp, Maybe Ident)]
              -> [(Param DeclType, SubExp)]
              -> Maybe (m [LoopResultSummary])
summariseLoop updates usedInBody resmap merge =
  sequence <$> zipWithM summariseLoopResult resmap merge
  where summariseLoopResult (se, Just v) (fparam, mergeinit)
          | Just update <- find (updateHasValue $ identName v) updates =
            if updateSource update `HS.member` usedInBody
            then Nothing
            else if hasLoopInvariantShape fparam then Just $ do
              ident <-
                newIdent "lowered_array" $ updateType update
              return LoopResultSummary { resultSubExp = se
                                       , inPatternAs = Just v
                                       , mergeParam = (fparam, mergeinit)
                                       , relatedUpdate = Just (update, ident)
                                       }
            else Nothing
        summariseLoopResult (se, patpart) (fparam, mergeinit) =
          Just $ return LoopResultSummary { resultSubExp = se
                                          , inPatternAs = patpart
                                          , mergeParam = (fparam, mergeinit)
                                          , relatedUpdate = Nothing
                                          }

        hasLoopInvariantShape = all loopInvariant . arrayDims . paramType

        merge_param_names = map (paramName . fst) merge

        loopInvariant (Var v)    = v `notElem` merge_param_names
        loopInvariant Constant{} = True

data LoopResultSummary =
  LoopResultSummary { resultSubExp :: SubExp
                    , inPatternAs :: Maybe Ident
                    , mergeParam :: (Param DeclType, SubExp)
                    , relatedUpdate :: Maybe (DesiredUpdate, Ident)
                    }
  deriving (Show)

indexSubstitutions :: [LoopResultSummary]
                   -> IndexSubstitutions
indexSubstitutions = mapMaybe getSubstitution
  where getSubstitution res = do
          (DesiredUpdate _ _ cs _ is _, Ident nm tp) <- relatedUpdate res
          let name = paramName $ fst $ mergeParam res
          return (name, (cs, nm, tp, is))

manipulateResult :: (Bindable lore, MonadFreshNames m) =>
                    [LoopResultSummary]
                 -> IndexSubstitutions
                 -> m (Result, [Binding lore])
manipulateResult summaries substs = do
  let (orig_ses,updated_ses) = partitionEithers $ map unchangedRes summaries
  (subst_ses, res_bnds) <- runWriterT $ zipWithM substRes updated_ses substs
  return (orig_ses ++ subst_ses, res_bnds)
  where
    unchangedRes summary =
      case relatedUpdate summary of
        Nothing -> Left $ resultSubExp summary
        Just _  -> Right $ resultSubExp summary
    substRes (Var res_v) (subst_v, (_, nm, _, _))
      | res_v == subst_v =
        return $ Var nm
    substRes res_se (_, (cs, nm, tp, is)) = do
      v' <- newIdent' (++"_updated") $ Ident nm tp
      tell [mkLet [] [(v', BindInPlace cs nm is)] $ PrimOp $ SubExp res_se]
      return $ Var $ identName v'
