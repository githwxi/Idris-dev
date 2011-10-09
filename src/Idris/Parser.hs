module Idris.Parser where

import Idris.AbsSyntax

import Core.CoreParser
import Core.TT

import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Expr
import Text.ParserCombinators.Parsec.Language
import qualified Text.ParserCombinators.Parsec.Token as PTok

import Data.List
import Control.Monad.State
import Debug.Trace

type TokenParser a = PTok.TokenParser a

type IParser = GenParser Char IState

lexer :: TokenParser IState
lexer  = PTok.makeTokenParser idrisDef

whiteSpace= PTok.whiteSpace lexer
lexeme    = PTok.lexeme lexer
symbol    = PTok.symbol lexer
natural   = PTok.natural lexer
parens    = PTok.parens lexer
semi      = PTok.semi lexer
comma     = PTok.comma lexer
identifier= PTok.identifier lexer
reserved  = PTok.reserved lexer
operator  = PTok.operator lexer
reservedOp= PTok.reservedOp lexer
lchar = lexeme.char

parseExpr i = runParser pFullExpr i "(input)"

parseProg :: String -> Idris [PDecl]
parseProg fname = do file <- lift $ readFile fname
                     i <- get
                     case (runParser (do ps <- many1 pDecl
                                         eof
                                         i' <- getState
                                         return (ps, i')) i fname file) of
                        Left err -> fail (show err)
                        Right (x, i) -> do put i
                                           return (collect x)

-- Collect PClauses with the same function name
collect :: [PDecl] -> [PDecl]
collect (PClauses _ [c@(PClause n l r)] : ds) = clauses n [c] ds
  where clauses n acc (PClauses _ [c@(PClause n' l r)] : ds)
           | n == n' = clauses n (c : acc) ds
        clauses n acc xs = PClauses n (reverse acc) : collect xs
collect (d : ds) = d : collect ds
collect [] = []

pFullExpr = do x <- pExpr; eof; return x

pDecl :: IParser PDecl
pDecl = do d <- pDecl'
           lchar ';'
           i <- getState
           return (fmap (addImpl i) d)

--------- Top Level Declarations ---------

pDecl' :: IParser PDecl
pDecl' = try pFixity
     <|> try (do n <- pfName; ty <- pTSig
                 ty' <- implicit n ty
                 return (PTy n ty'))
     <|> try pData
     <|> try pPattern

--------- Fixity ---------

pFixity :: IParser PDecl
pFixity = do f <- fixity; i <- natural; ops <- sepBy1 operator (lchar ',')
             let prec = fromInteger i
             istate <- getState
             let fs = map (Fix (f prec)) ops
             setState (istate { 
                idris_infixes = sort (fs ++ idris_infixes istate) })
             return (PFix (f prec) ops)

fixity :: IParser (Int -> Fixity) 
fixity = try (do reserved "infixl"; return Infixl)
     <|> try (do reserved "infixr"; return Infixr)
     <|> try (do reserved "infix";  return InfixN)

--------- Expressions ---------

pExpr = do i <- getState
           buildExpressionParser (table (idris_infixes i)) pExpr'

pExpr' :: IParser PTerm
pExpr' = try pApp 
     <|> pSimpleExpr
     <|> try pLambda
     <|> try pPi 

pfName = try iName
     <|> do lchar '('; o <- operator; lchar ')'; return (UN [o])

pSimpleExpr = 
        try (do symbol "!["; t <- pTerm; lchar ']' 
                return $ PQuote t)
        <|> try (do x <- pfName; return (PRef x))
        <|> try (do lchar '_'; return Placeholder)
        <|> try (do lchar '('; e <- pExpr; lchar ')'; return e)
        <|> try (do reserved "Set"; return PSet)

pHSimpleExpr = try pSimpleExpr
           <|> do lchar '.'
                  e <- pSimpleExpr
                  return $ PHidden e

pApp = do f <- pSimpleExpr
          iargs <- many pImplicitArg
          args <- many1 pSimpleExpr
          return (PApp f iargs args)

pImplicitArg = do lchar '{'; n <- iName
                  v <- option (PRef n) (do lchar '='; pExpr)
                  lchar '}'
                  return (n, v)

pTSig = do lchar ':'
           pExpr

pLambda = do lchar '\\'; x <- iName; t <- option Placeholder pTSig
             symbol "=>"
             sc <- pExpr
             return (PLam x t sc)

pPi = do lchar '('; x <- iName; t <- pTSig; lchar ')'
         symbol "->"
         sc <- pExpr
         return (PPi Exp x t sc)
  <|> do lchar '{'; x <- iName; t <- pTSig; lchar '}'
         symbol "->"
         sc <- pExpr
         return (PPi Imp x t sc)

table fixes 
   = toTable (reverse fixes) ++
      [[binary "="  (\x y -> PApp (PRef (UN ["="])) [] [x,y]) AssocLeft],
       [binary "->" (PPi Exp (MN 0 "X")) AssocRight]]

toTable fs = map (map toBin) 
                 (groupBy (\ (Fix x _) (Fix y _) -> prec x == prec y) fs)
   where toBin (Fix f op) = binary op 
                               (\x y -> PApp (PRef (UN [op])) [] [x,y]) (assoc f)
         assoc (Infixl _) = AssocLeft
         assoc (Infixr _) = AssocRight
         assoc (InfixN _) = AssocNone

binary name f assoc = Infix (do { reservedOp name; return f }) assoc

--------- Data declarations ---------

pData :: IParser PDecl
pData = try (do reserved "data"; tyn <- pfName; ty <- pTSig
                reserved "where"
                ty' <- implicit tyn ty
                cons <- sepBy1 pConstructor (lchar '|')
                return $ PData (PDatadecl tyn ty' cons))
    <|> do reserved "data"; tyn <- pfName; args <- many iName
           lchar '='
           cons <- sepBy1 pSimpleCon (lchar '|')
           let conty = mkPApp (PRef tyn) (map PRef args)
           let ty = bindArgs (map (\a -> PSet) args) PSet
           ty' <- implicit tyn ty
           cons' <- mapM (\ (x, cargs) -> do let cty = bindArgs cargs conty
                                             cty' <- implicit x cty
                                             return (x, cty')) cons
           return $ PData (PDatadecl tyn ty' cons')

mkPApp t [] = t
mkPApp t xs = PApp t [] xs

bindArgs :: [PTerm] -> PTerm -> PTerm
bindArgs [] t = t
bindArgs (x:xs) t = PPi Exp (MN 0 "t") x (bindArgs xs t)

pConstructor :: IParser (Name, PTerm)
pConstructor 
    = do cn <- pfName; ty <- pTSig
         ty' <- implicit cn ty
         return (cn, ty')

pSimpleCon :: IParser (Name, [PTerm])
pSimpleCon = do cn <- pfName
                args <- many pSimpleExpr
                return (cn, args)

--------- Pattern match clauses ---------

pPattern :: IParser PDecl
pPattern = do clause <- pClause 
              return (PClauses (MN 0 "_") [clause]) -- collect together later

pClause :: IParser PClause
pClause = try (do n <- pfName
                  iargs <- many pImplicitArg
                  args <- many pHSimpleExpr
                  lchar '='
                  rhs <- pExpr
                  return $ PClause n (PApp (PRef n) iargs args) rhs)
       <|> do l <- pSimpleExpr
              op <- operator
              let n = UN [op]
              r <- pSimpleExpr
              lchar '='
              rhs <- pExpr
              return $ PClause n (PApp (PRef n) [] [l,r]) rhs

-- Dealing with implicit arguments

implicit :: Name -> PTerm -> IParser PTerm
implicit n ptm 
    = do i <- getState
         let (tm', names) = implicitise i ptm
         setState (i { idris_implicits = addDef n names (idris_implicits i) })
         return tm'

addImplicits :: PTerm -> IParser PTerm
addImplicits tm 
    = do i <- getState
         return (addImpl i tm)
