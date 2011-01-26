module Language.Pike.Compiler where

import Language.Pike.Syntax
import Language.Pike.CompileError
import Llvm
import qualified Data.ByteString.Char8 as BS
import Data.Maybe (mapMaybe,catMaybes)
import System.IO.Unsafe (unsafeInterleaveIO)
import Data.Unique
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Error
import Data.List (find)

type Compiler a = ErrorT CompileError (StateT ([Unique],Stack) (Writer [LlvmFunction])) a

data StackReference = Pointer Type BS.ByteString
                    | Variable Type BS.ByteString
                    | Function Type [Type] BS.ByteString
                    deriving Show

type Stack = [[StackReference]]

initialStack :: [Definition] -> [StackReference]
initialStack [] = []
initialStack ((Definition _ body):xs)
    = case body of
        FunctionDef name tp args _ -> (Function tp [t | (_,t) <- args] (BS.pack name)):rest
        _ -> rest
    where
      rest = initialStack xs
                        

stackAlloc' :: String -> Type -> Stack -> Stack
stackAlloc' name tp []     = [[Pointer tp (BS.pack name)]]
stackAlloc' name tp (x:xs) = ((Pointer tp (BS.pack name)):x):xs

stackAlloc :: String -> Type -> Compiler ()
stackAlloc name tp = modify $ \(uniq,st) -> (uniq,stackAlloc' name tp st)

stackLookup' :: ConstantIdentifier -> Stack -> StackReference
stackLookup' s [] = error $ "Couldn't lookup "++show s
stackLookup' s@(ConstId _ (name:_)) (x:xs) = case find (\ref -> case ref of
                                                                 Pointer _ n -> n == BS.pack name
                                                                 Variable _ n -> n == BS.pack name
                                                                 Function _ _ n -> n == BS.pack name
                                                       ) x of
                                               Nothing -> stackLookup' s xs
                                               Just ref -> ref

stackLookup :: ConstantIdentifier -> Compiler StackReference
stackLookup s = do
  (_,st) <- get
  return $ stackLookup' s st

stackAdd :: [StackReference] -> Compiler ()
stackAdd refs = modify $ \(uniq,st) -> (uniq,refs:st)

stackPush :: Compiler ()
stackPush = modify $ \(uniq,st) -> (uniq,[]:st)

stackPop :: Compiler ()
stackPop = modify $ \(uniq,st) -> (uniq,tail st)

stackShadow :: Compiler a -> Compiler a
stackShadow comp = do
  (uniq,st) <- get
  put (uniq,[])
  res <- comp
  (nuniq,_) <- get
  put (nuniq,st)
  return res

newLabel :: Compiler Unique
newLabel = do
  (x:xs,st) <- get
  put (xs,st)
  return x

uniques :: IO [Unique]
uniques = do
  x <- newUnique
  xs <- unsafeInterleaveIO uniques
  return $ x:xs

runCompiler :: Compiler a -> IO (Either CompileError a)
runCompiler c = do
  uniq <- uniques
  return $ fst $ runWriter $ evalStateT (runErrorT c) (uniq,[])

mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM f xs = mapM f xs >>= return.catMaybes

typeCheck :: Expression -> Maybe Type -> Type -> Compiler ()
typeCheck expr Nothing act = return ()
typeCheck expr (Just req@(TypeFunction TypeVoid args)) act@(TypeFunction _ eargs)
  | args == eargs = return ()
  | otherwise    = throwError (TypeMismatch expr act req)
typeCheck expr (Just req) act
  | req == act = return ()
  | otherwise = throwError (TypeMismatch expr act req)

compilePike :: [Definition] -> Compiler LlvmModule
compilePike defs = do
  (f1,f2) <- listen $ do
    stackAdd (initialStack defs)
    funcs <- mapMaybeM (\(Definition mods x) -> case x of
                           FunctionDef name ret args block -> compileFunction name ret args block >>= return.Just
                           _ -> return Nothing) defs
    stackPop
    return funcs
  return $  LlvmModule
             { modComments = []
             , modAliases = []
             , modGlobals = []
             , modFwdDecls = []
             , modFuncs = f2++f1
             }

compileFunction :: String -> Type -> [(String,Type)] -> [Statement] -> Compiler LlvmFunction
compileFunction name ret args block = let decl = genFuncDecl (BS.pack name) ret (map snd args)
                                      in do
                                        stackPush
                                        stackAdd [Variable argtp (BS.pack argn) | (argn,argtp) <- args]
                                        blks <- compileBody block
                                        stackPop
                                        return $ LlvmFunction
                                             { funcDecl = decl
                                             , funcArgs = [BS.pack name | (name,tp) <- args]
                                             , funcAttrs = []
                                             , funcSect = Nothing
                                             , funcBody = blks
                                             }

