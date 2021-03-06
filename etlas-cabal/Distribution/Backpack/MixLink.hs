{-# LANGUAGE NondecreasingIndentation #-}
-- | See <https://github.com/ezyang/ghc-proposals/blob/backpack/proposals/0000-backpack.rst>
module Distribution.Backpack.MixLink (
    mixLink,
) where

import Prelude ()
import Distribution.Compat.Prelude hiding (mod)

import Distribution.Backpack
import Distribution.Backpack.UnifyM
import Distribution.Backpack.FullUnitId

import qualified Distribution.Utils.UnionFind as UnionFind
import Distribution.ModuleName
import Distribution.Text
import Distribution.Types.ComponentId
import Distribution.Types.ComponentName

import Text.PrettyPrint
import Control.Monad
import qualified Data.Map as Map
import qualified Data.Foldable as F

-----------------------------------------------------------------------
-- Linking

-- | Given to scopes of provisions and requirements, link them together.
mixLink :: [ModuleScopeU s] -> UnifyM s (ModuleScopeU s)
mixLink scopes = do
    let provs = Map.unionsWith (++) (map fst scopes)
        -- Invariant: any identically named holes refer to same mutable cell
        reqs  = Map.unionsWith (++) (map snd scopes)
        filled = Map.intersectionWithKey linkProvision provs reqs
    F.sequenceA_ filled
    let remaining = Map.difference reqs filled
    return (provs, remaining)

-- TODO: Deduplicate this with Distribution.Backpack.UnifyM.ci_msg
dispSource :: ModuleSourceU s -> Doc
dispSource src
 | usrc_implicit src
 = text "build-depends:" <+> pp_pn
 | otherwise
 = text "mixins:" <+> pp_pn <+> disp (usrc_renaming src)
 where
  pp_pn =
    -- NB: This syntax isn't quite the source syntax, but it
    -- should be clear enough.  To do source syntax, we'd
    -- need to know what the package we're linking is.
    case usrc_compname src of
        CLibName -> disp (usrc_pkgname src)
        CSubLibName cn -> disp (usrc_pkgname src) <<>> colon <<>> disp cn
        -- Shouldn't happen
        cn -> disp (usrc_pkgname src) <+> parens (disp cn)

-- | Link a list of possibly provided modules to a single
-- requirement.  This applies a side-condition that all
-- of the provided modules at the same name are *actually*
-- the same module.
linkProvision :: ModuleName
              -> [ModuleSourceU s] -- provs
              -> [ModuleSourceU s] -- reqs
              -> UnifyM s [ModuleSourceU s]
linkProvision mod_name ret@(prov:provs) (req:reqs) = do
    -- TODO: coalesce all the non-unifying modules together
    forM_ provs $ \prov' -> do
        -- Careful: read it out BEFORE unifying, because the
        -- unification algorithm preemptively unifies modules
        mod  <- convertModuleU (usrc_module prov)
        mod' <- convertModuleU (usrc_module prov')
        r <- unify prov prov'
        case r of
            Just () -> return ()
            Nothing -> do
                addErr $
                  text "Ambiguous module" <+> quotes (disp mod_name) $$
                  text "It could refer to" <+>
                    ( text "  " <+> (quotes (disp mod)  $$ in_scope_by prov) $$
                      text "or" <+> (quotes (disp mod') $$ in_scope_by prov') ) $$
                  link_doc
    mod <- convertModuleU (usrc_module prov)
    req_mod <- convertModuleU (usrc_module req)
    r <- unify prov req
    case r of
        Just () -> return ()
        Nothing -> do
            -- TODO: Record and report WHERE the bad constraint came from
            addErr $ text "Could not instantiate requirement" <+> quotes (disp mod_name) $$
                     nest 4 (text "Expected:" <+> disp mod $$
                             text "Actual:  " <+> disp req_mod) $$
                     parens (text "This can occur if an exposed module of" <+>
                             text "a libraries shares a name with another module.") $$
                     link_doc
    return ret
  where
    unify s1 s2 = tryM $ addErrContext short_link_doc
                       $ unifyModule (usrc_module s1) (usrc_module s2)
    in_scope_by s = text "brought into scope by" <+> dispSource s
    short_link_doc = text "While filling requirement" <+> quotes (disp mod_name)
    link_doc = text "While filling requirements of" <+> reqs_doc
    reqs_doc
      | null reqs = dispSource req
      | otherwise =  (       text "   " <+> dispSource req  $$
                      vcat [ text "and" <+> dispSource r | r <- reqs])
linkProvision _ _ _ = error "linkProvision"



-----------------------------------------------------------------------
-- The unification algorithm

-- This is based off of https://gist.github.com/amnn/559551517d020dbb6588
-- which is a translation from Huet's thesis.

unifyUnitId :: UnitIdU s -> UnitIdU s -> UnifyM s ()
unifyUnitId uid1_u uid2_u
    | uid1_u == uid2_u = return ()
    | otherwise = do
        xuid1 <- liftST $ UnionFind.find uid1_u
        xuid2 <- liftST $ UnionFind.find uid2_u
        case (xuid1, xuid2) of
            (UnitIdThunkU u1, UnitIdThunkU u2)
                | u1 == u2  -> return ()
                | otherwise ->
                    failWith $ hang (text "Couldn't match unit IDs:") 4
                               (text "   " <+> disp u1 $$
                                text "and" <+> disp u2)
            (UnitIdThunkU uid1, UnitIdU _ cid2 insts2)
                -> unifyThunkWith cid2 insts2 uid2_u uid1 uid1_u
            (UnitIdU _ cid1 insts1, UnitIdThunkU uid2)
                -> unifyThunkWith cid1 insts1 uid1_u uid2 uid2_u
            (UnitIdU _ cid1 insts1, UnitIdU _ cid2 insts2)
                -> unifyInner cid1 insts1 uid1_u cid2 insts2 uid2_u

unifyThunkWith :: ComponentId
               -> Map ModuleName (ModuleU s)
               -> UnitIdU s
               -> DefUnitId
               -> UnitIdU s
               -> UnifyM s ()
unifyThunkWith cid1 insts1 uid1_u uid2 uid2_u = do
    db <- fmap unify_db getUnifEnv
    let FullUnitId cid2 insts2' = expandUnitId db uid2
    insts2 <- convertModuleSubst insts2'
    unifyInner cid1 insts1 uid1_u cid2 insts2 uid2_u

unifyInner :: ComponentId
           -> Map ModuleName (ModuleU s)
           -> UnitIdU s
           -> ComponentId
           -> Map ModuleName (ModuleU s)
           -> UnitIdU s
           -> UnifyM s ()
unifyInner cid1 insts1 uid1_u cid2 insts2 uid2_u = do
    when (cid1 /= cid2) $
        -- TODO: if we had a package identifier, could be an
        -- easier to understand error message.
        failWith $
            hang (text "Couldn't match component IDs:") 4
                 (text "   " <+> disp cid1 $$
                  text "and" <+> disp cid2)
    -- The KEY STEP which makes this a Huet-style unification
    -- algorithm.  (Also a payoff of using union-find.)
    -- We can build infinite unit IDs this way, which is necessary
    -- for support mutual recursion. NB: union keeps the SECOND
    -- descriptor, so we always arrange for a UnitIdThunkU to live
    -- there.
    liftST $ UnionFind.union uid1_u uid2_u
    F.sequenceA_ $ Map.intersectionWith unifyModule insts1 insts2

-- | Imperatively unify two modules.
unifyModule :: ModuleU s -> ModuleU s -> UnifyM s ()
unifyModule mod1_u mod2_u
    | mod1_u == mod2_u = return ()
    | otherwise = do
        mod1 <- liftST $ UnionFind.find mod1_u
        mod2 <- liftST $ UnionFind.find mod2_u
        case (mod1, mod2) of
            (ModuleVarU _, _) -> liftST $ UnionFind.union mod1_u mod2_u
            (_, ModuleVarU _) -> liftST $ UnionFind.union mod2_u mod1_u
            (ModuleU uid1 mod_name1, ModuleU uid2 mod_name2) -> do
                when (mod_name1 /= mod_name2) $
                    failWith $
                        hang (text "Cannot match module names") 4 $
                            text "   " <+> disp mod_name1 $$
                            text "and" <+> disp mod_name2
                -- NB: this is not actually necessary (because we'll
                -- detect loops eventually in 'unifyUnitId'), but it
                -- seems harmless enough
                liftST $ UnionFind.union mod1_u mod2_u
                unifyUnitId uid1 uid2
