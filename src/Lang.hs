module Lang where

import           Data.Char
import           Data.List                  hiding (group)
import qualified Data.Map.Strict            as M
import           Data.Maybe                 (isJust)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Void

import           Control.Monad              (void)
import           Control.Monad.State.Strict

import           Text.Megaparsec            hiding (State)
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import           Core

{-
term :=
  | Var = <string>
  | Typ = Type
  | All = (x : A) -> B
  | App = f(a)
  | Slf = ${a}
  | New = new(a) b
  | Use = use(a)(b)
  | Num = Number
  | Val = <int>
  | Op1 = +(x)
  | Op2 = +(x,y)
  | Ite = c ? t : f
  | Ann = a :: A
  | Log = log(a) b
  | Hol = ?a
  | Ref = <name>
-}

type Scope = M.Map Name Term

data Ctx = Ctx { binders :: [Text], holeCount :: Int } deriving Show

type Parser = ParsecT Void Text (State Ctx)

-- space consumer
sc :: Parser ()
sc = L.space space1 (L.skipLineComment "//") empty

symbol =  L.symbol sc

parserTest :: Show a => Parser a -> Text -> IO ()
parserTest p s = print $ runState (runParserT p "" s) (Ctx [] 0)

evalTest :: Parser Term -> Text -> IO ()
evalTest p s = do
  let (Right a, b) = runState (runParserT p "" s) (Ctx [] 0)
  print $ eval a M.empty

name :: Parser Text
name = do
  n  <- letterChar <|> satisfy (\x -> x == '_')
  ns <- many (alphaNumChar <|> satisfy (\x -> elem x ['_','.','#','-','@','/']))
  return $ T.pack (n : ns)

refVar :: Parser Term
refVar = do
  bs <- gets binders
  n <- name
  case findIndex (\x -> x == n) bs of
    Just i -> return $ Var i
    _      -> return $ Ref n

num :: Parser Term
num = "Number" >> return Num

val :: Parser Term
val = Val <$> L.decimal

typ :: Parser Term
typ = "Type" >> return Typ

allLam :: Parser Term
allLam = do
  bs <- symbol "(" >> binds
  sc
  ctor <- (symbol "->" >> return All) <|> (symbol "=>" >> return Lam)
  sc
  body <- expr
  return $ foldr (\(n,t,e) x -> ctor n t x e) body bs

  where
    binds :: Parser [(Name, Term, Eras)]
    binds = (sc >> ")" >> return []) <|> next

    next :: Parser [(Name,Term,Eras)]
    next = do
      b <- name
      modify (\ctx -> ctx { binders = b : binders ctx })
      sc
      bT <- typeOrHole
      e <- optional $ (sc >> symbol ",") <|> (sc >> symbol ";")
      case e of
        Just ";" -> (do bs <- binds; return $ (b,bT,True) : bs)
        _        -> (do bs <- binds; return $ (b,bT,False) : bs)

    typeOrHole :: Parser Term
    typeOrHole = do
      bT <- (optional $ symbol ":" >> term)
      case bT of
        Just x -> return x
        Nothing -> newHole

newHole :: Parser Term
newHole = do
  h <- gets holeCount
  modify (\ctx -> ctx { holeCount = (holeCount ctx) + 1 })
  return $ Hol $ T.pack ("?#" ++ show h)

group :: Parser Term
group = symbol "(" >> expr <* symbol ")"

term :: Parser Term
term = do
  t <- choice
      [ try $ allLam
      , try $ typ
      , try $ num
      , try $ val
      , try $ refVar
      , try $ group
      ]
  choice
    [try $ fun t
    , return t
    ]

fun :: Term -> Parser Term
fun f = do
  as <- concat <$> (symbol "(" >> args) `sepBy` sc
  return $ foldl (\t (a,e) -> App t a e) f as
  where
    args :: Parser [(Term, Bool)]
    args = (sc >> ")" >> return []) <|> next

    next :: Parser [(Term, Bool)]
    next = do
      a <- term
      sc
      e <- optional $ (sc >> symbol ",") <|> (sc >> symbol ";")
      case e of
        Just ";"  -> (do as <- args; return $ (a,True) : as)
        _         -> (do as <- args; return $ (a,False) : as)

expr :: Parser Term
expr = do
  ts <- term `sepEndBy1` sc
  return $ foldl1 (\x y -> App x y False) ts