genFuncDecl :: BS.ByteString -> Type -> [Type] -> LlvmFunctionDecl
genFuncDecl name ret_tp args = LlvmFunctionDecl
                               { decName = name
                               , funcLinkage = External
                               , funcCc = CC_Fastcc
                               , decReturnType = toLLVMType ret_tp
                               , decVarargs = FixedArgs
                               , decParams = map (\arg -> (toLLVMType arg,[])) args
                               , funcAlign = Nothing
                               }

compileBody :: [Statement] -> Compiler [LlvmBlock]
compileBody stmts = do
  blks <- compileStatements stmts [] Nothing
  return $ readyBlocks blks

readyBlocks :: [LlvmBlock] -> [LlvmBlock]
readyBlocks = reverse.map (\blk -> blk { blockStmts = reverse (blockStmts blk) })

appendStatements :: [LlvmStatement] -> [LlvmBlock] -> Compiler [LlvmBlock]
appendStatements stmts [] = do
  lbl <- newLabel
  return [LlvmBlock { blockLabel = LlvmBlockId lbl
                    , blockStmts = stmts
                    }]
appendStatements stmts (x:xs) = return $ x { blockStmts = stmts ++ (blockStmts x) }:xs

compileStatements :: [Statement] -> [LlvmBlock] -> Maybe Unique -> Compiler [LlvmBlock]
compileStatements [] blks _ = return blks
compileStatements (x:xs) blks brk = do
  (stmts,nblks) <- compileStatement x brk
  nblks2 <- appendStatements stmts blks
  compileStatements xs (nblks ++ nblks2) brk

compileStatement :: Statement -> Maybe Unique -> Compiler ([LlvmStatement],[LlvmBlock])
compileStatement (StmtBlock stmts) brk = do
  stackPush
  blks <- compileStatements stmts [] brk
  stackPop
  return ([],blks)
compileStatement (StmtDecl name tp expr) _ = do
  stackAlloc name tp
  let rtp = toLLVMType tp
  let tvar = LMNLocalVar (BS.pack name) (LMPointer rtp)
  let alloc = Assignment tvar (Alloca rtp 1)
  case expr of
    Nothing -> return ([alloc],[])
    Just rexpr -> do
              (extra,res,_) <- compileExpression rexpr (Just tp)
              lbl <- newLabel
              return ([Store res tvar,alloc]++extra,[])
compileStatement (StmtReturn expr) _ = case expr of
                                       Nothing -> return ([Return Nothing],[])
                                       Just rexpr -> do
                                                 (extra,res,_) <- compileExpression rexpr Nothing
                                                 return ([Return (Just res)]++extra,[])
compileStatement (StmtFor e1 e2 e3 body) _ = do
  begin <- case e1 of
            Nothing -> return []
            Just re1 -> do
                    (res,_,_) <- compileExpression re1 Nothing
                    return res
  it <- case e3 of
    Nothing -> return []
    Just re3 -> do
      (res,_,_) <- compileExpression re3 Nothing
      return res
  lbl_cont <- newLabel
  lbl_end <- newLabel
  stackPush
  body_blks' <- compileStatements body [] (Just lbl_end)
  stackPop
  body_blks <- appendStatements ((Branch (LMLocalVar lbl_cont LMLabel):it)) body_blks'
  let LlvmBlock { blockLabel = LlvmBlockId lbl_next } = last body_blks
  sw <- case e2 of
         Nothing -> return Nothing
         Just re2 -> compileExpression re2 (Just TypeBool) >>= return.Just
  let sw_stmt = case sw of
        Nothing -> []
        Just (stmts,res,_) -> [BranchIf res (LMLocalVar lbl_next LMLabel) (LMLocalVar lbl_end LMLabel)]++stmts
  return ([Branch (LMLocalVar lbl_cont LMLabel)]++begin,[LlvmBlock (LlvmBlockId lbl_end) []]++body_blks++[LlvmBlock (LlvmBlockId lbl_cont) sw_stmt])
compileStatement (StmtIf expr ifTrue mel) brk = do
  lblEnd <- newLabel
  (res,var,_) <- compileExpression expr (Just TypeBool)
  stackPush
  blksTrue <- compileStatement ifTrue brk
              >>= uncurry appendStatements
              >>= appendStatements [Branch (LMLocalVar lblEnd LMLabel)]
  stackPop
  blksFalse <- case mel of
    Nothing -> return []
    Just st -> do
      stackPush
      blks <- compileStatement st brk
              >>= uncurry appendStatements
              >>= appendStatements [Branch (LMLocalVar lblEnd LMLabel)]
      stackPop
      return blks
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
          }]++blksFalse++blksTrue)
