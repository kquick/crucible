-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.LLVM.Translation.Instruction
-- Description      : Translation of LLVM instructions
-- Copyright        : (c) Galois, Inc 2018
-- License          : BSD3
-- Maintainer       : Rob Dockins <rdockins@galois.com>
-- Stability        : provisional
--
-- This module represents the workhorse of the LLVM translation.  It
-- is responsable for interpreting the LLVM instruction set into
-- corresponding crucible statements.
-----------------------------------------------------------------------
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE ImplicitParams        #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PatternGuards         #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}

module Lang.Crucible.LLVM.Translation.Instruction
  ( instrResultType
  , generateInstr
  , definePhiBlock
  , assignLLVMReg
  ) where

import Control.Monad.Except
import Control.Monad.State.Strict
import Control.Lens hiding (op, (:>) )
import Data.Foldable (toList)
import Data.Int
import qualified Data.List as List
import Data.Maybe
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.String
import qualified Data.Vector as V
import qualified Data.Text   as Text

import qualified Text.LLVM.AST as L

import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Context ( pattern (:>) )
import           Data.Parameterized.NatRepr as NatRepr

import Data.Parameterized.Some
import Text.PrettyPrint.ANSI.Leijen (pretty)

import           Lang.Crucible.CFG.Expr
import           Lang.Crucible.CFG.Generator

import           Lang.Crucible.LLVM.DataLayout
import           Lang.Crucible.LLVM.Extension
import           Lang.Crucible.LLVM.MemType

import qualified Lang.Crucible.LLVM.Bytes as G
import           Lang.Crucible.LLVM.MemModel
import           Lang.Crucible.LLVM.Translation.Constant
import           Lang.Crucible.LLVM.Translation.Expr
import           Lang.Crucible.LLVM.Translation.Monad
import           Lang.Crucible.LLVM.Translation.Types
import           Lang.Crucible.LLVM.TypeContext
import           Lang.Crucible.Syntax
import           Lang.Crucible.Types


instrResultType ::
  (?lc :: TypeContext, MonadError String m, HasPtrWidth wptr) =>
  L.Instr ->
  m MemType
