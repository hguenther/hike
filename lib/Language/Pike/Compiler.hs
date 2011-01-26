{-# LANGUAGE TupleSections, DoRec #-}
module Language.Pike.Compiler where

import Language.Pike.Syntax
import Language.Pike.CompileError
import Llvm
import qualified Data.ByteString.Char8 as BS
import Data.Maybe (mapMaybe,catMaybes)
import System.IO.Unsafe (unsafeInterleaveIO)
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Error
import Control.Monad.Reader
import Data.List (find)
import Data.Map as Map hiding (map,mapMaybe)
import qualified Data.Map as Map (mapMaybe,map)
import Data.Set as Set hiding (map)
import qualified Data.Set as Set

type Compiler a p = ErrorT [CompileError p] (StateT ([Integer],Stack) (WriterT [LlvmFunction] (Reader ClassMap))) a

type Resolver a p = WriterT [CompileError p] (StateT ([Integer],ClassMap) (Reader Stack)) a

data StackReference = Pointer RType
                    | Variable RType LlvmVar
                    | Function RType [RType]
                    | Class Integer
                    deriving (Show,Eq)

type Stack = [Map String (BS.ByteString,StackReference)]

type ClassMap = Map Integer (String,BS.ByteString,Map String (BS.ByteString,StackReference))

resolve :: [Definition p] -> Either [CompileError p] (Map String (BS.ByteString,StackReference),ClassMap)
resolve defs = let ((res,errs),(_,mp)) = runReader (runStateT (runWriterT (resolveBody defs)) ([0..],Map.empty)) []
               in case errs of
                 [] -> Right (res,mp)
                 _ -> Left errs

resolveType :: Type -> Resolver RType p
resolveType (TypeId name) = do
  st <- ask
  let (t,res) = case stackLookup' name st of
        Nothing -> ([LookupFailure name Nothing],undefined)
        Just (_,ref) -> case ref of
          Class n -> ([],TypeId n)
          _ -> ([NotAClass name],undefined)
  tell t
  return res
resolveType x = return $ fmap (const undefined) x -- This is a brutal hack

translateType :: Type -> Compiler RType p
translateType (TypeId name) = do
  (_,ref) <- stackLookup Nothing name
  case ref of
    Class n -> return (TypeId n)
    _ -> throwError [NotAClass name]
translateType x = return $ fmap (const undefined) x
    

resolveDef :: Definition p -> Resolver (Map String (BS.ByteString,StackReference)) p
resolveDef (Definition _ body _) = case body of
  VariableDef tp names -> do
    rtp <- resolveType tp
    return $ Map.fromList $ map (\name -> (name,(BS.pack name,Pointer rtp))) names
  ClassDef name args body -> do
    rec { rbody <- local (rbody:) $ resolveBody body }
    (uniq,mp) <- get
    put (tail uniq,Map.insert (head uniq) (name,BS.pack name,rbody) mp)
    return $ Map.singleton name (BS.pack name,Class (head uniq))
  FunctionDef name rtp args body -> do
    rtp' <- resolveType rtp
    targs <- mapM (\(_,tp) -> resolveType tp) args
    return $ Map.singleton name (BS.pack name,Function rtp' targs)
  Import _ -> return Map.empty

resolveBody :: [Definition p] -> Resolver (Map String (BS.ByteString,StackReference)) p
resolveBody [] = return Map.empty
resolveBody (def:defs) = do
  refs1 <- resolveDef def
  refs2 <- resolveBody defs
  return (Map.union refs1 refs2)

stackAlloc' :: String -> RType -> Stack -> Stack
stackAlloc' name tp []     = [Map.singleton name (BS.pack name,Pointer tp)]
stackAlloc' name tp (x:xs) = (Map.insert name (BS.pack name,Pointer tp) x):xs

stackAlloc :: String -> RType -> Compiler () p
stackAlloc name tp = modify $ \(uniq,st) -> (uniq,stackAlloc' name tp st)

stackLookup' :: ConstantIdentifier -> Stack -> Maybe (BS.ByteString,StackReference)
stackLookup' s [] = Nothing
stackLookup' s@(ConstId _ (name:_)) (x:xs) = case Map.lookup name x of
  Nothing -> stackLookup' s xs
  Just ref -> Just ref

stackLookup :: Maybe p -> ConstantIdentifier -> Compiler (BS.ByteString,StackReference) p
stackLookup pos s = do
  (_,st) <- get
  case stackLookup' s st of
    Nothing -> throwError [LookupFailure s pos]
    Just res -> return res

stackAdd :: Map String (BS.ByteString,StackReference) -> Compiler () p
stackAdd refs = modify $ \(uniq,st) -> (uniq,refs:st)

stackPush :: Compiler () p
stackPush = modify $ \(uniq,st) -> (uniq,Map.empty:st)

stackPop :: Compiler () p
stackPop = modify $ \(uniq,st) -> (uniq,tail st)

stackShadow :: Compiler a p -> Compiler a p
stackShadow comp = do
  (uniq,st) <- get
  put (uniq,[])
  res <- comp
  (nuniq,_) <- get
  put (nuniq,st)
  return res

stackPut :: String -> StackReference -> Compiler () p
stackPut name ref = do
  (uniq,st) <- get
  let nst = case st of
        [] -> [Map.singleton name (BS.pack (name++show (head uniq)),ref)]
        x:xs -> (Map.insert name (BS.pack (name++show (head uniq)),ref) x):xs
  put (tail uniq,nst)

stackDiff :: Stack -> Stack -> [Map String (StackReference,StackReference)]
stackDiff st1 st2 = reverse $ stackDiff' (reverse st1) (reverse st2)
  where
    stackDiff' :: Stack -> Stack -> [Map String (StackReference,StackReference)]
    stackDiff' (x:xs) (y:ys) = (Map.mapMaybe id $ 
                                Map.intersectionWith (\(_,l) (_,r) -> if l==r
                                                                      then Nothing
                                                                      else Just (l,r)) x y):(stackDiff' xs ys)
    stackDiff' [] ys = []
    stackDiff' xs [] = []

{-stackDiff :: Compiler a -> Compiler (a,[Map String (StackReference,StackReference)])
stackDiff comp = do
  (_,st1) <- get
  res <- comp
  (_,st2) <- get
  return (res,reverse $ stackDiff' (reverse st1) (reverse st2))-}

newLabel :: Compiler Integer p
newLabel = do
  (x:xs,st) <- get
  put (xs,st)
  return x

runCompiler :: ClassMap -> Compiler a p -> Either [CompileError p] a
runCompiler mp c = fst $ runReader (runWriterT $ evalStateT (runErrorT c) ([0..],[])) mp

mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM f xs = mapM f xs >>= return.catMaybes

typeCheck :: Expression p -> Maybe RType -> RType -> Compiler () p
typeCheck expr Nothing act = return ()
typeCheck expr (Just req@(TypeFunction TypeVoid args)) act@(TypeFunction _ eargs)
  | args == eargs = return ()
  | otherwise    = throwError [TypeMismatch expr act req]
typeCheck expr (Just req) act
  | req == act = return ()
  | otherwise = throwError [TypeMismatch expr act req]

compilePike :: [Definition p] -> Either [CompileError p] LlvmModule
compilePike defs = case resolve defs of
  Left errs -> Left errs
  Right (st,mp) -> runCompiler mp $ do
    ((f1,aliases),f2) <- listen $ do
      alias <- generateAliases
      stackAdd st
      funcs <- mapMaybeM (\(Definition mods x _) -> case x of
                             FunctionDef name ret args block -> compileFunction name ret args block >>= return.Just
                             _ -> return Nothing) defs
      stackPop
      return (funcs,alias)
    return $  LlvmModule { modComments = []
                         , modAliases = aliases
                         , modGlobals = []
                         , modFwdDecls = []
                         , modFuncs = f2++f1
                         }

generateAliases :: Compiler [LlvmAlias] p
generateAliases = do
  mp <- ask
  mapM (\(_,(cname,int_cname,body)) -> do
           struct <- mapMaybeM (\(_,(name,ref)) -> case ref of
                                   Pointer tp -> do
                                     rtp <- toLLVMType tp
                                     return $ Just rtp
                                   _ -> return Nothing
                               ) (Map.toList body)
           return (int_cname,LMStruct struct)
       ) (Map.toList mp)

compileFunction :: String -> Type -> [(String,Type)] -> [Pos Statement p] -> Compiler LlvmFunction p
compileFunction name ret args block = do
  ret_tp <- translateType ret
  rargs <- mapM (\(name,tp) -> do
                    rtp <- translateType tp
                    ltp <- toLLVMType rtp
                    return (name,rtp,ltp)) args
  decl <- genFuncDecl (BS.pack name) ret_tp [tp | (_,tp,_) <- rargs]
  stackAdd $ Map.fromList [(argn,(BS.pack argn,Variable argtp (LMNLocalVar (BS.pack argn) ltp))) | (argn,argtp,ltp) <- rargs]
  blks <- compileBody block ret_tp
  stackPop
  return $ LlvmFunction { funcDecl = decl
                        , funcArgs = [BS.pack name | (name,tp) <- args]
                        , funcAttrs = [GC "shadow-stack"]
                        , funcSect = Nothing
                        , funcBody = blks
                        }

genFuncDecl :: BS.ByteString -> RType -> [RType] -> Compiler LlvmFunctionDecl p
genFuncDecl name ret_tp args = do
  rret_tp <- toLLVMType ret_tp
  rargs <- mapM (\tp -> toLLVMType tp >>= return.(,[])) args
  return $ LlvmFunctionDecl { decName = name
                            , funcLinkage = External
                            , funcCc = CC_Fastcc
                            , decReturnType = rret_tp
                            , decVarargs = FixedArgs
                            , decParams = rargs
                            , funcAlign = Nothing
                            }

compileBody :: [Pos Statement p] -> RType -> Compiler [LlvmBlock] p
compileBody stmts rtp = do
  (blks,nrtp) <- compileStatements stmts [] Nothing (Just rtp)
  return $ readyBlocks blks

readyBlocks :: [LlvmBlock] -> [LlvmBlock]
readyBlocks = reverse.map (\blk -> blk { blockStmts = case blockStmts blk of
                                            [] -> [Unreachable]
                                            _ -> reverse (blockStmts blk) 
                                       })

appendStatements :: [LlvmStatement] -> [LlvmBlock] -> Compiler [LlvmBlock] p
appendStatements [] [] = return []
appendStatements stmts [] = do
  lbl <- newLabel
  return [LlvmBlock { blockLabel = LlvmBlockId lbl
                    , blockStmts = stmts
                    }]
appendStatements stmts (x:xs) = return $ x { blockStmts = stmts ++ (blockStmts x) }:xs

compileStatements :: [Pos Statement p] -> [LlvmBlock] -> Maybe Integer -> Maybe RType -> Compiler ([LlvmBlock],Maybe RType) p
compileStatements [] blks _ rtp = return (blks,rtp)
compileStatements ((Pos x pos):xs) blks brk rtp = do
  (stmts,nblks,nrtp) <- compileStatement pos x brk rtp
  nblks2 <- appendStatements stmts blks
  compileStatements xs (nblks ++ nblks2) brk nrtp

compileStatement :: p -> Statement p -> Maybe Integer -> Maybe RType -> Compiler ([LlvmStatement],[LlvmBlock],Maybe RType) p
compileStatement _ (StmtBlock stmts) brk rtp = do
  stackPush
  (blks,nrtp) <- compileStatements stmts [] brk rtp
  stackPop
  return ([],blks,nrtp)
compileStatement _ (StmtDecl name tp expr) _ rtp = do
  tp2 <- translateType tp
  --stackAlloc name tp2
  rtp' <- toLLVMType tp2
  case expr of
    Nothing -> do
      var <- defaultValue tp2
      stackPut name (Variable tp2 var)
      return ([],[],rtp)
    Just rexpr -> do
      (extra,res,_) <- compileExpression' "assignment" rexpr (Just tp2)
      stackPut name (Variable tp2 res)
      return (extra,[],rtp)
compileStatement _ st@(StmtReturn expr) _ rtp = case expr of
  Nothing -> case rtp of
    Nothing -> return ([Return Nothing],[],Just TypeVoid)
    Just rrtp
      | rrtp == TypeVoid -> return ([Return Nothing],[],Just TypeVoid)
      | otherwise -> throwError [WrongReturnType st TypeVoid rrtp]
  Just rexpr -> do
    (extra,res,rrtp) <- compileExpression' "return value" rexpr rtp
    return ([Return (Just res)]++extra,[],Just rrtp)
compileStatement _ (StmtWhile cond body) _ rtp = compileWhile cond body rtp Nothing
compileStatement pos (StmtFor e1 e2 e3 body) _ rtp = do
  (init_stmts,init_blks,nrtp) <- case e1 of
    Nothing -> return ([],[],rtp)
    Just r1 -> compileStatement pos (StmtExpr r1) Nothing rtp
  init_blks' <- appendStatements init_stmts init_blks
  let lbl_start = case init_blks' of
        [] -> Nothing
        (LlvmBlock (LlvmBlockId lbl) _:_) -> Just lbl
  (body_stmts,body_blks,nnrtp) <- compileWhile
                                  (case e2 of
                                      Nothing -> Pos (ExprInt 1) pos
                                      Just r2 -> r2)    
                                  (body++(case e3 of
                                             Nothing -> []
                                             Just r3 -> [Pos (StmtExpr r3) pos])) nrtp lbl_start
  return (body_stmts,body_blks++init_blks',nnrtp)
compileStatement _ (StmtIf expr (Pos ifTrue tpos) mel) brk rtp = do
  lblEnd <- newLabel
  (res,var,_) <- compileExpression' "condition" expr (Just TypeBool)
  stackPush
  (blksTrue,nrtp1) <- do
    (stmts,blks,nrtp) <- compileStatement tpos ifTrue brk rtp
    nblks <- appendStatements ([Branch (LMLocalVar lblEnd LMLabel)]++stmts) blks
    return (nblks,nrtp)
  stackPop
  (blksFalse,nrtp2) <- case mel of
    Nothing -> return ([],nrtp1)
    Just (Pos st stpos) -> do
      stackPush
      (blks,nrtp) <- do
        (stmts,blks,nnrtp) <- compileStatement stpos st brk nrtp1
        nblks <- appendStatements ([Branch (LMLocalVar lblEnd LMLabel)]++stmts) blks
        return (nblks,nnrtp)
      stackPop
      return (blks,nrtp)
  let lblTrue = case blksTrue of
        [] -> lblEnd
        _  -> let LlvmBlock { blockLabel = LlvmBlockId lbl } = last blksTrue in lbl
  let lblFalse = case blksFalse of
        [] -> lblEnd
        _  -> let LlvmBlock { blockLabel = LlvmBlockId lbl } = last blksFalse in lbl
  return ([BranchIf var (LMLocalVar lblTrue LMLabel) (LMLocalVar lblFalse LMLabel)] ++ res,
          [LlvmBlock
          { blockLabel = LlvmBlockId lblEnd
          , blockStmts = []
          }]++blksFalse++blksTrue,nrtp2)
compileStatement _ (StmtExpr expr) _ rtp = do
  (stmts,var,_) <- compileExpression' "statement expression" expr Nothing
  return (stmts,[],rtp)
compileStatement _ StmtBreak Nothing _ = error "Nothing to break to"
compileStatement _ StmtBreak (Just lbl) rtp = return ([Branch (LMLocalVar lbl LMLabel)],[],rtp)
compileStatement _ _ _ rtp = return ([Unreachable],[],rtp)

compileWhile :: Pos Expression p -> [Pos Statement p] -> Maybe RType -> Maybe Integer -> Compiler ([LlvmStatement],[LlvmBlock],Maybe RType) p
compileWhile cond body rtp mlbl_start = do
  lbl_start <- case mlbl_start of
    Just lbl -> return lbl
    Nothing -> newLabel
  lbl_test <- newLabel
  lbl_end <- newLabel
  wvars <- mapM (\(cid@(ConstId _ (wvar:_))) -> do
                    (_,Variable tp ref) <- stackLookup Nothing cid
                    lbl <- newLabel
                    rtp <- toLLVMType tp
                    stackPut wvar (Variable tp (LMLocalVar lbl rtp))
                    return (cid,tp,rtp,lbl,ref)
                ) (Set.toList (writes ((StmtExpr cond):(map posObj body))))
  (_,st) <- get
  (loop,nrtp) <- compileStatements body [] (Just lbl_end) rtp
  let (LlvmBlock (LlvmBlockId lbl_loop) _):_ = loop
  nloop <- appendStatements [Branch (LMLocalVar lbl_test LMLabel)] loop
  phis <- mapM (\(cid,tp,rtp,lbl,ref) -> do
                   (_,Variable _ nref) <- stackLookup Nothing cid
                   return (Assignment
                           (LMLocalVar lbl rtp)
                           (Phi rtp [(ref,LMLocalVar lbl_start LMLabel),
                                     (nref,LMLocalVar lbl_loop LMLabel)]))) wvars
  modify (\(uniq,_) -> (uniq,st))
  (test_stmts,test_var,_) <- compileExpression' "condition" cond (Just TypeBool)
  return (case mlbl_start of
             Nothing -> [Branch (LMLocalVar lbl_start LMLabel)]
             Just _ -> [],
          [LlvmBlock (LlvmBlockId lbl_end) []]++nloop++
          [LlvmBlock
           (LlvmBlockId lbl_test)
           ([BranchIf test_var (LMLocalVar lbl_loop LMLabel) (LMLocalVar lbl_end LMLabel)] ++ test_stmts ++ phis)
          ]++(case mlbl_start of
              Just _ -> []
              Nothing -> [LlvmBlock (LlvmBlockId lbl_start) [Branch (LMLocalVar lbl_test LMLabel)]])
          ,rtp)

data CompileExprResult
     = ResultCalc [LlvmStatement] LlvmVar RType
     | ResultClass Integer
     deriving Show

compileExpression' :: String -> Pos Expression p -> Maybe RType -> Compiler ([LlvmStatement],LlvmVar,RType) p
compileExpression' reason (Pos expr pos) rt = do
  res <- compileExpression pos expr rt
  case res of
    ResultCalc stmts var ret -> return (stmts,var,ret)
    ResultClass n -> do
      classmap <- ask
      let (name,_,_) = classmap!n
      throwError [MisuseOfClass reason name]

compileExpression :: p -> Expression p -> Maybe RType -> Compiler CompileExprResult p
compileExpression _ (ExprInt n) tp = case tp of
  Nothing -> do
    rtp <- toLLVMType TypeInt
    return $ ResultCalc [] (LMLitVar $ LMIntLit n rtp) TypeInt
  Just rtp -> case rtp of
    TypeInt -> return $ ResultCalc [] (LMLitVar $ LMIntLit n (LMInt 32)) TypeInt
    TypeFloat -> return $ ResultCalc [] (LMLitVar $ LMFloatLit (fromIntegral n) LMDouble) TypeFloat
    _ -> error $ "Ints can't have type "++show rtp
compileExpression pos e@(ExprId name) etp = do
  (n,ref) <- stackLookup (Just pos) name
  case ref of
    Variable tp var -> do
      typeCheck e etp tp
      return $ ResultCalc [] var tp
    Pointer tp -> do
      typeCheck e etp tp
      rtp <- toLLVMType tp
      lbl <- newLabel
      let tvar = LMLocalVar lbl rtp
      return $ ResultCalc [Assignment tvar (Load (LMNLocalVar n (LMPointer rtp)))] tvar tp
    Function tp args -> do
      typeCheck e etp (TypeFunction tp args)
      fdecl <- genFuncDecl n tp args
      return $ ResultCalc [] (LMGlobalVar n (LMFunction fdecl) External Nothing Nothing False) (TypeFunction tp args)
    Class n -> return $ ResultClass n
compileExpression pos e@(ExprAssign Assign lhs expr) etp = case lhs of
  LVId tid -> do
    (n,ref) <- stackLookup (Just pos) tid
    case ref of
      Variable tp var -> do
        typeCheck e etp tp
        (extra,res,_) <- compileExpression' "assignment" expr (Just tp)
        llvmtp <- toLLVMType tp
        let ConstId _ (name:_) = tid
        stackPut name (Variable tp res)
        return $ ResultCalc extra res tp
      Pointer ptp -> do
        typeCheck e etp ptp
        (extra,res,_) <- compileExpression' "assignment" expr (Just ptp)
        llvmtp <- toLLVMType ptp
        return $ ResultCalc ([Store res (LMNLocalVar n (LMPointer llvmtp))]++extra) res ptp
compileExpression _ e@(ExprBin op lexpr rexpr) etp = do
  (lextra,lres,tpl) <- compileExpression' "binary expressions" lexpr Nothing
  (rextra,rres,tpr) <- compileExpression' "binary expressions" rexpr (Just tpl)
  res <- newLabel
  case op of
    BinLess -> do
      typeCheck e etp TypeBool
      let resvar = LMLocalVar res (LMInt 1)
      return $ ResultCalc ([Assignment resvar (Compare LM_CMP_Slt lres rres)]++rextra++lextra) resvar TypeBool
    BinPlus -> do
      typeCheck e etp tpl
      llvmtp <- toLLVMType tpl
      let resvar = LMLocalVar res llvmtp
      return $ ResultCalc ([Assignment resvar (LlvmOp LM_MO_Add lres rres)]++rextra++lextra) resvar tpl
compileExpression _ e@(ExprCall (Pos expr rpos) args) etp = do
  res <- compileExpression rpos expr Nothing
  case res of
    ResultCalc eStmts eVar ftp -> case ftp of
      TypeFunction rtp argtp
          | (length argtp) == (length args) -> do
            rargs <- zipWithM (\arg tp -> compileExpression' "function argument" arg (Just tp)) args argtp
            res <- newLabel
            resvar <- toLLVMType rtp >>= return.(LMLocalVar res)
            return $ ResultCalc ([Assignment resvar (Call StdCall eVar [ v | (_,v,_) <- rargs ] [])]++(concat [stmts | (stmts,_,_) <- rargs])++eStmts) resvar rtp
          | otherwise -> throwError [WrongNumberOfArguments e (length  args) (length argtp)]
      _ -> throwError [NotAFunction e ftp]
    ResultClass n -> do
      classmap <- ask
      let (name,int_name,funcs) = classmap!n
      lbl <- newLabel
      let resvar = LMLocalVar lbl (LMPointer (LMAlias int_name))
      return $ ResultCalc [Assignment resvar (Malloc (LMAlias int_name) 1)] resvar (TypeId n)
compileExpression _ e@(ExprLambda args (Pos body body_pos)) etp = do
  fid <- newLabel
  let fname = BS.pack ("lambda"++show fid)
  rargs <- mapM (\(name,tp) -> do
                    tp' <- translateType tp
                    ltp <- toLLVMType tp'
                    return (name,tp',ltp)) args
  fdecl <- genFuncDecl fname TypeInt [ tp | (_,tp,_) <- rargs]
  let rtp = case etp of
        Just (TypeFunction r _) -> Just r
        _ -> Nothing
  (blks,nrtp) <- stackShadow $ do
    stackAdd $ Map.fromList [ (name,(BS.pack name,Variable tp (LMNLocalVar (BS.pack name) ltp))) | (name,tp,ltp) <- rargs ]
    (stmts,blks,rtp2) <- compileStatement body_pos body Nothing rtp
    nblks <- appendStatements stmts blks
    return (nblks,rtp2)
  tell $ [LlvmFunction { funcDecl = fdecl,
                         funcArgs = map (BS.pack . fst) args,
                         funcAttrs = [],
                         funcSect = Nothing,
                         funcBody = readyBlocks blks
                       }]
  let ftp = TypeFunction (case nrtp of
                             Nothing -> TypeVoid
                             Just tp -> tp) [tp | (_,tp,_) <- rargs]
  typeCheck e etp ftp
  return $ ResultCalc [] (LMGlobalVar fname (LMFunction fdecl) External Nothing Nothing False) ftp
compileExpression _ expr _ = error $ "Couldn't compile expression "++show expr


toLLVMType :: RType -> Compiler LlvmType p
toLLVMType TypeInt = return $ LMInt 32
toLLVMType TypeBool = return $ LMInt 1
toLLVMType (TypeId n) = do
  cls <- ask
  let (_,int_name,_) = cls!n
  return (LMAlias int_name)

defaultValue :: RType -> Compiler LlvmVar p
defaultValue TypeInt = return (LMLitVar (LMIntLit 0 (LMInt 32)))

writes :: [Statement p] -> Set ConstantIdentifier
writes xs = writes' xs Set.empty
  where
    writes' :: [Statement p] -> Set ConstantIdentifier -> Set ConstantIdentifier
    writes' [] s = s
    writes' (x:xs) s = writes' xs (writes'' x s)

    writes'' :: Statement p -> Set ConstantIdentifier -> Set ConstantIdentifier
    writes'' (StmtBlock stmts) s = writes' (map posObj stmts) s
    writes'' (StmtExpr expr) s = writes''' (posObj expr) s
    writes'' (StmtDecl name _ (Just expr)) s = writes''' (posObj expr) (Set.insert (ConstId False [name]) s)
    writes'' (StmtIf cond (Pos ifTrue _) ifFalse) s = writes''' (posObj cond) (writes'' ifTrue (case ifFalse of
                                                                                                   Nothing -> s
                                                                                                   Just (Pos e _) -> writes'' e s))
    writes'' (StmtReturn (Just expr)) s = writes''' (posObj expr) s
    writes'' (StmtFor init cond it body) s = let s1 = case init of
                                                   Nothing -> s
                                                   Just (Pos r1 _) -> writes''' r1 s
                                                 s2 = case cond of
                                                   Nothing -> s1
                                                   Just (Pos r2 _) -> writes''' r2 s1
                                                 s3 = case it of
                                                   Nothing -> s2
                                                   Just (Pos r3 _) -> writes''' r3 s2
                                             in writes' (map posObj body) s3
    writes'' _ s = s
    
    writes''' :: Expression p -> Set ConstantIdentifier -> Set ConstantIdentifier
    writes''' (ExprAssign _ lhs (Pos rhs _)) s = case lhs of
                                                      LVId tid -> writes''' rhs (Set.insert tid s)
                                                      _ -> writes''' rhs s
    writes''' (ExprCall cmd args) s = foldl (\s' e -> writes''' e s') s (map posObj (cmd:args))
    writes''' (ExprBin _ (Pos lhs _) (Pos rhs _)) s = writes''' rhs (writes''' lhs s)
    writes''' (ExprIndex (Pos lhs _) (Pos rhs _)) s = writes''' rhs (writes''' rhs s)
    writes''' (ExprLambda _ (Pos stmt _)) s = writes'' stmt s
    writes''' _ s = s