compileStatement (StmtExpr expr) _ = do
  (stmts,var,_) <- compileExpression expr Nothing
  return (stmts,[])
compileStatement StmtBreak Nothing = error "Nothing to break to"
compileStatement StmtBreak (Just lbl) = return ([Branch (LMLocalVar lbl LMLabel)],[])
compileStatement _ _ = return ([Unreachable],[])

compileExpression :: Expression -> Maybe Type -> Compiler ([LlvmStatement],LlvmVar,Type)
compileExpression (ExprInt n) tp = case tp of
  Nothing -> return ([],LMLitVar $ LMIntLit n (toLLVMType TypeInt),TypeInt)
  Just rtp -> case rtp of
    TypeInt -> return ([],LMLitVar $ LMIntLit n (LMInt 32),TypeInt)
    TypeFloat -> return ([],LMLitVar $ LMFloatLit (fromIntegral n) LMDouble,TypeFloat)
    _ -> error $ "Ints can't have type "++show rtp
compileExpression e@(ExprId name) etp = do
  ref <- stackLookup name
  case ref of
    Variable tp n -> do
      typeCheck e etp tp
      return ([],LMNLocalVar n (toLLVMType tp),tp)
    Pointer tp n -> do
      typeCheck e etp tp
      let rtp = toLLVMType tp
      lbl <- newLabel
      let tvar = LMLocalVar lbl rtp
      return ([Assignment tvar (Load (LMNLocalVar n (LMPointer rtp)))],tvar,tp)
    Function tp args n -> do
      typeCheck e etp (TypeFunction tp args)
      return ([],LMGlobalVar n (LMFunction (genFuncDecl n tp args)) External Nothing Nothing False,TypeFunction tp args)
compileExpression e@(ExprAssign Assign tid expr) etp = do
  ref <- stackLookup tid
  case ref of
    Variable tp n -> error "Please don't assign to function arguments yet..."
    Pointer ptp n -> do
      typeCheck e etp ptp
      (extra,res,_) <- compileExpression expr (Just ptp)
      return ([Store res (LMNLocalVar n (LMPointer (toLLVMType ptp)))]++extra,res,ptp)
compileExpression e@(ExprBin op lexpr rexpr) etp = do
  (lextra,lres,tpl) <- compileExpression lexpr Nothing
  (rextra,rres,tpr) <- compileExpression rexpr (Just tpl)
  res <- newLabel
  case op of
    BinLess -> do
      typeCheck e etp TypeBool
      let resvar = LMLocalVar res (LMInt 1)
      return ([Assignment resvar (Compare LM_CMP_Slt lres rres)]++rextra++lextra,resvar,TypeBool)
    BinPlus -> do
      typeCheck e etp tpl
      let resvar = LMLocalVar res (toLLVMType tpl)
      return ([Assignment resvar (LlvmOp LM_MO_Add lres rres)]++rextra++lextra,resvar,tpl)
compileExpression e@(ExprCall expr args) etp = do
  (eStmts,eVar,ftp) <- compileExpression expr Nothing
  case ftp of
    TypeFunction rtp argtp
        | (length argtp) == (length args) -> do
          rargs <- zipWithM (\arg tp -> compileExpression arg (Just tp)) args argtp
          res <- newLabel
          let resvar = LMLocalVar res (toLLVMType rtp)
          return ([Assignment resvar (Call StdCall eVar [ v | (_,v,_) <- rargs ] [])]++(concat [stmts | (stmts,_,_) <- rargs])++eStmts,resvar,rtp)
        | otherwise -> throwError (WrongNumberOfArguments e (length  args) (length argtp))
    _ -> throwError (NotAFunction e ftp)
compileExpression e@(ExprLambda args body) etp = do
  fid <- newLabel
  let fname = BS.pack ("lambda"++show (hashUnique fid))
  let fdecl = genFuncDecl fname TypeInt (map snd args)
  blks <- stackShadow $ do
    stackAdd [ Variable tp (BS.pack name) | (name,tp) <- args ]
    compileStatement body Nothing >>= uncurry appendStatements
  tell $ [LlvmFunction { funcDecl = fdecl,
                         funcArgs = map (BS.pack . fst) args,
                         funcAttrs = [],
                         funcSect = Nothing,
                         funcBody = readyBlocks blks
                       }]
  typeCheck e etp (TypeFunction TypeVoid (map snd args))
  return ([],LMGlobalVar fname (LMFunction fdecl) External Nothing Nothing False,TypeFunction TypeVoid (map snd args))
  
    
compileExpression expr _ = error $ "Couldn't compile expression "++show expr

toLLVMType :: Type -> LlvmType
toLLVMType TypeInt = LMInt 32
toLLVMType TypeBool = LMInt 1