instrResultType instr =
  case instr of
    L.Arith _ x _ -> liftMemType (L.typedType x)
    L.Bit _ x _   -> liftMemType (L.typedType x)
    L.Conv _ _ ty -> liftMemType ty
    L.Call _ (L.PtrTo (L.FunTy ty _ _)) _ _ -> liftMemType ty
    L.Call _ ty _ _ ->  fail $ unwords ["unexpected function type in call:", show ty]
    L.Invoke (L.FunTy ty _ _) _ _ _ _ -> liftMemType ty
    L.Invoke ty _ _ _ _ -> fail $ unwords ["unexpected function type in invoke:", show ty]
    L.Alloca ty _ _ -> liftMemType (L.PtrTo ty)
    L.Load x _ _ -> case L.typedType x of
                   L.PtrTo ty -> liftMemType ty
                   _ -> fail $ unwords ["load through non-pointer type", show (L.typedType x)]
    L.ICmp _ _ _ -> liftMemType (L.PrimType (L.Integer 1))
    L.FCmp _ _ _ -> liftMemType (L.PrimType (L.Integer 1))
    L.Phi tp _   -> liftMemType tp

    L.GEP inbounds base elts ->
       do gepRes <- runExceptT (translateGEP inbounds base elts)
          case gepRes of
            Left err -> fail err
            Right (GEPResult lanes tp _gep) ->
              let n = fromInteger (natValue lanes) in
              if n == 1 then
                return (PtrType (MemType tp))
              else
                return (VecType n (PtrType (MemType tp)))

    L.Select _ x _ -> liftMemType (L.typedType x)

    L.ExtractValue x idxes -> liftMemType (L.typedType x) >>= go idxes
         where go [] tp = return tp
               go (i:is) (ArrayType n tp')
                   | i < fromIntegral n = go is tp'
                   | otherwise = fail $ unwords ["invalid index into array type", showInstr instr]
               go (i:is) (StructType si) =
                      case siFields si V.!? (fromIntegral i) of
                        Just fi -> go is (fiType fi)
                        Nothing -> error $ unwords ["invalid index into struct type", showInstr instr]
               go _ _ = fail $ unwords ["invalid type in extract value instruction", showInstr instr]

    L.InsertValue x _ _ -> liftMemType (L.typedType x)

    L.ExtractElt x _ ->
       do tp <- liftMemType (L.typedType x)
          case tp of
            VecType _n tp' -> return tp'
            _ -> fail $ unwords ["extract element of non-vector type", showInstr instr]

    L.InsertElt x _ _ -> liftMemType (L.typedType x)

    L.ShuffleVector x _ i ->
      do xtp <- liftMemType (L.typedType x)
         itp <- liftMemType (L.typedType i)
         case (xtp, itp) of
           (VecType _n ty, VecType m _) -> return (VecType m ty)
           _ -> fail $ unwords ["invalid shufflevector:", showInstr instr]

    L.LandingPad x _ _ _ -> liftMemType x

    _ -> fail $ unwords ["instrResultType, unsupported instruction:", showInstr instr]



liftMemType' :: (?lc::TypeContext, Monad m) => L.Type -> m MemType
liftMemType' = either fail return . liftMemType 

-- | Given an LLVM expression of vector type, select out the ith element.
extractElt
    :: forall h s arch ret.
       L.Instr
    -> MemType    -- ^ type contained in the vector
    -> Integer   -- ^ size of the vector
    -> LLVMExpr s arch  -- ^ vector expression
    -> LLVMExpr s arch -- ^ index expression
    -> LLVMGenerator h s arch ret (LLVMExpr s arch)
extractElt _instr ty _n (UndefExpr _) _i =
   return $ UndefExpr ty
extractElt _instr ty _n (ZeroExpr _) _i =
   return $ ZeroExpr ty
extractElt _ ty _ _ (UndefExpr _) =
   return $ UndefExpr ty
extractElt instr ty n v (ZeroExpr zty) =
   let ?err = fail in
   zeroExpand zty $ \tyr ex -> extractElt instr ty n v (BaseExpr tyr ex)
extractElt instr _ n (VecExpr _ vs) i
  | Scalar (LLVMPointerRepr _) (BitvectorAsPointerExpr _ x) <- asScalar i
  , App (BVLit _ x') <- x
  = constantExtract x'

 where
 constantExtract :: Integer -> LLVMGenerator h s arch ret (LLVMExpr s arch)
 constantExtract idx =
    if (fromInteger idx < Seq.length vs) && (fromInteger idx < n)
        then return $ Seq.index vs (fromInteger idx)
        else fail (unlines ["invalid extractelement instruction (index out of bounds)", showInstr instr])

extractElt instr ty n (VecExpr _ vs) i = do
   let ?err = fail
   llvmTypeAsRepr ty $ \tyr -> unpackVec tyr (toList vs) $
      \ex -> extractElt instr ty n (BaseExpr (VectorRepr tyr) ex) i
extractElt instr _ n (BaseExpr (VectorRepr tyr) v) i =
  do idx <- case asScalar i of
                   Scalar (LLVMPointerRepr w) x ->
                     do bv <- pointerAsBitvectorExpr w x
                        assertExpr (App (BVUlt w bv (App (BVLit w n)))) "extract element index out of bounds!"
                        return $ App (BvToNat w bv)
                   _ ->
                     fail (unlines ["invalid extractelement instruction", showInstr instr])
     return $ BaseExpr tyr (App (VectorGetEntry tyr v idx))

extractElt instr _ _ _ _ = fail (unlines ["invalid extractelement instruction", showInstr instr])


-- | Given an LLVM expression of vector type, insert a new element at location ith element.
insertElt :: forall h s arch ret.
       L.Instr            -- ^ Actual instruction
    -> MemType            -- ^ type contained in the vector
    -> Integer            -- ^ size of the vector
    -> LLVMExpr s arch    -- ^ vector expression
    -> LLVMExpr s arch    -- ^ element to insert
    -> LLVMExpr s arch    -- ^ index expression
    -> LLVMGenerator h s arch ret (LLVMExpr s arch)
insertElt _ ty _ _ _ (UndefExpr _) = do
   return $ UndefExpr ty
insertElt instr ty n v a (ZeroExpr zty) = do
   let ?err = fail
   zeroExpand zty $ \tyr ex -> insertElt instr ty n v a (BaseExpr tyr ex)

insertElt instr ty n (UndefExpr _) a i  = do
  insertElt instr ty n (VecExpr ty (Seq.replicate (fromInteger n) (UndefExpr ty))) a i
insertElt instr ty n (ZeroExpr _) a i   = do
  insertElt instr ty n (VecExpr ty (Seq.replicate (fromInteger n) (ZeroExpr ty))) a i

insertElt instr _ n (VecExpr ty vs) a i
  | Scalar (LLVMPointerRepr _) (BitvectorAsPointerExpr _ x) <- asScalar i
  , App (BVLit _ x') <- x
  = constantInsert x'
 where
 constantInsert :: Integer -> LLVMGenerator h s arch ret (LLVMExpr s arch)
 constantInsert idx =
     if (fromInteger idx < Seq.length vs) && (fromInteger idx < n)
       then return $ VecExpr ty $ Seq.adjust (\_ -> a) (fromIntegral idx) vs
       else fail (unlines ["invalid insertelement instruction (index out of bounds)", showInstr instr])

insertElt instr ty n (VecExpr _ vs) a i = do
   let ?err = fail
   llvmTypeAsRepr ty $ \tyr -> unpackVec tyr (toList vs) $
        \ex -> insertElt instr ty n (BaseExpr (VectorRepr tyr) ex) a i

insertElt instr _ n (BaseExpr (VectorRepr tyr) v) a i =
  do (idx :: Expr (LLVM arch) s NatType)
         <- case asScalar i of
                   Scalar (LLVMPointerRepr w) x ->
                     do bv <- pointerAsBitvectorExpr w x
                        assertExpr (App (BVUlt w bv (App (BVLit w n)))) "insert element index out of bounds!"
                        return $ App (BvToNat w bv)
                   _ ->
                     fail (unlines ["invalid insertelement instruction", showInstr instr, show i])
     let ?err = fail
     unpackOne a $ \tyra a' ->
      case testEquality tyr tyra of
        Just Refl ->
          return $ BaseExpr (VectorRepr tyr) (App (VectorSetEntry tyr v idx a'))
        Nothing -> fail (unlines ["type mismatch in insertelement instruction", showInstr instr])
insertElt instr _tp n v a i = fail (unlines ["invalid insertelement instruction", showInstr instr, show n, show v, show a, show i])

-- Given an LLVM expression of vector or structure type, select out the
-- element indicated by the sequence of given concrete indices.
extractValue
    :: LLVMExpr s arch  -- ^ aggregate expression
    -> [Int32]     -- ^ sequence of indices
    -> LLVMGenerator h s arch ret (LLVMExpr s arch)
extractValue v [] = return v
extractValue (UndefExpr (StructType si)) is =
   extractValue (StructExpr $ Seq.fromList $ map (\tp -> (tp, UndefExpr tp)) tps) is
 where tps = map fiType $ toList $ siFields si
extractValue (UndefExpr (ArrayType n tp)) is =
   extractValue (VecExpr tp $ Seq.replicate (fromIntegral n) (UndefExpr tp)) is
extractValue (ZeroExpr (StructType si)) is =
   extractValue (StructExpr $ Seq.fromList $ map (\tp -> (tp, ZeroExpr tp)) tps) is
 where tps = map fiType $ toList $ siFields si
extractValue (ZeroExpr (ArrayType n tp)) is =
   extractValue (VecExpr tp $ Seq.replicate (fromIntegral n) (ZeroExpr tp)) is
extractValue (BaseExpr (StructRepr ctx) x) (i:is)
   | Just (Some idx) <- Ctx.intIndex (fromIntegral i) (Ctx.size ctx) = do
           let tpr = ctx Ctx.! idx
           extractValue (BaseExpr tpr (getStruct idx x)) is
extractValue (StructExpr vs) (i:is)
   | fromIntegral i < Seq.length vs = extractValue (snd $ Seq.index vs $ fromIntegral i) is
extractValue (VecExpr _ vs) (i:is)
   | fromIntegral i < Seq.length vs = extractValue (Seq.index vs $ fromIntegral i) is
extractValue _ _ = fail "invalid extractValue instruction"


-- Given an LLVM expression of vector or structure type, insert a new element in the posistion
-- given by the concrete indices.
insertValue
    :: LLVMExpr s arch  -- ^ aggregate expression
    -> LLVMExpr s arch  -- ^ element to insert
    -> [Int32]     -- ^ sequence of concrete indices
    -> LLVMGenerator h s arch ret (LLVMExpr s arch)
insertValue _ v [] = return v
insertValue (UndefExpr (StructType si)) v is =
   insertValue (StructExpr $ Seq.fromList $ map (\tp -> (tp, UndefExpr tp)) tps) v is
 where tps = map fiType $ toList $ siFields si
insertValue (UndefExpr (ArrayType n tp)) v is =
   insertValue (VecExpr tp $ Seq.replicate (fromIntegral n) (UndefExpr tp)) v is
insertValue (ZeroExpr (StructType si)) v is =
   insertValue (StructExpr $ Seq.fromList $ map (\tp -> (tp, ZeroExpr tp)) tps) v is
 where tps = map fiType $ toList $ siFields si
insertValue (ZeroExpr (ArrayType n tp)) v is =
   insertValue (VecExpr tp $ Seq.replicate (fromIntegral n) (ZeroExpr tp)) v is
insertValue (BaseExpr (StructRepr ctx) x) v (i:is)
   | Just (Some idx) <- Ctx.intIndex (fromIntegral i) (Ctx.size ctx) = do
           let tpr = ctx Ctx.! idx
           x' <- insertValue (BaseExpr tpr (getStruct idx x)) v is
           case x' of
             BaseExpr tpr' x''
               | Just Refl <- testEquality tpr tpr' ->
                    return $ BaseExpr (StructRepr ctx) (setStruct ctx x idx x'')
             _ -> fail "insertValue was expected to return base value of same type"
insertValue (StructExpr vs) v (i:is)
   | fromIntegral i < Seq.length vs = do
        let (xtp, x) = Seq.index vs (fromIntegral i)
        x' <- insertValue x v is
        return (StructExpr (Seq.adjust (\_ -> (xtp,x')) (fromIntegral i) vs))
insertValue (VecExpr tp vs) v (i:is)
   | fromIntegral i < Seq.length vs = do
        let x = Seq.index vs (fromIntegral i)
        x' <- insertValue x v is
        return (VecExpr tp (Seq.adjust (\_ -> x') (fromIntegral i) vs))
insertValue _ _ _ = fail "invalid insertValue instruction"



evalGEP :: forall h s arch ret wptr.
  wptr ~ ArchWidth arch =>
  L.Instr ->
  GEPResult (LLVMExpr s arch) ->
  LLVMGenerator h s arch ret (LLVMExpr s arch)
evalGEP instr (GEPResult _lanes finalMemType gep0) = finish =<< go gep0
 where
 finish xs =
   case Seq.viewl xs of
     x Seq.:< (Seq.null -> True) -> return (BaseExpr PtrRepr x)
     _ -> return (VecExpr (PtrType (MemType finalMemType)) (fmap (BaseExpr PtrRepr) xs))

 badGEP :: LLVMGenerator h s arch ret a
 badGEP = fail $ unlines ["Unexpected failure when evaluating GEP", showInstr instr]

 asPtr :: LLVMExpr s arch -> LLVMGenerator h s arch ret (Expr (LLVM arch) s (LLVMPointerType wptr))
 asPtr x =
   case asScalar x of
     Scalar PtrRepr p -> return p
     _ -> badGEP

 go :: GEP n (LLVMExpr s arch) -> LLVMGenerator h s arch ret (Seq (Expr (LLVM arch) s (LLVMPointerType wptr)))

 go (GEP_scalar_base x) =
      do p <- asPtr x
         return (Seq.singleton p)

 go (GEP_vector_base n x) =
      do xs <- maybe badGEP (traverse asPtr) (asVector x)
         unless (toInteger (Seq.length xs) == natValue n) badGEP
         return xs

 go (GEP_scatter n gep) =
      do xs <- go gep
         unless (Seq.length xs == 1) badGEP
         return (Seq.cycleTaking (fromInteger (natValue n)) xs)

 go (GEP_field fi gep) =
      do xs <- go gep
         traverse (\x -> calcGEP_struct fi x) xs

 go (GEP_index_each mt' gep idx) =
      do xs <- go gep
         traverse (\x -> calcGEP_array mt' x idx) xs

 go (GEP_index_vector mt' gep idx) =
      do xs <- go gep
         idxs <- maybe badGEP return (asVector idx)
         unless (Seq.length idxs == Seq.length xs) badGEP
         traverse (\(x,i) -> calcGEP_array mt' x i) (Seq.zip xs idxs)


calcGEP_array :: forall wptr arch h s ret.
  wptr ~ ArchWidth arch =>
  MemType {- ^ Type of the array elements -} ->
  Expr (LLVM arch) s (LLVMPointerType wptr) {- ^ Base pointer -} ->
  LLVMExpr s arch {- ^ index value -} ->
  LLVMGenerator h s arch ret (Expr (LLVM arch) s (LLVMPointerType wptr))
calcGEP_array typ base idx =
  do -- sign-extend the index value if necessary to make it
     -- the same width as a pointer
     (idx' :: Expr (LLVM arch) s (BVType wptr))
       <- case asScalar idx of
              Scalar (LLVMPointerRepr w) x
                 | Just Refl <- testEquality w PtrWidth ->
                      pointerAsBitvectorExpr PtrWidth x
                 | Just LeqProof <- testLeq (incNat w) PtrWidth ->
                   do x' <- pointerAsBitvectorExpr w x
                      return $ app (BVSext PtrWidth w x')
              _ -> fail $ unwords ["Invalid index value in GEP", show idx]

     -- Calculate the size of the element memtype and check that it fits
     -- in the pointer width
     let dl  = llvmDataLayout ?lc
     let isz = G.bytesToInteger $ memTypeSize dl typ
     unless (isz <= maxSigned PtrWidth)
       (fail $ unwords ["Type size too large for pointer width:", show typ])

     unless (isz == 0) $ do
       -- Compute safe upper and lower bounds for the index value to prevent multiplication
       -- overflow.  Note that `minidx <= idx <= maxidx` iff `MININT <= (isz * idx) <= MAXINT`
       -- when `isz` and `idx` are considered as infinite precision integers.
       -- This property holds only if we use `quot` (which rounds toward 0) for the
       -- divisions in the following definitions.

       -- maximum and minimum indices to prevent multiplication overflow
       let maxidx = maxSigned PtrWidth `quot` (max isz 1)
       let minidx = minSigned PtrWidth `quot` (max isz 1)

       -- Assert the necessary range condition
       assertExpr ((app $ BVSle PtrWidth (app $ BVLit PtrWidth minidx) idx') .&&
                   (app $ BVSle PtrWidth idx' (app $ BVLit PtrWidth maxidx)))
                  (litExpr "Multiplication overflow in getelementpointer")

     -- Perform the multiply
     let off = app $ BVMul PtrWidth (app $ BVLit PtrWidth isz) idx'

     -- Perform the pointer offset arithmetic
     callPtrAddOffset base off


calcGEP_struct ::
  wptr ~ ArchWidth arch =>
  FieldInfo ->
  Expr (LLVM arch) s (LLVMPointerType wptr) ->
  LLVMGenerator h s arch ret (Expr (LLVM arch) s (LLVMPointerType wptr))
calcGEP_struct fi base =
      do -- Get the field offset and check that it fits
         -- in the pointer width
         let ioff = G.bytesToInteger $ fiOffset fi
         unless (ioff <= maxSigned PtrWidth)
           (fail $ unwords ["Field offset too large for pointer width in structure:", show ioff])
         let off  = app $ BVLit PtrWidth $ ioff

         -- Perform the pointer arithmetic and continue
         callPtrAddOffset base off




translateConversion
  :: L.Instr
  -> L.ConvOp
  -> L.Typed L.Value
  -> L.Type
  -> LLVMGenerator h s arch ret (LLVMExpr s arch)
translateConversion instr op x outty =
 let showI = showInstr instr in
 case op of
    L.IntToPtr -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (LLVMPointerRepr w) _, LLVMPointerRepr w')
              | Just Refl <- testEquality w PtrWidth
              , Just Refl <- testEquality w' PtrWidth -> return x'
           (Scalar t v, a)   ->
               fail (unlines ["integer-to-pointer conversion failed: "
                             , showI
                             , show v ++ " : " ++ show (pretty t) ++ " -to- " ++ show (pretty a)
                             ])
           (NotScalar, _) -> fail (unlines ["integer-to-pointer conversion failed: non scalar", showI])

    L.PtrToInt -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (LLVMPointerRepr w) _, LLVMPointerRepr w')
              | Just Refl <- testEquality w PtrWidth
              , Just Refl <- testEquality w' PtrWidth -> return x'
           _ -> fail (unlines ["pointer-to-integer conversion failed", showI])

    L.Trunc -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (LLVMPointerRepr w) x'', (LLVMPointerRepr w'))
             | Just LeqProof <- isPosNat w'
             , Just LeqProof <- testLeq (incNat w') w ->
                 do x_bv <- pointerAsBitvectorExpr w x''
                    let bv' = App (BVTrunc w' w x_bv)
                    return (BaseExpr outty'' (BitvectorAsPointerExpr w' bv'))
           _ -> fail (unlines [unwords ["invalid truncation:", show x, show outty], showI])

    L.ZExt -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (LLVMPointerRepr w) x'', (LLVMPointerRepr w'))
             | Just LeqProof <- isPosNat w
             , Just LeqProof <- testLeq (incNat w) w' ->
                 do x_bv <- pointerAsBitvectorExpr w x''
                    let bv' = App (BVZext w' w x_bv)
                    return (BaseExpr outty'' (BitvectorAsPointerExpr w' bv'))
           _ -> fail (unlines [unwords ["invalid zero extension:", show x, show outty], showI])

    L.SExt -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (LLVMPointerRepr w) x'', (LLVMPointerRepr w'))
             | Just LeqProof <- isPosNat w
             , Just LeqProof <- testLeq (incNat w) w' -> do
                 do x_bv <- pointerAsBitvectorExpr w x''
                    let bv' = App (BVSext w' w x_bv)
                    return (BaseExpr outty'' (BitvectorAsPointerExpr w' bv'))
           _ -> fail (unlines [unwords ["invalid sign extension", show x, show outty], showI])

    L.BitCast -> do
       tp <- either fail return $ liftMemType $ L.typedType x
       outty' <- liftMemType' outty
       x' <- transValue tp (L.typedValue x)
       bitCast tp x' outty'

    L.UiToFp -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (LLVMPointerRepr w) x'', FloatRepr fi) -> do
             bv <- pointerAsBitvectorExpr w x''
             return $ BaseExpr (FloatRepr fi) $ App $ FloatFromBV fi RNE bv
           _ -> fail (unlines [unwords ["Invalid uitofp:", show op, show x, show outty], showI])

    L.SiToFp -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (LLVMPointerRepr w) x'', FloatRepr fi) -> do
             bv <- pointerAsBitvectorExpr w x''
             return $ BaseExpr (FloatRepr fi) $ App $ FloatFromSBV fi RNE bv
           _ -> fail (unlines [unwords ["Invalid sitofp:", show op, show x, show outty], showI])

    L.FpToUi -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       let demoteToInt :: (1 <= w) => NatRepr w -> Expr (LLVM arch) s (FloatType fi) -> LLVMExpr s arch
           demoteToInt w v = BaseExpr (LLVMPointerRepr w) (BitvectorAsPointerExpr w $ App $ FloatToBV w RNE v)
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (FloatRepr _) x'', LLVMPointerRepr w) -> return $ demoteToInt w x''
           _ -> fail (unlines [unwords ["Invalid fptoui:", show op, show x, show outty], showI])

    L.FpToSi -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       let demoteToInt :: (1 <= w) => NatRepr w -> Expr (LLVM arch) s (FloatType fi) -> LLVMExpr s arch
           demoteToInt w v = BaseExpr (LLVMPointerRepr w) (BitvectorAsPointerExpr w $ App $ FloatToSBV w RNE v)
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (FloatRepr _) x'', LLVMPointerRepr w) -> return $ demoteToInt w x''
           _ -> fail (unlines [unwords ["Invalid fptosi:", show op, show x, show outty], showI])

    L.FpTrunc -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (FloatRepr _) x'', FloatRepr fi) -> do
             return $ BaseExpr (FloatRepr fi) $ App $ FloatCast fi RNE x''
           _ -> fail (unlines [unwords ["Invalid fptrunc:", show op, show x, show outty], showI])

    L.FpExt -> do
       outty' <- liftMemType' outty
       x' <- transTypedValue x
       llvmTypeAsRepr outty' $ \outty'' ->
         case (asScalar x', outty'') of
           (Scalar (FloatRepr _) x'', FloatRepr fi) -> do
             return $ BaseExpr (FloatRepr fi) $ App $ FloatCast fi RNE x''
           _ -> fail (unlines [unwords ["Invalid fpext:", show op, show x, show outty], showI])


--------------------------------------------------------------------------------
-- Bit Cast


bitCast :: (?lc::TypeContext,HasPtrWidth wptr, wptr ~ ArchWidth arch) =>
          MemType {- ^ starting type of the expression -} ->
          LLVMExpr s arch {- ^ expression to cast -} ->
          MemType {- ^ target type -} ->
          LLVMGenerator h s arch ret (LLVMExpr s arch)

bitCast _ (ZeroExpr _) tgtT = return (ZeroExpr tgtT)
bitCast _ (UndefExpr _) tgtT = return (UndefExpr tgtT)

bitCast srcT expr tgtT =
  llvmTypeAsRepr tgtT $ \cruT ->    -- Crucible version of the type

  -- First check if we are casting anything at all
  case asScalar expr of
    Scalar tyx _ | Just Refl <- testEquality tyx cruT -> return expr  -- no cast
    _ -> mb $
      case tgtT of

        -- Vector to bit-vector
        IntType {} | Just (_,es) <- mbEls ->
          do res@(BaseExpr ty _) <- vecJoin es
             Refl <- testEquality ty cruT
             return res

        VecType len ty@(IntType w1)
          | w1 > 0 ->
            do VectorRepr (BVRepr n) <- return cruT
               vs <- case mbEls of
                       Nothing -> vecSplit n expr
                       Just (IntType w2, es)
                         | w1 > w2   -> vecSplitVec n es
                         | otherwise -> vecJoinVec es (fromIntegral (div w2 w1))
                       _ -> Nothing

               guard (length vs == len)
               return $ VecExpr ty $ Seq.fromList vs

          | otherwise -> Nothing

        _ -> Nothing

  where
  mb    = maybe (err [ "*** Invalid coercion of expression"
                     , indent (show expr)
                     , "of type"
                     , indent (show srcT)
                     , "to type"
                     , indent (show tgtT)
                     ]) return
  mbEls = do (ty,se) <- asVectorWithType expr
             return (ty, toList se)
  err msg = reportError $ fromString $ unlines ("[bitCast] Failed to perform cast:" : msg)
  indent msg = "  " ++ msg


-- | Join the elements of a vector into a single bit-vector value.
-- The resulting bit-vector would be of length at least one.
vecJoin ::
  (?lc::TypeContext,HasPtrWidth w, w ~ ArchWidth arch) =>
  [LLVMExpr s arch] {- ^ Join these vector elements -} ->
  Maybe (LLVMExpr s arch)
vecJoin exprs =
  do (a,ys) <- List.uncons exprs
     Scalar (BVRepr n) e1 <- return (asScalar a)
     if null ys
       then do LeqProof <- testLeq (knownNat @1) n
               return (BaseExpr (BVRepr n) e1)
       else do BaseExpr (BVRepr m) e2 <- vecJoin ys
               let p1 = leqProof (knownNat @0) n
                   p2 = leqProof (knownNat @1) m
               (LeqProof,LeqProof) <- return (leqAdd2 p1 p2, leqAdd2 p2 p1)
               let bits u v x y = bitVal (addNat u v) (BVConcat u v x y)
               return $! case llvmDataLayout ?lc ^. intLayout of
                           LittleEndian -> bits m n e2 e1
                           BigEndian    -> bits n m e1 e2

-- | Join the elements in a vector,
-- to get a shorter vector with larger elements.
vecJoinVec ::
  (?lc::TypeContext,HasPtrWidth w, w ~ ArchWidth arch) =>
  [ LLVMExpr s arch ] {- ^ Input vector -} ->
  Int            {- ^ Number of els. to join to get 1 el. of result -} ->
  Maybe [ LLVMExpr s arch ]
vecJoinVec exprs n = mapM vecJoin =<< chunk n exprs

-- | Split a list into sub-lists of the given length.
-- Fails if the list does not divide exactly.
chunk :: Int -> [a] -> Maybe [[a]]
chunk n xs = case xs of
               [] -> Just []
               _  -> case splitAt n xs of
                       (_,[])  -> Nothing
                       (as,bs) -> (as :) <$> chunk n bs

bitVal :: (1 <= n) => NatRepr n ->
                  App (LLVM arch) (Expr (LLVM arch) s) (BVType n) ->
                  LLVMExpr s arch
bitVal n e = BaseExpr (BVRepr n) (App e)


-- | Split a single bit-vector value into a vector of value of the given width.
vecSplit :: forall s n w arch. (?lc::TypeContext,HasPtrWidth w, w ~ ArchWidth arch, 1 <= n) =>
  NatRepr n  {- ^ Length of a single element -} ->
  LLVMExpr s arch {- ^ Bit-vector value -} ->
  Maybe [ LLVMExpr s arch ]
vecSplit elLen expr =
  do Scalar (BVRepr totLen) e <- return (asScalar expr)
     let getEl :: NatRepr offset -> Maybe [ LLVMExpr s arch ]
         getEl offset = let end = addNat offset elLen
                        in case testLeq end totLen of
                             Just LeqProof ->
                               do rest <- getEl end
                                  let x = bitVal elLen
                                            (BVSelect offset elLen totLen e)
                                  return (x : rest)
                             Nothing ->
                               do Refl <- testEquality offset totLen
                                  return []
     els <- getEl (knownNat @0)
     -- in `els` the least significant chunk is first

     return $! case lay ^. intLayout of
                 LittleEndian -> els
                 BigEndian    -> reverse els
  where
  lay = llvmDataLayout ?lc

-- | Split the elements in a vector,
-- to get a longer vector with smaller element.
vecSplitVec ::
  (?lc::TypeContext,HasPtrWidth w, w ~ ArchWidth arch, 1 <= n) =>
  NatRepr n          {- ^ Length of a single element in the new vector -} ->
  [LLVMExpr s arch ] {- ^ Vector to split -} ->
  Maybe [ LLVMExpr s arch ]
vecSplitVec n es = concat <$> mapM (vecSplit n) es


intop :: (1 <= w)
      => L.ArithOp
      -> NatRepr w
      -> Expr (LLVM arch) s (BVType w)
      -> Expr (LLVM arch) s (BVType w)
      -> LLVMGenerator h s arch ret (Expr (LLVM arch) s (BVType w))
intop op w a b =
      case op of
             L.Add nuw nsw -> do
                let nuwCond expr
                     | nuw = return $ App $ AddSideCondition (BaseBVRepr w)
                                (notExpr (App (BVCarry w a b)))
                                "unsigned overflow on addition"
                                expr
                     | otherwise = return expr

                let nswCond expr
                     | nsw = return $ App $ AddSideCondition (BaseBVRepr w)
                                (notExpr (App (BVSCarry w a b)))
                                "signed overflow on addition"
                                expr
                     | otherwise = return expr

                nuwCond =<< nswCond (App (BVAdd w a b))

             L.Sub nuw nsw -> do
                let nuwCond expr
                     | nuw = return $ App $ AddSideCondition (BaseBVRepr w)
                                (notExpr (App (BVUlt w a b)))
                                "unsigned overflow on subtraction"
                                expr
                     | otherwise = return expr

                let nusCond expr
                     | nsw = return $ App $ AddSideCondition (BaseBVRepr w)
                                (notExpr (App (BVSBorrow w a b)))
                                "signed overflow on subtraction"
                                expr
                     | otherwise = return expr

                nuwCond =<< nusCond (App (BVSub w a b))

             L.Mul nuw nsw -> do
                let w' = addNat w w
                Just LeqProof <- return $ isPosNat w'
                Just LeqProof <- return $ testLeq (incNat w) w'

                prod <- AtomExpr <$> mkAtom (App (BVMul w a b))
                let nuwCond expr
                     | nuw = do
                         az <- AtomExpr <$> mkAtom (App (BVZext w' w a))
                         bz <- AtomExpr <$> mkAtom (App (BVZext w' w b))
                         wideprod <- AtomExpr <$> mkAtom (App (BVMul w' az bz))
                         prodz <- AtomExpr <$> mkAtom (App (BVZext w' w prod))
                         return $ App $ AddSideCondition (BaseBVRepr w)
                                (App (BVEq w' wideprod prodz))
                                "unsigned overflow on multiplication"
                                expr
                     | otherwise = return expr

                let nswCond expr
                     | nsw = do
                         as <- AtomExpr <$> mkAtom (App (BVSext w' w a))
                         bs <- AtomExpr <$> mkAtom (App (BVSext w' w b))
                         wideprod <- AtomExpr <$> mkAtom (App (BVMul w' as bs))
                         prods <- AtomExpr <$> mkAtom (App (BVSext w' w prod))
                         return $ App $ AddSideCondition (BaseBVRepr w)
                                (App (BVEq w' wideprod prods))
                                "signed overflow on multiplication"
                                expr
                     | otherwise = return expr

                nuwCond =<< nswCond prod

             L.UDiv exact -> do
                let z = App (BVLit w 0)
                assertExpr (notExpr (App (BVEq w z b)))
                           (litExpr "unsigned division-by-0")

                q <- AtomExpr <$> mkAtom (App (BVUdiv w a b))

                let exactCond expr
                     | exact = do
                         m <- AtomExpr <$> mkAtom (App (BVMul w q b))
                         return $ App $ AddSideCondition (BaseBVRepr w)
                                (App (BVEq w a m))
                                "inexact result of unsigned division"
                                expr
                     | otherwise = return expr

                exactCond q

             L.SDiv exact
               | Just LeqProof <- isPosNat w -> do
                  let z      = App (BVLit w 0)
                  let neg1   = App (BVLit w (-1))
                  let minInt = App (BVLit w (minSigned w))
                  assertExpr (notExpr (App (BVEq w z b)))
                             (litExpr "signed division-by-0")
                  assertExpr (notExpr ((App (BVEq w neg1 b))
                                       .&&
                                       (App (BVEq w minInt a)) ))
                             (litExpr "signed division overflow (yes, really)")

                  q <- AtomExpr <$> mkAtom (App (BVSdiv w a b))

                  let exactCond expr
                       | exact = do
                           m <- AtomExpr <$> mkAtom (App (BVMul w q b))
                           return $ App $ AddSideCondition (BaseBVRepr w)
                                  (App (BVEq w a m))
                                  "inexact result of signed division"
                                  expr
                       | otherwise = return expr

                  exactCond q

               | otherwise -> fail "cannot take the signed quotient of a 0-width bitvector"

             L.URem -> do
                  let z = App (BVLit w 0)
                  assertExpr (notExpr (App (BVEq w z b)))
                             (litExpr "unsigned division-by-0 in urem")
                  return $ App (BVUrem w a b)

             L.SRem
               | Just LeqProof <- isPosNat w -> do
                  let z      = App (BVLit w 0)
                  let neg1   = App (BVLit w (-1))
                  let minInt = App (BVLit w (minSigned w))
                  assertExpr (notExpr (App (BVEq w z b)))
                             (litExpr "signed division-by-0 in srem")
                  assertExpr (notExpr ((App (BVEq w neg1 b))
                                       .&&
                                       (App (BVEq w minInt a)) ))
                             (litExpr "signed division overflow in srem (yes, really)")

                  return $ App (BVSrem w a b)

               | otherwise -> fail "cannot take the signed remainder of a 0-width bitvector"

             _ -> fail $ unwords ["unsupported integer arith operation", show op]

caseptr
  :: (1 <= w)
  => NatRepr w
  -> TypeRepr a
  -> (Expr (LLVM arch) s (BVType w) ->
      LLVMGenerator h s arch ret (Expr (LLVM arch) s a))
  -> (Expr (LLVM arch) s NatType -> Expr (LLVM arch) s (BVType w) ->
      LLVMGenerator h s arch ret (Expr (LLVM arch) s a))
  -> Expr (LLVM arch) s (LLVMPointerType w)
  -> LLVMGenerator h s arch ret (Expr (LLVM arch) s a)

caseptr w tpr bvCase ptrCase x =
  case x of
    PointerExpr _ blk off ->
      case asApp blk of
        Just (NatLit 0) -> bvCase off
        Just (NatLit _) -> ptrCase blk off
        _               -> ptrSwitch blk off

    _ -> do a_x <- forceEvaluation (app (UnrollRecursive knownRepr (Ctx.Empty :> BVRepr w) x))
            blk <- forceEvaluation (app (GetStruct a_x (Ctx.natIndex @0) NatRepr))
            off <- forceEvaluation (app (GetStruct a_x (Ctx.natIndex @1) (BVRepr w)))
            ptrSwitch blk off
  where
  ptrSwitch blk off =
    do let cond = (blk .== litExpr 0)
       c_label  <- newLambdaLabel' tpr
       bv_label <- defineBlockLabel (bvCase off >>= jumpToLambda c_label)
       ptr_label <- defineBlockLabel (ptrCase blk off >>= jumpToLambda c_label)
       continueLambda c_label (branch cond bv_label ptr_label)

intcmp :: (1 <= w)
    => NatRepr w
    -> L.ICmpOp
    -> Expr (LLVM arch) s (BVType w)
    -> Expr (LLVM arch) s (BVType w)
    -> Expr (LLVM arch) s BoolType
intcmp w op a b =
   case op of
      L.Ieq  -> App (BVEq w a b)
      L.Ine  -> App (Not (App (BVEq w a b)))
      L.Iult -> App (BVUlt w a b)
      L.Iule -> App (BVUle w a b)
      L.Iugt -> App (BVUlt w b a)
      L.Iuge -> App (BVUle w b a)
      L.Islt -> App (BVSlt w a b)
      L.Isle -> App (BVSle w a b)
      L.Isgt -> App (BVSlt w b a)
      L.Isge -> App (BVSle w b a)

pointerCmp
   :: wptr ~ ArchWidth arch
   => L.ICmpOp
   -> Expr (LLVM arch) s (LLVMPointerType wptr)
   -> Expr (LLVM arch) s (LLVMPointerType wptr)
   -> LLVMGenerator h s arch ret (Expr (LLVM arch) s BoolType)
pointerCmp op x y =
  caseptr PtrWidth knownRepr
    (\x_bv ->
      caseptr PtrWidth knownRepr
        (\y_bv   -> return $ intcmp PtrWidth op x_bv y_bv)
        (\_ _ -> ptr_bv_compare x_bv y)
        y)
    (\_ _ ->
      caseptr PtrWidth knownRepr
        (\y_bv   -> ptr_bv_compare y_bv x)
        (\_ _    -> ptrOp)
        y)
    x
 where

  -- Special case: a pointer can be compared for equality with an integer, as long as
  -- that integer is 0, representing the null pointer.
  ptr_bv_compare bv ptr =
    do assertExpr (App (BVEq PtrWidth bv (App (BVLit PtrWidth 0))))
                  "Attempted to compare a pointer to a non-0 integer value"
       case op of
         L.Ieq  -> do
            res <- callIsNull PtrWidth ptr
            return res
         L.Ine  -> do
            res <- callIsNull PtrWidth ptr
            return (App (Not res))
         _ -> reportError $ litExpr $ Text.pack $ unwords ["arithmetic comparison on incompatible values", show op, show x, show y]

  ptrOp =
    do memVar <- getMemVar
       case op of
         L.Ieq -> do
           isEq <- extensionStmt (LLVM_PtrEq memVar x y)
           return $ isEq
         L.Ine -> do
           isEq <- extensionStmt (LLVM_PtrEq memVar x y)
           return $ App (Not isEq)
         L.Iule -> do
           isLe <- extensionStmt (LLVM_PtrLe memVar x y)
           return $ isLe
         L.Iult -> do
           isGe <- extensionStmt (LLVM_PtrLe memVar y x)
           return $ App (Not isGe)
         L.Iuge -> do
           isGe <- extensionStmt (LLVM_PtrLe memVar y x)
           return $ isGe
         L.Iugt -> do
           isLe <- extensionStmt (LLVM_PtrLe memVar x y)
           return $ App (Not isLe)
         _ -> reportError $ litExpr $ Text.pack $ unwords ["signed comparison on pointer values", show op, show x, show y]

pointerOp
   :: wptr ~ ArchWidth arch
   => L.ArithOp
   -> Expr (LLVM arch) s (LLVMPointerType wptr)
   -> Expr (LLVM arch) s (LLVMPointerType wptr)
   -> LLVMGenerator h s arch ret (Expr (LLVM arch) s (LLVMPointerType wptr))
pointerOp op x y =
  caseptr PtrWidth PtrRepr
    (\x_bv  ->
      caseptr PtrWidth PtrRepr
        (\y_bv  -> BitvectorAsPointerExpr PtrWidth <$> intop op PtrWidth x_bv y_bv)
        (\_ _   -> bv_ptr_op x_bv)
        y)
    (\_ _ ->
      caseptr PtrWidth PtrRepr
        (\y_bv  -> ptr_bv_op y_bv)
        (\_ _   -> ptr_ptr_op)
      y)
    x
 where
  ptr_bv_op y_bv =
    case op of
      L.Add _ _ ->
           callPtrAddOffset x y_bv
      L.Sub _ _ ->
        do let off = App (BVSub PtrWidth (App $ BVLit PtrWidth 0) y_bv)
           callPtrAddOffset x off
      _ -> err

  bv_ptr_op x_bv =
    case op of
      L.Add _ _ -> callPtrAddOffset y x_bv
      _ -> err

  ptr_ptr_op =
    case op of
      L.Sub _ _ -> BitvectorAsPointerExpr PtrWidth <$> callPtrSubtract x y
      _ -> err

  err = reportError $ litExpr $ Text.pack $ unwords ["Invalid pointer operation", show op, show x, show y]


-- | Do the heavy lifting of translating LLVM instructions to crucible code.
generateInstr :: forall h s arch ret a
         . TypeRepr ret     -- ^ Type of the function return value
        -> L.BlockLabel     -- ^ The label of the current LLVM basic block
        -> L.Instr          -- ^ The instruction to translate
        -> (LLVMExpr s arch -> LLVMGenerator h s arch ret ())
                            -- ^ A continuation to assign the produced value of this instruction to a register
        -> LLVMGenerator h s arch ret a  -- ^ A continuation for translating the remaining statements in this function.
                                   --   Straightline instructions should enter this continuation,
                                   --   but block-terminating instructions should not.
        -> LLVMGenerator h s arch ret a
generateInstr retType lab instr assign_f k =
  case instr of
    -- skip phi instructions, they are handled in definePhiBlock
    L.Phi _ _ -> k
    L.Comment _ -> k
    L.Unreachable -> reportError "LLVM unreachable code"

    L.ExtractValue x is -> do
        x' <- transTypedValue x
        v <- extractValue x' is
        assign_f v
        k

    L.InsertValue x v is -> do
        x' <- transTypedValue x
        v' <- transTypedValue v
        y <- insertValue x' v' is
        assign_f y
        k

    L.ExtractElt x i ->
        case x of
          L.Typed (L.Vector n ty) x' -> do
            ty' <- liftMemType' ty
            x'' <- transValue (VecType (fromIntegral n) ty') x'
            i'  <- transValue (IntType 64) i               -- FIXME? this is a bit of a hack, since the llvm-pretty
                                                           -- AST doesn't track the size of the index value
            y <- extractElt instr ty' (fromIntegral n) x'' i'
            assign_f y
            k

          _ -> fail $ unwords ["expected vector type in extractelement instruction:", show x]

    L.InsertElt x v i ->
        case x of
          L.Typed (L.Vector n ty) x' -> do
            ty' <- liftMemType' ty
            x'' <- transValue (VecType (fromIntegral n) ty') x'
            v'  <- transTypedValue v
            i'  <- transValue (IntType 64) i                -- FIXME? this is a bit of a hack, since the llvm-pretty
                                                            -- AST doesn't track the size of the index value
            y <- insertElt instr ty' (fromIntegral n) x'' v' i'
            assign_f y
            k

          _ -> fail $ unwords ["expected vector type in insertelement instruction:", show x]

    L.ShuffleVector sV1 sV2 sIxes ->
      case (L.typedType sV1, L.typedType sIxes) of
        (L.Vector m ty, L.Vector n (L.PrimType (L.Integer 32))) ->
          do elTy <- liftMemType' ty
             let inL :: Num b => b
                 inL  = fromIntegral n
                 inV  = VecType inL elTy
                 outL :: Num b => b
                 outL = fromIntegral m

             Just v1 <- asVector <$> transValue inV (L.typedValue sV1)
             Just v2 <- asVector <$> transValue inV sV2
             Just is <- asVector <$> transValue (VecType outL (IntType 32)) (L.typedValue sIxes)

             let getV x =
                   case asScalar x of
                     Scalar _ (App (BVLit _ i))
                       | i < 0     -> UndefExpr elTy
                       | i < inL   -> Seq.index v1 (fromIntegral i)
                       | i < 2*inL -> Seq.index v2 (fromIntegral (i - inL))

                     _ -> UndefExpr elTy

             assign_f (VecExpr elTy (getV <$> is))
             k

        (t1,t2) -> fail $ unlines ["[shuffle] Type error", show t1, show t2 ]


    L.LandingPad _ _ _ _ ->
      reportError "FIXME landingPad not implemented"

    L.Alloca tp num _align -> do
      -- ?? FIXME assert that the alignment value is appropriate...
      tp' <- liftMemType' tp
      let dl = llvmDataLayout ?lc
      let tp_sz = memTypeSize dl tp'
      let tp_sz' = app $ BVLit PtrWidth $ G.bytesToInteger tp_sz
      sz <- case num of
               Nothing -> return $ tp_sz'
               Just num' -> do
                  n <- transTypedValue num'
                  case n of
                     ZeroExpr _ -> return $ app $ BVLit PtrWidth 0
                     BaseExpr (LLVMPointerRepr w) x
                        | Just Refl <- testEquality w PtrWidth ->
                            do x' <- pointerAsBitvectorExpr w x
                               return $ app $ BVMul PtrWidth x' tp_sz'
                     _ -> fail $ "Invalid alloca argument: " ++ show num
      p <- callAlloca sz
      assign_f (BaseExpr (LLVMPointerRepr PtrWidth) p)
      k

    L.Load ptr _atomic align -> do
      tp'  <- liftMemType' (L.typedType ptr)
      ptr' <- transValue tp' (L.typedValue ptr)
      case tp' of
        PtrType (MemType resTy) ->
          llvmTypeAsRepr resTy $ \expectTy -> do
            let a0 = memTypeAlign (llvmDataLayout ?lc) resTy
            let align' = fromMaybe a0 (toAlignment . G.toBytes =<< align)
            res <- callLoad resTy expectTy ptr' align'
            assign_f res
            k
        _ ->
          fail $ unwords ["Invalid argument type on load", show ptr]

    L.Store v ptr align -> do
      tp'  <- liftMemType' (L.typedType ptr)
      ptr' <- transValue tp' (L.typedValue ptr)
      case tp' of
        PtrType (MemType resTy) ->
          do let a0 = memTypeAlign (llvmDataLayout ?lc) resTy
             let align' = fromMaybe a0 (toAlignment . G.toBytes =<< align)

             vTp <- liftMemType' (L.typedType v)
             v' <- transValue vTp (L.typedValue v)
             unless (resTy == vTp)
                (fail "Pointer type does not match value type in store instruction")
             callStore vTp ptr' v' align'
             k
        _ ->
          fail $ unwords ["Invalid argument type on store", show ptr]

    -- NB We treat every GEP as though it has the "inbounds" flag set;
    --    thus, the calculation of out-of-bounds pointers results in
    --    a runtime error.
    L.GEP inbounds base elts -> do
      runExceptT (translateGEP inbounds base elts) >>= \case
        Left err -> reportError $ fromString $ unlines ["Error translating GEP", err]
        Right gep ->
          do gep' <- traverse transTypedValue gep
             assign_f =<< evalGEP instr gep'
             k

    L.Conv op x outty -> do
      v <- translateConversion instr op x outty
      assign_f v
      k

    L.Call _tailCall (L.PtrTo fnTy) fn args ->
        callFunctionWithCont fnTy fn args assign_f k

    L.Invoke fnTy fn args normLabel _unwindLabel -> do
        callFunctionWithCont fnTy fn args assign_f $ definePhiBlock lab normLabel

    L.Bit op x y -> do
           let bitop :: (1 <= w)
                     => NatRepr w
                     -> Expr (LLVM arch) s (BVType w)
                     -> Expr (LLVM arch) s (BVType w)
                     -> LLVMGenerator h s arch ret (Expr (LLVM arch) s (BVType w))
               bitop w a b =
                     case op of
                         L.And -> return $ App (BVAnd w a b)
                         L.Or  -> return $ App (BVOr w a b)
                         L.Xor -> return $ App (BVXor w a b)

                         L.Shl nuw nsw -> do
                           let wlit = App (BVLit w (natValue w))
                           assertExpr (App (BVUlt w b wlit))
                                      (litExpr "shift amount too large in shl")

                           res <- AtomExpr <$> mkAtom (App (BVShl w a b))

                           let nuwCond expr
                                | nuw = do
                                    m <- AtomExpr <$> mkAtom (App (BVLshr w res b))
                                    return $ App $ AddSideCondition (BaseBVRepr w)
                                       (App (BVEq w a m))
                                       "unsigned overflow on shl"
                                       expr
                                | otherwise = return expr

                           let nswCond expr
                                | nsw = do
                                    m <- AtomExpr <$> mkAtom (App (BVAshr w res b))
                                    return $ App $ AddSideCondition (BaseBVRepr w)
                                       (App (BVEq w a m))
                                       "signed overflow on shl"
                                       expr
                                | otherwise = return expr

                           nuwCond =<< nswCond =<< return res

                         L.Lshr exact -> do
                           let wlit = App (BVLit w (natValue w))
                           assertExpr (App (BVUlt w b wlit))
                                      (litExpr "shift amount too large in lshr")

                           res <- AtomExpr <$> mkAtom (App (BVLshr w a b))

                           let exactCond expr
                                | exact = do
                                    m <- AtomExpr <$> mkAtom (App (BVShl w res b))
                                    return $ App $ AddSideCondition (BaseBVRepr w)
                                       (App (BVEq w a m))
                                       "inexact logical right shift"
                                       expr
                                | otherwise = return expr

                           exactCond res

                         L.Ashr exact
                           | Just LeqProof <- isPosNat w -> do
                              let wlit = App (BVLit w (natValue w))
                              assertExpr (App (BVUlt w b wlit))
                                         (litExpr "shift amount too large in ashr")

                              res <- AtomExpr <$> mkAtom (App (BVAshr w a b))

                              let exactCond expr
                                   | exact = do
                                       m <- AtomExpr <$> mkAtom (App (BVShl w res b))
                                       return $ App $ AddSideCondition (BaseBVRepr w)
                                          (App (BVEq w a m))
                                          "inexact arithmetic right shift"
                                          expr
                                   | otherwise = return expr

                              exactCond res

                           | otherwise -> fail "cannot arithmetic right shift a 0-width integer"

           x' <- transTypedValue x
           y' <- transTypedValue (L.Typed (L.typedType x) y)
           case (asScalar x', asScalar y') of
             (Scalar (LLVMPointerRepr w) x'',
              Scalar (LLVMPointerRepr w') y'')
               | Just Refl <- testEquality w w'
               , Just LeqProof <- isPosNat w -> do
                  xbv <- pointerAsBitvectorExpr w x''
                  ybv <- pointerAsBitvectorExpr w y''
                  ex  <- bitop w xbv ybv
                  assign_f (BaseExpr (LLVMPointerRepr w) (BitvectorAsPointerExpr w ex))
                  k

             _ -> fail $ unwords ["bitwise operation on unsupported values", show x, show y]

    L.Arith op x y ->
      do x' <- transTypedValue x
         y' <- transTypedValue (L.Typed (L.typedType x) y)
         assign_f =<< arithOp op x' y'
         k

    L.FCmp op x y -> do
           let isNaNCond = App . FloatIsNaN
           let cmpf :: Expr (LLVM arch) s (FloatType fi)
                    -> Expr (LLVM arch) s (FloatType fi)
                    -> Expr (LLVM arch) s BoolType
               cmpf a b =
                  -- True if a is NAN or b is NAN
                  let unoCond = App $ Or (isNaNCond a) (isNaNCond b) in
                  let mkUno c = App $ Or c unoCond in
                  case op of
                    L.Ftrue  -> App $ BoolLit True
                    L.Ffalse -> App $ BoolLit False
                    L.Foeq   -> App $ FloatFpEq a b
                    L.Folt   -> App $ FloatLt a b
                    L.Fole   -> App $ FloatLe a b
                    L.Fogt   -> App $ FloatGt a b
                    L.Foge   -> App $ FloatGe a b
                    L.Fone   -> App $ FloatFpNe a b
                    L.Fueq   -> mkUno $ App $ FloatFpEq a b
                    L.Fult   -> mkUno $ App $ FloatLt a b
                    L.Fule   -> mkUno $ App $ FloatLe a b
                    L.Fugt   -> mkUno $ App $ FloatGt a b
                    L.Fuge   -> mkUno $ App $ FloatGe a b
                    L.Fune   -> mkUno $ App $ FloatFpNe a b
                    L.Ford   -> App $ And (App $ Not $ isNaNCond a) (App $ Not $ isNaNCond b)
                    L.Funo   -> unoCond

           x' <- transTypedValue x
           y' <- transTypedValue (L.Typed (L.typedType x) y)
           case (asScalar x', asScalar y') of
             (Scalar (FloatRepr fi) x'',
              Scalar (FloatRepr fi') y'')
              | Just Refl <- testEquality fi fi' ->
                do assign_f (BaseExpr (LLVMPointerRepr (knownNat :: NatRepr 1))
                                   (BitvectorAsPointerExpr knownNat (App (BoolToBV knownNat (cmpf  x'' y'')))))
                   k

             _ -> fail $ unwords ["Floating point comparison on incompatible values", show x, show y]

    L.ICmp op x y -> do
           x' <- transTypedValue x
           y' <- transTypedValue (L.Typed (L.typedType x) y)
           case (asScalar x', asScalar y') of
             (Scalar (LLVMPointerRepr w) x'', Scalar (LLVMPointerRepr w') y'')
                | Just Refl <- testEquality w w'
                , Just Refl <- testEquality w PtrWidth
                -> do b <- pointerCmp op x'' y''
                      assign_f (BaseExpr (LLVMPointerRepr (knownNat :: NatRepr 1))
                                         (BitvectorAsPointerExpr knownNat (App (BoolToBV knownNat b))))
                      k
                | Just Refl <- testEquality w w'
                -> do xbv <- pointerAsBitvectorExpr w x''
                      ybv <- pointerAsBitvectorExpr w y''
                      let b = intcmp w op xbv ybv
                      assign_f (BaseExpr (LLVMPointerRepr (knownNat :: NatRepr 1))
                                         (BitvectorAsPointerExpr knownNat (App (BoolToBV knownNat b))))
                      k

             _ -> fail $ unwords ["arithmetic comparison on incompatible values", show x, show y]

    L.Select c x y -> do
         c' <- transTypedValue c
         x' <- transTypedValue x
         y' <- transTypedValue (L.Typed (L.typedType x) y)
         e' <- case asScalar c' of
                 Scalar (LLVMPointerRepr w) e -> notExpr <$> callIsNull w e
                 _ -> fail "expected boolean condition on select"

         ifte_ e' (assign_f x') (assign_f y')
         k

    L.Jump l' -> definePhiBlock lab l'

    L.Br v l1 l2 -> do
        v' <- transTypedValue v
        e' <- case asScalar v' of
                 Scalar (LLVMPointerRepr w) e -> notExpr <$> callIsNull w e
                 _ -> fail "expected boolean condition on branch"

        phi1 <- defineBlockLabel (definePhiBlock lab l1)
        phi2 <- defineBlockLabel (definePhiBlock lab l2)
        branch e' phi1 phi2

    L.Switch x def branches -> do
        x' <- transTypedValue x
        case asScalar x' of
          Scalar (LLVMPointerRepr w) x'' ->
            do bv <- pointerAsBitvectorExpr w x''
               buildSwitch w bv lab def branches
          _ -> fail $ unwords ["expected integer value in switch", showInstr instr]

    L.Ret v -> do v' <- transTypedValue v
                  let ?err = fail
                  unpackOne v' $ \retType' ex ->
                     case testEquality retType retType' of
                        Just Refl -> do
                           callPopFrame
                           returnFromFunction ex
                        Nothing -> fail $ unwords ["unexpected return type", show retType, show retType']

    L.RetVoid -> case testEquality retType UnitRepr of
                    Just Refl -> do
                       callPopFrame
                       returnFromFunction (App EmptyApp)
                    Nothing -> fail $ unwords ["tried to void return from non-void function", show retType]

    _ -> reportError $ App $ TextLit $ Text.pack $ unwords ["unsupported instruction", showInstr instr]



arithOp :: L.ArithOp -> LLVMExpr s arch -> LLVMExpr s arch ->
         LLVMGenerator h s arch ret (LLVMExpr s arch)
arithOp op x y =
  case (asScalar x, asScalar y) of
    (Scalar ty@(LLVMPointerRepr w)  x',
     Scalar    (LLVMPointerRepr w') y')
      | Just Refl <- testEquality w PtrWidth
      , Just Refl <- testEquality w w' ->
        do z <- pointerOp op x' y'
           return (BaseExpr ty z)

      | Just Refl <- testEquality w w' ->
        do xbv <- pointerAsBitvectorExpr w x'
           ybv <- pointerAsBitvectorExpr w y'
           z   <- intop op w xbv ybv
           return (BaseExpr (LLVMPointerRepr w) (BitvectorAsPointerExpr w z))

    (Scalar (FloatRepr fi) x',
     Scalar (FloatRepr fi') y')
      | Just Refl <- testEquality fi fi' ->
        do ex <- fop fi x' y'
           return (BaseExpr (FloatRepr fi) ex)

    _ | Just (t,xs) <- asVectorWithType x
      , Just ys     <- asVector y ->
        VecExpr t <$> sequence (Seq.zipWith (arithOp op) xs ys)

    _ -> reportError
           $ fromString
           $ unwords ["arithmetic operation on unsupported values",
                         show x, show y]

  where
  fop :: (FloatInfoRepr fi) ->
         Expr (LLVM arch) s (FloatType fi) ->
         Expr (LLVM arch) s (FloatType fi) ->
         LLVMGenerator h s arch ret (Expr (LLVM arch) s (FloatType fi))
  fop fi a b =
    case op of
       L.FAdd ->
         return $ App $ FloatAdd fi RNE a b
       L.FSub ->
         return $ App $ FloatSub fi RNE a b
       L.FMul ->
         return $ App $ FloatMul fi RNE a b
       L.FDiv ->
         return $ App $ FloatDiv fi RNE a b
       L.FRem -> do
         return $ App $ FloatRem fi a b
       _ -> reportError
              $ fromString
              $ unwords [ "unsupported floating-point arith operation"
                        , show op, show x, show y
                        ]



callFunctionWithCont :: forall h s arch ret a.
                        L.Type -> L.Value -> [L.Typed L.Value]
                     -> (LLVMExpr s arch -> LLVMGenerator h s arch ret ())
                     -> LLVMGenerator h s arch ret a
                     -> LLVMGenerator h s arch ret a
callFunctionWithCont fnTy@(L.FunTy lretTy largTys varargs) fn args assign_f k
     -- Skip calls to debugging intrinsics.  We might want to support these in some way
     -- in the future.  However, they take metadata values as arguments, which
     -- would require some work to support.
     | L.ValSymbol nm <- fn
     , nm `elem` [ "llvm.dbg.declare"
                 , "llvm.dbg.value"
                 , "llvm.lifetime.start"
                 , "llvm.lifetime.end"
                 ] = k

     -- For varargs functions, any arguments beyond the ones found in the function
     -- declaration are gathered into a vector of 'ANY' type, which is then passed
     -- as an additional final argument to the underlying Crucible function.  The
     -- called function is expected to know the types of these additional arguments,
     -- which it can unpack from the ANY values when it knows those types.
     | varargs = do
           fnTy' <- liftMemType' (L.PtrTo fnTy)
           retTy' <- either fail return $ liftRetType lretTy
           fn' <- transValue fnTy' fn
           args' <- mapM transTypedValue args
           let ?err = fail
           let (mainArgs, varArgs) = splitAt (length largTys) args'
           let varArgs' = unpackVarArgs varArgs
           unpackArgs mainArgs $ \argTypes mainArgs' ->
            llvmRetTypeAsRepr retTy' $ \retTy ->
             case asScalar fn' of
                Scalar PtrRepr ptr ->
                  do memVar <- getMemVar
                     v <- extensionStmt (LLVM_LoadHandle memVar ptr (argTypes :> varArgsRepr) retTy)
                     ret <- call v (mainArgs' :> varArgs')
                     assign_f (BaseExpr retTy ret)
                     k
                _ -> fail $ unwords ["unsupported function value", show fn]

     -- Ordinary (non varargs) function call
     | otherwise = do
           fnTy' <- liftMemType' (L.PtrTo fnTy)
           retTy' <- either fail return $ liftRetType lretTy
           fn' <- transValue fnTy' fn
           args' <- mapM transTypedValue args
           let ?err = fail
           unpackArgs args' $ \argTypes args'' ->
            llvmRetTypeAsRepr retTy' $ \retTy ->
              case asScalar fn' of
                Scalar PtrRepr ptr ->
                  do memVar <- getMemVar
                     v <- extensionStmt (LLVM_LoadHandle memVar ptr argTypes retTy)
                     ret <- call v args''
                     assign_f (BaseExpr retTy ret)
                     k

                _ -> fail $ unwords ["unsupported function value", show fn]
callFunctionWithCont fnTy _fn _args _assign_f _k =
    reportError $ App $ TextLit $ Text.pack $ unwords ["unsupported function type", show fnTy]

-- | Build a switch statement by decomposing it into a linear sequence of branches.
--   FIXME? this could be more efficient if we sort the list and do binary search instead...
buildSwitch :: (1 <= w)
            => NatRepr w
            -> Expr (LLVM arch) s (BVType w) -- ^ The expression to switch on
            -> L.BlockLabel        -- ^ The label of the current basic block
            -> L.BlockLabel        -- ^ The label of the default basic block if no other branch applies
            -> [(Integer, L.BlockLabel)] -- ^ The switch labels
            -> LLVMGenerator h s arch ret a
buildSwitch _ _  curr_lab def [] =
   definePhiBlock curr_lab def
buildSwitch w ex curr_lab def ((i,l):bs) = do
   let test = App $ BVEq w ex $ App $ BVLit w i
   t_id <- newLabel
   f_id <- newLabel
   defineBlock t_id (definePhiBlock curr_lab l)
   defineBlock f_id (buildSwitch w ex curr_lab def bs)
   branch test t_id f_id

-- | Implement the phi-functions along the edge from one LLVM Basic block to another.
definePhiBlock :: L.BlockLabel      -- ^ The LLVM source basic block
               -> L.BlockLabel      -- ^ The LLVM target basic block
               -> LLVMGenerator h s arch ret a
definePhiBlock l l' = do
  bim <- use blockInfoMap
  case Map.lookup l' bim of
    Nothing -> fail $ unwords ["label not found in label map:", show l']
    Just bi' -> do
      -- Collect all the relevant phi functions to evaluate
      let phi_funcs = maybe [] toList $ Map.lookup l (block_phi_map bi')

      -- NOTE: We evaluate all the right-hand sides of the phi nodes BEFORE
      --   we assign the values to their associated registers.  This preserves
      --   the expected semantics that phi functions are evaluated in the context
      --   of the previous basic block, and prevents unintended register shadowing.
      --   Otherwise loop-carried dependencies will sometimes end up with the wrong
      --   values.
      phiVals <- mapM evalPhi phi_funcs
      mapM_ assignPhi phiVals

      -- Now jump to the target code block
      jump (block_label bi')

 where evalPhi (ident,tp,v) = do
           t_v <- transTypedValue (L.Typed tp v)
           return (ident,t_v)
       assignPhi (ident,t_v) = do
           assignLLVMReg ident t_v


-- | Assign a packed LLVM expression into the named LLVM register.
assignLLVMReg
        :: L.Ident
        -> LLVMExpr s arch
        -> LLVMGenerator h s arch ret ()
assignLLVMReg ident rhs = do
  st <- get
  let idMap = st^.identMap
  case Map.lookup ident idMap of
    Just (Left lhs) -> do
      doAssign lhs rhs
    Just (Right _) -> fail $ "internal: Value cannot be assigned to."
    Nothing  -> fail $ unwords ["register not found in register map:", show ident]

-- | Given a register and an expression shape, assign the expressions in the right-hand-side
--   into the register left-hand side.
doAssign :: forall h s arch ret.
      Some (Reg s)
   -> LLVMExpr s arch -- ^ the RHS values to assign
   -> LLVMGenerator h s arch ret ()
doAssign (Some r) (BaseExpr tpr ex) =
   case testEquality (typeOfReg r) tpr of
     Just Refl -> assignReg r ex
     Nothing -> reportError $ fromString $ unwords ["type mismatch when assigning register", show r, show (typeOfReg r) , show tpr]
doAssign (Some r) (StructExpr vs) = do
   let ?err = fail
   unpackArgs (map snd $ toList vs) $ \ctx asgn ->
     case testEquality (typeOfReg r) (StructRepr ctx) of
       Just Refl -> assignReg r (mkStruct ctx asgn)
       Nothing -> reportError $ fromString $ unwords ["type mismatch when assigning structure to register", show r, show (StructRepr ctx)]
doAssign (Some r) (ZeroExpr tp) = do
  let ?err = fail
  zeroExpand tp $ \(tpr :: TypeRepr t) (ex :: Expr (LLVM arch) s t) ->
    case testEquality (typeOfReg r) tpr of
      Just Refl -> assignReg r ex
      Nothing -> reportError $ fromString $ "type mismatch when assigning zero value"
doAssign (Some r) (UndefExpr tp) = do
  let ?err = fail
  undefExpand tp $ \(tpr :: TypeRepr t) (ex :: Expr (LLVM arch) s t) ->
    case testEquality (typeOfReg r) tpr of
      Just Refl -> assignReg r ex
      Nothing -> reportError $ fromString $ "type mismatch when assigning undef value"
doAssign (Some r) (VecExpr tp vs) = do
  let ?err = fail
  llvmTypeAsRepr tp $ \tpr ->
    unpackVec tpr (toList vs) $ \ex ->
      case testEquality (typeOfReg r) (VectorRepr tpr) of
        Just Refl -> assignReg r ex
        Nothing -> reportError $ fromString $ "type mismatch when assigning vector value"

